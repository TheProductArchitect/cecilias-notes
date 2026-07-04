import SwiftData
import SwiftUI
import UIKit

/// Per-page render layer for V6 `PageElement(kind: .highlight)`.
/// Fifth PageElement-backed overlay (text, image, PDF, audio,
/// highlight); same template.
///
/// Step 5.5: replaces the legacy
/// `PageRenderer.drawTextAnnotationOverlay` Core Graphics pass.
/// Lives between the PDF overlay and the image overlay in the
/// host stack so highlights sit visually on top of the PDF text
/// they annotate, with strokes / text / images / audio layered
/// above.
///
/// Projection: HighlightContent stores its rect in normalised
/// PDF-page coordinates. The actual on-screen position depends on
/// where the host PDFPageContent's `PageElement` sits within the
/// canvas page (full-bleed for Workflow A, resized for Workflow B).
/// The overlay fetches the parent PDFPageContent element for each
/// highlight and composes the two normalised rects before passing
/// the final render rect to `HighlightElementView`.
struct HighlightElementsOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel
    let pageId: UUID
    let coordinateSpace: PageCoordinateSpace

    private var modelContext: ModelContext {
        StorageService.shared.container.mainContext
    }

    @State private var selectedElementId: UUID?
    @State private var refreshTick: Int = 0

    private var pageSize: CGSize { coordinateSpace.baseSize }

    /// Cursor + image tools let users select / delete existing
    /// highlights. The highlighter tool itself targets PDF text
    /// (not existing highlight rectangles) so it doesn't gate
    /// selection here.
    private var allowsInteraction: Bool {
        viewModel.selectedTool.allowsImageSelection
    }

    /// Whether to mount the full-page background tap layer.
    /// OPEN_ISSUES #1 — the catcher only clears the selection, so
    /// mount it only while a selection exists. A no-op full-page
    /// catcher absorbs taps meant for the overlays stacked below
    /// this one in `PageOverlaysContainer`.
    private var showsBackgroundCatcher: Bool {
        allowsInteraction && selectedElementId != nil
    }

    /// Fetch highlight elements for this page. Filter `kind ==
    /// .highlight` in Swift (iOS 26 `#Predicate` workaround
    /// established in Step 3).
    private var elements: [PageElement] {
        let _ = refreshTick
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.zIndex), SortDescriptor(\.createdAt)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.kind == .highlight }.dedupedById()
    }

    /// Quick lookup of every PDF page element on this page —
    /// highlights project through their parent PDFPageContent's
    /// bounds.
    private var pdfPageElementsByContentId: [UUID: PageElement] {
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            }
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        var map: [UUID: PageElement] = [:]
        for element in all where element.kind == .pdfPage {
            if let content = element.pdfPageContent {
                map[content.id] = element
            }
        }
        return map
    }

    var body: some View {
        let pdfMap = pdfPageElementsByContentId
        ZStack(alignment: .topLeading) {
            if showsBackgroundCatcher {
                // Tap-to-deselect on empty area. Mounted only while a
                // selection exists — see `showsBackgroundCatcher`.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { _ in
                        if selectedElementId != nil { selectedElementId = nil }
                    }
            }

            ForEach(elements, id: \.id) { element in
                if let content = element.highlightContent,
                   let parent = pdfMap[content.pdfPageContentId] {
                    HighlightElementView(
                        element: element,
                        content: content,
                        renderRect: renderRect(for: content, parent: parent),
                        isSelected: bindingForSelected(elementId: element.id),
                        onDelete: { softDeleteGroup(for: element) }
                    )
                    .allowsHitTesting(allowsInteraction)
                }
                // Highlights whose parent PDFPageContent is gone are
                // filtered out by the map lookup — equivalent to the
                // soft-delete cascade the architecture calls for.
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onChange(of: viewModel.selectedTool.identity) { _, newValue in
            if newValue != .cursor && newValue != .image {
                selectedElementId = nil
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .highlightElementsChanged)
        ) { _ in
            refreshTick &+= 1
        }
    }

    /// Project the highlight's normalised PDF-page rect onto the
    /// host page's canvas coordinates. The parent PDF element
    /// bounds carry the PDF-on-canvas placement; multiplying
    /// through gives the final render rect.
    ///
    /// `parent.normalizedX/Y/Width/Height` are the PDF
    /// element's bounds in host-page-normalised coords.
    /// `content.rectOrigin*/Width/Height` are the highlight's
    /// bounds in PDF-page-normalised coords. Compose:
    ///   x = parent.x + content.x * parent.width
    ///   y = parent.y + content.y * parent.height
    ///   w = content.w * parent.width
    ///   h = content.h * parent.height
    /// then × pageSize to get the canvas-points rect.
    private func renderRect(for content: HighlightContent, parent: PageElement) -> CGRect {
        let normX = parent.normalizedX + content.rectOriginX * parent.normalizedWidth
        let normY = parent.normalizedY + content.rectOriginY * parent.normalizedHeight
        let normW = content.rectWidth  * parent.normalizedWidth
        let normH = content.rectHeight * parent.normalizedHeight
        return CGRect(
            x: normX * pageSize.width,
            y: normY * pageSize.height,
            width:  normW * pageSize.width,
            height: normH * pageSize.height
        )
    }

    private func bindingForSelected(elementId: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedElementId == elementId },
            set: { newValue in
                if newValue {
                    selectedElementId = elementId
                } else if selectedElementId == elementId {
                    selectedElementId = nil
                }
            }
        )
    }

    /// Soft-delete this element and every other highlight that
    /// shares its `groupId` (multi-line selections). Standalone
    /// highlights — `groupId == nil` — delete just themselves.
    private func softDeleteGroup(for element: PageElement) {
        let context = modelContext
        let now = Date()

        // Standalone: single soft-delete.
        guard let groupId = element.highlightContent?.groupId else {
            if selectedElementId == element.id { selectedElementId = nil }
            PageElementUndo.registerDelete(
                elementId: element.id,
                kind: .highlight,
                canvas: viewModel.canvasView,
                actionName: "Delete Highlight"
            )
            element.deletedAt = now
            element.updatedAt = now
            try? context.save()
            refreshTick &+= 1
            NotificationCenter.default.post(name: .highlightElementsChanged, object: nil)
            return
        }

        // Group: find every sibling and soft-delete in one save.
        let descriptor = FetchDescriptor<HighlightContent>(
            predicate: #Predicate { $0.groupId == groupId }
        )
        let contents = (try? context.fetch(descriptor)) ?? []
        // One grouped undo step restores the whole multi-line
        // highlight, matching how it was created.
        let undoManager = viewModel.canvasView?.undoManager
        undoManager?.beginUndoGrouping()
        for content in contents {
            guard let el = content.element else { continue }
            PageElementUndo.registerDelete(
                elementId: el.id,
                kind: .highlight,
                canvas: viewModel.canvasView,
                actionName: "Delete Highlight"
            )
            el.deletedAt = now
            el.updatedAt = now
        }
        undoManager?.endUndoGrouping()
        if let toClear = selectedElementId,
           contents.contains(where: { $0.element?.id == toClear }) {
            selectedElementId = nil
        }
        try? context.save()
        refreshTick &+= 1
        NotificationCenter.default.post(name: .highlightElementsChanged, object: nil)
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Posted by `HighlightCommit` and this overlay's soft-delete
    /// handler whenever a highlight element is inserted or
    /// deleted. Overlays refetch; the notification is a "now
    /// would be a good time to refetch" hint, not a payload.
    static let highlightElementsChanged = Notification.Name("highlightElementsChanged")
}
