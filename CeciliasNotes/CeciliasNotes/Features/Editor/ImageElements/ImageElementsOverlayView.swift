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
struct ImageElementsOverlayView: View, Equatable {

    let inputs: EditorPageOverlayInputs
    let pageId: UUID
    let notebookId: UUID
    let coordinateSpace: PageCoordinateSpace

    private var modelContext: ModelContext {
        StorageService.shared.container.mainContext
    }

    @State private var selectedElementId: UUID?
    @State private var cachedElements: [PageElement] = []

    private var pageSize: CGSize { coordinateSpace.baseSize }

    /// True for tools that let the user select / drag / resize
    /// existing images. Matches `CeciliasNotesTool.allowsImageSelection`
    /// (cursor + image).
    private var allowsInteraction: Bool {
        inputs.selectedTool.allowsImageSelection
    }

    /// Whether to mount the full-page background tap layer.
    ///
    /// OPEN_ISSUES #1 — element-tap gesture absorption. A full-page
    /// `.contentShape` tap catcher absorbs every tap on the page, so
    /// while it's mounted no tap reaches the overlays stacked below
    /// this one. This catcher's only job is to clear the selection,
    /// so mount it only while a selection exists — otherwise it is a
    /// no-op layer that must not be mounted.
    private var showsBackgroundCatcher: Bool {
        allowsInteraction && selectedElementId != nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pageId == rhs.pageId
            && lhs.notebookId == rhs.notebookId
            && lhs.coordinateSpace.baseSize == rhs.coordinateSpace.baseSize
            && lhs.inputs == rhs.inputs
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background tap surface — clears the selection when
            // the user taps empty page area. See
            // `showsBackgroundCatcher`: mounted only while a
            // selection exists, so it never absorbs taps meant for
            // the image / sticky / audio overlays below.
            if showsBackgroundCatcher {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { _ in
                        if selectedElementId != nil { selectedElementId = nil }
                    }
            }

            ForEach(cachedElements, id: \.id) { element in
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
        .onAppear { reloadElements() }
        .onChange(of: inputs.selectedTool.identity) { _, newValue in
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
        ) { note in
            // Mirror the shape overlay's tick-deferring rule for the
            // cross-page handoff: when this overlay is the source
            // page in a move, refresh one runloop tick later so the
            // destination renders first and the user doesn't see an
            // empty frame between source-drop and destination-mount.
            // Non-handoff posts (legacy import pipeline, soft-delete
            // path) carry no userInfo and fall through to the
            // immediate path.
            if let info = note.userInfo,
               let srcId = info["sourcePageId"] as? UUID,
               srcId == pageId {
                DispatchQueue.main.async { reloadElements() }
            } else {
                reloadElements()
            }
        }
    }

    // MARK: - Fetch

    private func reloadElements() {
        cachedElements = PageElementOverlayFetch.elements(
            pageId: pageId,
            kind: .image,
            context: modelContext
        )
        if let selected = selectedElementId,
           !cachedElements.contains(where: { $0.id == selected }) {
            selectedElementId = nil
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

    // MARK: - Soft delete

    private func softDelete(_ element: PageElement) {
        if selectedElementId == element.id {
            selectedElementId = nil
        }
        PageElementUndo.registerDelete(
            elementId: element.id,
            kind: .image,
            canvas: inputs.canvasView,
            actionName: "Delete Image"
        )
        element.deletedAt = Date()
        element.updatedAt = Date()
        // Thumbnail key is `page.updatedAt` — refresh the strip.
        StrokeCommit.stampPage(pageId: element.pageId, context: modelContext)
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            dlog("[ImageElement] save failed on softDelete: \(error)")
            #endif
        }
        reloadElements()
        NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
    }
}

// `Notification.Name.mediaAttachmentsChanged` is declared in
// `Core/Extensions/ElementChangeNotifications.swift` — shared with
// the Mac target, which posts it from trash restore.
