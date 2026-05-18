import SwiftData
import SwiftUI
import UIKit

/// Per-page render layer for V6 `PageElement`s of kind `.audio`.
/// Fourth PageElement-backed overlay (after text Step 3, image
/// Step 4, PDF Step 4.5); same template shape.
///
/// Step 5: replaces the legacy `AudioAnnotationCardsOverlayView`
/// (which rendered `AudioRecord` cards stacked from the top of the
/// page) and `LectureBlocksOverlayView` (which rendered
/// `lecture:<uuid>`-prefixed `TextBlock`s as expandable lecture
/// cards). Both legacy entities are gone; both legacy overlays are
/// retired in the same commit.
///
/// Cursor + image tool let users select existing audio strips
/// (drag, width-resize, delete). Drawing tools leave audio inert
/// so handwriting can sit on top.
struct AudioElementsOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel
    let pageId: UUID
    let coordinateSpace: PageCoordinateSpace

    private var modelContext: ModelContext {
        StorageService.shared.container.mainContext
    }

    @State private var selectedElementId: UUID?
    @State private var refreshTick: Int = 0

    private var pageSize: CGSize { coordinateSpace.baseSize }

    /// Audio strips share the same "selectable in cursor/image
    /// modes" gate as other PageElement-backed media. There's no
    /// dedicated audio tool — recording is its own UX surface.
    private var allowsInteraction: Bool {
        viewModel.selectedTool.allowsImageSelection
    }

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
        return all.filter { $0.kind == .audio }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if allowsInteraction {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { _ in
                        if selectedElementId != nil { selectedElementId = nil }
                    }
            }

            ForEach(elements, id: \.id) { element in
                if let content = element.audioContent {
                    AudioElementView(
                        element: element,
                        content: content,
                        pageSize: pageSize,
                        isSelected: bindingForSelected(elementId: element.id),
                        onDelete: { softDelete(element) }
                    )
                    // Play/pause/seek work regardless of tool mode —
                    // playback is a content interaction, not a
                    // selection interaction. Only the drag/resize/
                    // delete chrome is gated on `allowsInteraction`.
                }
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onChange(of: viewModel.selectedTool.identity) { _, newValue in
            if newValue != .cursor && newValue != .image {
                selectedElementId = nil
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .audioElementsChanged)
        ) { _ in
            refreshTick &+= 1
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
        element.deletedAt = Date()
        element.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("[AudioElement] save failed on softDelete: \(error)")
            #endif
        }
        refreshTick &+= 1
        NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Posted by the recording commit paths (short-note + lecture
    /// flows) and this overlay's soft-delete handler whenever an
    /// audio element is inserted, updated, or soft-deleted. The
    /// overlay refetches; the notification is a "now would be a
    /// good time to refetch" hint, not a payload carrier.
    static let audioElementsChanged = Notification.Name("audioElementsChanged")
}
