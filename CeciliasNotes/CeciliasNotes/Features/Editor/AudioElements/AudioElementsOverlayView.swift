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
/// so handwriting can sit on top. Play / pause / context-menu
/// delete stay live in every tool mode.
struct AudioElementsOverlayView: View, Equatable {

    let inputs: EditorPageOverlayInputs
    let pageId: UUID
    let coordinateSpace: PageCoordinateSpace

    private var modelContext: ModelContext {
        StorageService.shared.container.mainContext
    }

    @State private var selectedElementId: UUID?
    @State private var cachedElements: [PageElement] = []

    private var pageSize: CGSize { coordinateSpace.baseSize }

    /// Audio strips share the same "selectable in cursor/image
    /// modes" gate as other PageElement-backed media. There's no
    /// dedicated audio tool — recording is its own UX surface.
    private var allowsInteraction: Bool {
        inputs.selectedTool.allowsImageSelection
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

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pageId == rhs.pageId
            && lhs.coordinateSpace.baseSize == rhs.coordinateSpace.baseSize
            && lhs.inputs == rhs.inputs
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

            ForEach(cachedElements, id: \.id) { element in
                if let content = element.audioContent {
                    AudioElementView(
                        element: element,
                        content: content,
                        pageSize: pageSize,
                        allowsSelection: allowsInteraction,
                        isSelected: bindingForSelected(elementId: element.id),
                        onDelete: { softDelete(elementId: element.id) }
                    )
                    .zIndex(selectedElementId == element.id ? 1_000 : 0)
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
            NotificationCenter.default.publisher(for: .audioElementsChanged)
        ) { _ in
            reloadElements()
        }
    }

    // MARK: - Fetch

    private func reloadElements() {
        let audioOnly = PageElementOverlayFetch.elements(
            pageId: pageId,
            kind: .audio,
            context: modelContext
        )
        #if DEBUG
        if !audioOnly.isEmpty {
            dlog("[AudioPlayback] overlay elements fetch — pageId=\(pageId) audioElements=\(audioOnly.count) ids=\(audioOnly.map { $0.id.uuidString.prefix(8) })")
        }
        #endif
        cachedElements = audioOnly
        if let selected = selectedElementId,
           !audioOnly.contains(where: { $0.id == selected }) {
            selectedElementId = nil
        }
    }

    private func bindingForSelected(elementId: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedElementId == elementId },
            set: { newValue in
                if newValue {
                    // Lasso sits above audio in the page stack and
                    // claims the full page for hit-testing while it
                    // owns a selection — clear it so the audio
                    // toolbar's delete button gets the first tap.
                    LassoSelectionState.shared.clear()
                    selectedElementId = elementId
                } else if selectedElementId == elementId {
                    selectedElementId = nil
                }
            }
        )
    }

    private func softDelete(elementId: UUID) {
        let eid = elementId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == eid && $0.deletedAt == nil }
        )
        guard let element = try? modelContext.fetch(descriptor).first else {
            #if DEBUG
            dlog("[AudioElement] softDelete DROP — element not found id=\(elementId)")
            #endif
            if selectedElementId == eid { selectedElementId = nil }
            reloadElements()
            return
        }

        PageElementUndo.registerDelete(
            elementId: element.id,
            kind: .audio,
            canvas: inputs.canvasView,
            actionName: "Delete Audio"
        )
        element.deletedAt = Date()
        element.updatedAt = Date()
        do {
            try modelContext.save()
            HapticManager.shared.destructiveConfirmed()
            #if DEBUG
            dlog("[AudioElement] softDelete OK — elementId=\(element.id)")
            #endif
        } catch {
            #if DEBUG
            dlog("[AudioElement] save failed on softDelete: \(error)")
            #endif
        }
        // Clear selection only after the delete commits — clearing
        // first unmounts the toolbar mid-tap and drops the action.
        if selectedElementId == eid {
            selectedElementId = nil
        }
        reloadElements()
        NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
    }
}

// AudioSeekKey + .audioSeekRequested live in AudioElementCommit.swift
