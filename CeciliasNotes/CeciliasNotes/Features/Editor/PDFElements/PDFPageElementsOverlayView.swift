import SwiftData
import SwiftUI
import UIKit

/// Per-page render layer for V6 `PageElement`s of kind `.pdfPage`.
/// Third PageElement-backed overlay (after text in Step 3, image
/// in Step 4); same template:
///   • Reads ModelContext via
///     `StorageService.shared.container.mainContext` (static
///     accessor; SwiftUI environment doesn't propagate into the
///     per-page `UIHostingController`s built inside
///     `ContinuousCanvasView`).
///   • Fetches `PageElement` rows scoped to `pageId` +
///     `deletedAt == nil`, filters `kind == .pdfPage` in Swift
///     (the `#Predicate` macro on iOS 26 rejects enum-case
///     equality inside key-path comparisons).
///   • Dispatches each element to `PDFPageElementView`.
///   • Owns selection state. Background tap clears selection in
///     cursor/image modes; the import path (Workflow B) is fired
///     externally via the toolbar's PDF Page menu item, so this
///     overlay never owns the picker.
///
/// Step 4.5 only renders Workflow B's user-placed PDF page
/// elements. Workflow A (PDF-as-notebook) continues to render via
/// `PageRenderer.updatePDFBacking` until a follow-up step
/// migrates both the PDF render and the
/// `PDFTextAnnotationStore` overlay it sits behind.
struct PDFPageElementsOverlayView: View, Equatable {

    let inputs: EditorPageOverlayInputs
    let pageId: UUID
    let coordinateSpace: PageCoordinateSpace

    private var modelContext: ModelContext {
        StorageService.shared.container.mainContext
    }

    @State private var selectedElementId: UUID?
    @State private var cachedElements: [PageElement] = []

    private var pageSize: CGSize { coordinateSpace.baseSize }

    /// Cursor and image both let the user select existing media.
    /// PDF elements live in the same interaction model — there's
    /// no dedicated "PDF tool" mode (PDF insert is a menu item on
    /// the image tool, not a separate tool).
    private var allowsInteraction: Bool {
        inputs.selectedTool.allowsImageSelection
    }

    /// Whether to mount the full-page background tap layer.
    /// OPEN_ISSUES #1 — the catcher only clears the selection, so
    /// mount it only while a selection exists. A no-op full-page
    /// catcher absorbs taps meant for the overlays stacked below
    /// this one in `PageOverlaysContainer` (the image overlay in
    /// particular).
    private var showsBackgroundCatcher: Bool {
        allowsInteraction && selectedElementId != nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pageId == rhs.pageId
            && lhs.coordinateSpace.baseSize == rhs.coordinateSpace.baseSize
            && lhs.inputs == rhs.inputs
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsBackgroundCatcher {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { _ in
                        if selectedElementId != nil { selectedElementId = nil }
                    }
            }

            ForEach(cachedElements, id: \.id) { element in
                if let content = element.pdfPageContent {
                    PDFPageElementView(
                        element: element,
                        content: content,
                        pageSize: pageSize,
                        isSelected: bindingForSelected(elementId: element.id),
                        onDelete: { softDelete(element) }
                    )
                    .allowsHitTesting(allowsInteraction)
                }
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onAppear { reloadElements() }
        .onChange(of: inputs.selectedTool.identity) { _, newValue in
            if newValue != .cursor && newValue != .image {
                selectedElementId = nil
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .pdfPageElementsChanged)
        ) { _ in
            reloadElements()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .editorBlankPageTapped)
        ) { note in
            guard (note.object as? UUID) == pageId else { return }
            if selectedElementId != nil { selectedElementId = nil }
        }
    }

    private func reloadElements() {
        cachedElements = PageElementOverlayFetch.elements(
            pageId: pageId,
            kind: .pdfPage,
            context: modelContext
        )
        if let selected = selectedElementId,
           !cachedElements.contains(where: { $0.id == selected }) {
            selectedElementId = nil
        }
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

    private func softDelete(_ element: PageElement) {
        if selectedElementId == element.id {
            selectedElementId = nil
        }
        PageElementUndo.registerDelete(
            elementId: element.id,
            kind: .pdfPage,
            canvas: inputs.canvasView,
            actionName: "Delete PDF Page"
        )
        element.deletedAt = Date()
        element.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            dlog("[PDFElement] save failed on softDelete: \(error)")
            #endif
        }
        reloadElements()
        NotificationCenter.default.post(name: .pdfPageElementsChanged, object: nil)
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Posted whenever a PDF page element is inserted, updated, or
    /// soft-deleted outside this overlay's body (Workflow B
    /// import path, the soft-delete handler above). Listeners
    /// read SwiftData themselves; the notification is a "refetch
    /// now" hint.
    static let pdfPageElementsChanged = Notification.Name("pdfPageElementsChanged")
}
