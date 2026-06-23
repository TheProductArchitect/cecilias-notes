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

    /// Whether to mount the full-page background tap layer.
    ///
    /// OPEN_ISSUES #1 — element-tap gesture absorption. A full-page
    /// `.contentShape` tap catcher absorbs every tap on the page, so
    /// while it's mounted no tap reaches the overlays stacked below.
    /// This catcher's only job is to clear the selection, so mount it
    /// only while a selection exists — otherwise it is a no-op layer
    /// that would, in particular, swallow taps on the audio play
    /// button itself.
    private var showsBackgroundCatcher: Bool {
        allowsInteraction && selectedElementId != nil
    }

    @State private var elements: [PageElement] = []

    /// Off-main fetch + main-context rebind so SwiftUI body never
    /// blocks on `mainContext.fetch` under CloudKit pressure.
    private func refreshElements() {
        let pid = pageId
        let container = StorageService.shared.container
        Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> {
                    $0.pageId == pid && $0.deletedAt == nil
                },
                sortBy: [SortDescriptor(\.zIndex), SortDescriptor(\.createdAt)]
            )
            let bgAll = (try? bgContext.fetch(descriptor)) ?? []
            let audioIds = bgAll.filter { $0.kind == .audio }.map(\.id)
            await MainActor.run {
                guard !audioIds.isEmpty else {
                    self.elements = []
                    return
                }
                let mainCtx = StorageService.shared.container.mainContext
                let idSet = Set(audioIds)
                let mainDescriptor = FetchDescriptor<PageElement>(
                    predicate: #Predicate<PageElement> { idSet.contains($0.id) },
                    sortBy: [SortDescriptor(\.zIndex), SortDescriptor(\.createdAt)]
                )
                self.elements = (try? mainCtx.fetch(mainDescriptor)) ?? []
                #if DEBUG
                if !self.elements.isEmpty {
                    dlog("[AudioPlayback] overlay elements fetch — pageId=\(pid) audioElements=\(self.elements.count) ids=\(self.elements.map { $0.id.uuidString.prefix(8) })")
                }
                #endif
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background tap surface — see `showsBackgroundCatcher`.
            // Mounted only while a selection exists, so it never
            // absorbs taps meant for the audio strip / play button.
            if showsBackgroundCatcher {
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
            refreshElements()
        }
        .task(id: pageId) { refreshElements() }
        .onChange(of: refreshTick) { _, _ in refreshElements() }
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
            dlog("[AudioElement] save failed on softDelete: \(error)")
            #endif
        }
        refreshTick &+= 1
        NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted by the recording commit paths (short-note + lecture
    /// flows) and this overlay's soft-delete handler whenever an
    /// audio element is inserted, updated, or soft-deleted. The
    /// overlay refetches; the notification is a "now would be a
    /// good time to refetch" hint, not a payload carrier.
    static let audioElementsChanged = Notification.Name("audioElementsChanged")

    /// Posted by the text element overlay when the user taps a word
    /// in a dictated transcript. The receiver (`AudioElementView`)
    /// matches `userInfo[AudioSeekKey.contentId]` against its own
    /// `content.id` and calls `player.seek(to:)` on a match.
    static let audioSeekRequested = Notification.Name("audioSeekRequested")
}

/// userInfo keys for `.audioSeekRequested`.
enum AudioSeekKey {
    static let contentId = "contentId"   // UUID
    static let time      = "time"        // Double (seconds)
}
