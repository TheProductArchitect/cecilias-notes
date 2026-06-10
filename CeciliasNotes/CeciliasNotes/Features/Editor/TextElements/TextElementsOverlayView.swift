import SwiftData
import SwiftUI
import UIKit

/// Per-page render layer for V6 `PageElement`s of kind `.text`.
/// First user-facing surface for the unified PageElement model —
/// the template Steps 4-7 follow.
///
/// Interaction model:
///   • Text tool active + tap empty area → create a new PageElement
///     (+ TextContent), select it, immediately enter edit mode
///     (keyboard appears).
///   • Cursor tool active + tap a text element → select; another
///     tap (or single tap if already selected) enters edit mode.
///   • Tap outside any element (cursor or text mode) → exit edit
///     mode, save, deselect.
///   • Drag-to-create (V5 TextBlock behaviour) stays on
///     `TextBlockOverlayView` for now — Step 5 retires that path.
///
/// The overlay reads the active `ModelContext` from the
/// environment, fetches text elements for its page on each redraw,
/// and renders them via `TextElementView`. Inserts and deletes go
/// straight to the context — SwiftData's @Bindable propagation
/// keeps the views in sync.
struct TextElementsOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel
    let pageId: UUID
    let notebookId: UUID
    let coordinateSpace: PageCoordinateSpace

    /// Resolved straight from the singleton storage service rather
    /// than via `@Environment(\.modelContext)` — UIHostingController
    /// instances built inside the canvas coordinator don't inherit
    /// the SwiftUI root environment. Every per-page overlay
    /// (image, audio, PDF, highlight, sticky, text) resolves the
    /// context the same way for consistency. Reads happen on the
    /// main actor; the main context is the correct one.
    private var modelContext: ModelContext {
        StorageService.shared.container.mainContext
    }
    @Environment(\.theme) private var theme

    /// Selection identity — UUID of the currently-selected element,
    /// nil for "nothing selected". Cleared when the user taps
    /// empty space or switches to a tool that doesn't allow text
    /// interaction.
    @State private var selectedId: UUID?
    /// Editing identity — separate from `selectedId` because a tap
    /// can select without entering edit mode (and vice versa).
    @State private var editingId: UUID?
    /// SwiftData refresh tick — bumped after inserts/deletes so the
    /// fetched list re-runs without waiting for the next view-tree
    /// invalidation.
    @State private var refreshTick: Int = 0

    private var pageSize: CGSize { coordinateSpace.baseSize }

    /// Fetch text elements for this page. Sorted by zIndex so
    /// stacking is deterministic.
    ///
    /// Filtering by `kind` happens post-fetch in Swift because
    /// SwiftData's `#Predicate` macro on iOS 26 rejects equality
    /// against an enum case in a key-path comparison ("key path
    /// cannot refer to enum case"). The pageId + deletedAt
    /// predicate keeps the candidate set small, and the kind
    /// filter is O(n) over what's typically a handful of elements
    /// per page.
    private var elements: [PageElement] {
        let _ = refreshTick
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.zIndex)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.kind == .text }
    }

    /// True when the active tool grants text-element interaction.
    /// Text tool: creates new elements on tap + edits existing.
    /// Cursor tool: selects + edits existing.
    private var allowsInteraction: Bool {
        viewModel.selectedTool.isCursorMode
            || viewModel.selectedTool.isTextMode
    }

    /// Whether to mount the full-page background tap layer.
    ///
    /// OPEN_ISSUES #1 — element-tap gesture absorption. Every per-page
    /// overlay (text / image / sticky / audio) is a full-page host
    /// stacked inside the renderer. A full-page `.contentShape` tap
    /// catcher absorbs *every* tap on the page, so a catcher mounted
    /// while it has nothing to do starves the overlays below it —
    /// taps on an image / sticky / audio element never reach them.
    ///
    /// The catcher only does work in three cases: an active selection
    /// or edit to dismiss, or text mode (empty tap creates an
    /// element). Mount it only then; when idle in cursor mode it is a
    /// no-op layer and must not be mounted.
    private var showsBackgroundCatcher: Bool {
        guard allowsInteraction else { return false }
        return selectedId != nil
            || editingId != nil
            || viewModel.selectedTool.isTextMode
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background tap layer — see `showsBackgroundCatcher`.
            // In text mode an empty tap creates a new element; with
            // an active selection / edit, an empty tap dismisses it.
            if showsBackgroundCatcher {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        handleBackgroundTap(at: location)
                    }
            }

            ForEach(elements, id: \.id) { element in
                if let content = element.textContent {
                    elementContainer(element: element, content: content)
                }
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onChange(of: viewModel.selectedTool.identity) { _, newValue in
            // Switching to a tool that doesn't allow interaction
            // clears selection / editing state. Switching within
            // the interactive set (cursor ↔ text) preserves it.
            if newValue != .cursor && newValue != .text {
                exitEditAndDeselect()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .textElementsChanged)) { _ in
            // A text element was created outside the overlay's own
            // interactive path (currently the AI Summarize result
            // sheet). Re-fetch so it appears immediately.
            refreshTick &+= 1
        }
        #if DEBUG
        // OPEN_ISSUES #1 diagnostic — reports whether the gated
        // background catcher is mounted. The `v3` marker confirms
        // this build includes the catcher-gating fix (`8824a14`);
        // if no `[TextCatcher v3]` line appears, the device is
        // running a stale build.
        .onAppear {
            print("[TextCatcher v3] onAppear page=\(pageId.uuidString.prefix(8)) "
                + "showsBackgroundCatcher=\(showsBackgroundCatcher) "
                + "selectedId=\(selectedId?.uuidString.prefix(8) ?? "nil") "
                + "editingId=\(editingId?.uuidString.prefix(8) ?? "nil") "
                + "tool=\(viewModel.selectedTool.identity) "
                + "elementCount=\(elements.count)")
        }
        .onChange(of: showsBackgroundCatcher) { old, new in
            print("[TextCatcher v3] page=\(pageId.uuidString.prefix(8)) "
                + "showsBackgroundCatcher \(old) → \(new) "
                + "selectedId=\(selectedId?.uuidString.prefix(8) ?? "nil") "
                + "editingId=\(editingId?.uuidString.prefix(8) ?? "nil") "
                + "tool=\(viewModel.selectedTool.identity)")
        }
        #endif
    }

    // MARK: - Per-element container

    @ViewBuilder
    private func elementContainer(
        element: PageElement,
        content: TextContent
    ) -> some View {
        let isSelected = selectedId == element.id
        let isEditing  = editingId  == element.id

        ZStack(alignment: .topLeading) {
            TextElementView(
                element: element,
                content: content,
                pageSize: pageSize,
                isSelected: bindingForSelected(elementId: element.id),
                isEditing:  bindingForEditing(elementId: element.id)
            )
            // Tap handler sits in front of the editor so cursor-mode
            // taps land on this layer first. The editor still gets
            // focus once `isEditing` flips true (keyboard appears
            // via `TextEditorRepresentable.updateUIView`). Without
            // this, cursor-mode taps would land directly on the
            // UITextView and immediately start editing — skipping
            // the "select first" intermediate state.
            if !isEditing {
                // The renderer ignores the element's stored
                // `normalizedX` / `normalizedWidth` for text and
                // always lays out at `pageMargin × fullContentWidth`.
                // Mirror that here so the catcher covers what the
                // user actually sees — otherwise cursor-mode taps
                // land on a phantom rect to the side of the text.
                let pageMargin: CGFloat = 32
                let catcherWidth  = max(40, pageSize.width - 2 * pageMargin)
                let catcherHeight = max(24, element.normalizedHeight * pageSize.height)
                let catcherY      = max(0, min(pageSize.height - 24,
                                               element.normalizedY * pageSize.height))
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: catcherWidth, height: catcherHeight)
                    .position(
                        x: pageMargin + catcherWidth / 2,
                        y: catcherY   + catcherHeight / 2
                    )
                    .onTapGesture {
                        handleElementTap(element: element)
                    }
                    .onLongPressGesture(minimumDuration: 0.35) {
                        // Long-press selects without entering edit, giving
                        // the move gesture a chance to fire while the
                        // finger is still down (mirrors ImageElementView).
                        if viewModel.selectedTool.isCursorMode {
                            selectedId = element.id
                            // Do not set editingId — leave the block in
                            // the "selected, not editing" state so the
                            // drag gesture on TextElementView activates.
                        }
                    }
            }

            // Word-tap overlay for dictated transcripts that have
            // timing data. Sits on top of the plain tap catcher so
            // it captures the tap, performs seek, then also runs
            // handleElementTap to keep normal selection behaviour.
            // No-ops gracefully when timing data doesn't exist yet
            // (old recordings) or for non-dictated elements.
            if !isEditing,
               content.source == .dictated,
               let audioContent = content.audioRecordings?.first,
               audioContent.timingMapData != nil {
                let elemW = element.normalizedWidth  * pageSize.width
                let elemH = element.normalizedHeight * pageSize.height
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: elemW, height: elemH)
                    .position(
                        x: (element.normalizedX + element.normalizedWidth  / 2) * pageSize.width,
                        y: (element.normalizedY + element.normalizedHeight / 2) * pageSize.height
                    )
                    .onTapGesture(coordinateSpace: .local) { location in
                        handleWordTap(
                            at: location,
                            element: element,
                            content: content,
                            audioContent: audioContent,
                            elementWidth: elemW
                        )
                    }
            }

            // Size picker sits just above the element when selected
            // (cursor mode, not editing). Skipped when the element
            // is near the top of the page so it doesn't render off-
            // screen — fallback: below the element.
            if isSelected && !isEditing {
                sizePicker(for: content, element: element)
            }
        }
    }

    @ViewBuilder
    private func sizePicker(for content: TextContent, element: PageElement) -> some View {
        let pickerHeight: CGFloat = 36
        let gap: CGFloat = 8
        let elementOriginY = element.normalizedY * pageSize.height
        let elementCenterX = (element.normalizedX + element.normalizedWidth / 2) * pageSize.width
        let placeAbove = elementOriginY > (pickerHeight + gap)
        let y: CGFloat = placeAbove
            ? elementOriginY - gap - pickerHeight / 2
            : (element.normalizedY + element.normalizedHeight) * pageSize.height + gap + pickerHeight / 2

        TextSizePickerView(size: Binding(
            get: { content.size },
            set: { content.size = $0 }
        ))
        .frame(height: pickerHeight)
        .position(x: elementCenterX, y: y)
    }

    // MARK: - Selection / editing bindings

    /// Mirrors `selectedId == elementId` two-way so the child view
    /// can request selection state changes.
    private func bindingForSelected(elementId: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedId == elementId },
            set: { newValue in
                if newValue {
                    selectedId = elementId
                } else if selectedId == elementId {
                    selectedId = nil
                }
            }
        )
    }

    private func bindingForEditing(elementId: UUID) -> Binding<Bool> {
        Binding(
            get: { editingId == elementId },
            set: { newValue in
                if newValue {
                    selectedId = elementId
                    editingId  = elementId
                } else if editingId == elementId {
                    editingId = nil
                }
            }
        )
    }

    // MARK: - Tap handling

    private func handleBackgroundTap(at location: CGPoint) {
        // If currently editing or selected, an empty-area tap exits
        // back to a neutral state first. Subsequent text-mode taps
        // create new elements; cursor-mode taps just deselect.
        if editingId != nil || selectedId != nil {
            exitEditAndDeselect()
            return
        }
        if viewModel.selectedTool.isTextMode {
            createNewElement(at: location)
        }
    }

    private func handleElementTap(element: PageElement) {
        if selectedId == element.id {
            // Second tap on an already-selected element → enter
            // edit mode (keyboard appears).
            editingId = element.id
        } else {
            // First tap → select (no keyboard yet). Cursor mode
            // surfaces the size picker; text mode does too — both
            // give the user a chance to adjust size before typing.
            selectedId = element.id
            editingId  = nil
        }
    }

    private func exitEditAndDeselect() {
        editingId  = nil
        selectedId = nil
    }

    // MARK: - Word tap (dictated transcript seek)

    private func handleWordTap(
        at location: CGPoint,
        element: PageElement,
        content: TextContent,
        audioContent: AudioContent,
        elementWidth: CGFloat
    ) {
        // Keep normal element-selection behaviour.
        handleElementTap(element: element)

        guard let timingMap = audioContent.timingMap else { return }
        let charIndex = characterIndex(at: location, text: content.text,
                                       size: content.size, width: elementWidth)
        guard let word = timingMap.wordContaining(charIndex: charIndex) else { return }
        NotificationCenter.default.post(
            name: .audioSeekRequested,
            object: nil,
            userInfo: [
                AudioSeekKey.contentId: audioContent.id,
                AudioSeekKey.time:      word.startTime
            ]
        )
    }

    /// Map a point (in element-local coordinates) to the nearest
    /// character index in `text`, using the same font and container
    /// width the live UITextView uses so the mapping is accurate.
    private func characterIndex(
        at point: CGPoint,
        text: String,
        size: TextSize,
        width: CGFloat
    ) -> Int {
        guard !text.isEmpty, width > 1 else { return 0 }
        let font = UIFont.systemFont(ofSize: size.pointSize, weight: size.fontWeight)
        let storage = NSTextStorage(
            attributedString: NSAttributedString(string: text, attributes: [.font: font])
        )
        let layout    = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return layout.characterIndex(
            for: point,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
    }

    // MARK: - Create

    private func createNewElement(at location: CGPoint) {
        // Default placement: tap location becomes the top-left
        // corner. Width: 50% of page width. Height: enough for one
        // line at body size, with a small breathing margin.
        let defaultWidth: Double = 0.5
        let bodyHeight = TextSize.body.pointSize + 12
        let defaultHeight: Double = max(0.04, Double(bodyHeight) / Double(pageSize.height))

        let normX = max(0, min(1 - defaultWidth, Double(location.x / pageSize.width)))
        let normY = max(0, min(1 - defaultHeight, Double(location.y / pageSize.height)))

        // zIndex: 1 above the current max so the new element renders
        // on top of any existing text elements on this page.
        let maxZ = elements.map(\.zIndex).max() ?? 0

        let element = PageElement(
            pageId: pageId,
            notebookId: notebookId,
            kind: .text,
            normalizedX: normX,
            normalizedY: normY,
            normalizedWidth: defaultWidth,
            normalizedHeight: defaultHeight,
            zIndex: maxZ + 1
        )
        let content = TextContent(text: "", source: .typed, size: .body)
        element.textContent = content
        modelContext.insert(element)

        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("[TextElement] save failed on create: \(error)")
            #endif
        }

        // Force the next body() to re-fetch the elements list so
        // the new row appears immediately — without bumping, the
        // fetched array can lag a runloop.
        refreshTick &+= 1

        // Select + enter edit mode → keyboard appears.
        selectedId = element.id
        editingId  = element.id
    }
}
