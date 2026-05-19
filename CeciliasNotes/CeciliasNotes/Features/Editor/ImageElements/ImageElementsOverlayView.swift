import SwiftData
import SwiftUI
import UIKit

/// Per-page render layer for V6 `PageElement`s of kind `.image`.
/// Second PageElement-backed overlay (after `TextElementsOverlayView`
/// from Step 3) — same shape:
///   • Reads `ModelContext` via `StorageService.shared.container.mainContext`
///     (the static-accessor pattern; `@Environment(\.modelContext)`
///     does not propagate into the per-page `UIHostingController`s
///     built inside `ContinuousCanvasView`).
///   • Fetches `PageElement` rows scoped to `pageId` + `deletedAt == nil`,
///     filters `kind == .image` post-fetch in Swift (the
///     `#Predicate` macro on iOS 26 rejects enum-case equality
///     inside key-path comparisons).
///   • Dispatches each element to `ImageElementView`.
///   • Owns selection state via `selectedElementId`.
///   • Background tap clears selection (cursor + image modes);
///     the image-tool *placement* path is owned by the editor's
///     existing `.imageImportRequested` notification chain — this
///     overlay never opens the picker, it just renders + selects.
struct ImageElementsOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel
    let pageId: UUID
    let notebookId: UUID
    let coordinateSpace: PageCoordinateSpace

    private var modelContext: ModelContext {
        StorageService.shared.container.mainContext
    }

    @State private var selectedElementId: UUID?
    /// Bumped after inserts/deletes so the fetched list re-runs
    /// without waiting for the next view-tree invalidation. Same
    /// trick `TextElementsOverlayView` uses; cheap.
    @State private var refreshTick: Int = 0

    private var pageSize: CGSize { coordinateSpace.baseSize }

    /// True for tools that let the user select / drag / resize
    /// existing images. Matches `CeciliasNotesTool.allowsImageSelection`
    /// (cursor + image).
    private var allowsInteraction: Bool {
        viewModel.selectedTool.allowsImageSelection
    }

    /// Fetch image elements for this page. Filtering by `.image`
    /// kind happens in Swift; the predicate keeps the candidate set
    /// small via pageId + soft-delete.
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
        return all.filter { $0.kind == .image }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background tap surface — clears the selection when
            // the user taps empty page area. Only present in tools
            // that allow image interaction so drawing tools route
            // straight through to the canvas underneath.
            if allowsInteraction {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { _ in
                        print("[ImageGesture] overlay.bg tap pageId=\(pageId.uuidString.prefix(8)) selectedBefore=\(selectedElementId?.uuidString.prefix(8) ?? "nil") allowsInteraction=\(allowsInteraction) tool=\(viewModel.selectedTool.identity)")
                        if selectedElementId != nil { selectedElementId = nil }
                    }
            }

            ForEach(elements, id: \.id) { element in
                if let content = element.imageContent {
                    ImageElementView(
                        element: element,
                        content: content,
                        pageSize: pageSize,
                        isSelected: bindingForSelected(elementId: element.id),
                        onDelete: { softDelete(element) }
                    )
                    // Disable hit-testing entirely when the active
                    // tool doesn't allow image interaction —
                    // matches the legacy `allowsHitTesting(imageMode)`
                    // behaviour so handwriting tools can draw over
                    // images undisturbed.
                    .allowsHitTesting(allowsInteraction)
                }
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onChange(of: viewModel.selectedTool.identity) { _, newValue in
            // Switching to a tool that doesn't allow interaction
            // clears the selection chrome.
            if newValue != .cursor && newValue != .image {
                selectedElementId = nil
            }
        }
        // `.mediaAttachmentsChanged` was the legacy refresh signal
        // posted by `MediaAttachmentStore` mutations. The new flow
        // mutates SwiftData directly — observers can listen to the
        // same name to stay aware of external (e.g. import-pipeline)
        // inserts.
        .onReceive(
            NotificationCenter.default.publisher(for: .mediaAttachmentsChanged)
        ) { _ in
            refreshTick &+= 1
        }
    }

    // MARK: - Selection binding

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

    // MARK: - External-mutation signal

    /// Posted whenever an image element is inserted, updated, or
    /// soft-deleted outside this overlay's body (the import
    /// pipeline, the soft-delete handler below, future PDF/scan
    /// flows). Listeners read SwiftData themselves — the
    /// notification is a "now would be a good time to refetch"
    /// hint, not a payload carrier. Kept on the legacy name so the
    /// existing import-side post sites can land on it during the
    /// Step 4 transition.

    // MARK: - Soft delete

    private func softDelete(_ element: PageElement) {
        if selectedElementId == element.id {
            selectedElementId = nil
        }
        element.deletedAt = Date()
        element.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("[ImageElement] save failed on softDelete: \(error)")
            #endif
        }
        refreshTick &+= 1
        NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Step 4: relocated here when `MediaAttachmentStore` was
    /// retired. Posted by the image import pipeline and by this
    /// overlay's soft-delete path so listeners can refetch from
    /// SwiftData without polling.
    static let mediaAttachmentsChanged = Notification.Name("mediaAttachmentsChanged")
}

