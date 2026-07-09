import SwiftData
import SwiftUI

/// Per-page render layer for V6 `PageElement(kind: .stickyNote)`.
/// Step 7 — replaces the legacy `StickyNotesOverlayView` +
/// `StickyNoteStore` UserDefaults pipeline.
///
/// Interaction model (deliberate deviations from `TextElementsOverlayView`):
///   • Sticky tool + tap empty area → create a sticky at the tap
///     location, enter edit mode immediately.
///   • Cursor mode + tap on sticky → enter edit mode immediately
///     (single-tap-to-edit, not the text element's two-tap).
///   • Cursor mode + long-press on sticky → select without editing
///     (selection chrome surfaces colour picker + delete).
///   • Tap outside any sticky → exit edit / deselect.
///
/// Layer ordering: stickies render ABOVE text and images in the
/// host stack — they are "floating notes" on top of page content.
struct StickyNoteElementsOverlayView: View, Equatable {

    let inputs: EditorPageOverlayInputs
    let viewModel: EditorViewModel
    let pageId: UUID
    let notebookId: UUID
    let coordinateSpace: PageCoordinateSpace

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pageId == rhs.pageId
            && lhs.notebookId == rhs.notebookId
            && lhs.coordinateSpace.baseSize == rhs.coordinateSpace.baseSize
            && lhs.inputs == rhs.inputs
    }

    /// `StorageService.shared.container.mainContext` resolved
    /// directly — UIHostingController instances built inside the
    /// canvas coordinator don't inherit the SwiftUI root
    /// environment, same constraint as `TextElementsOverlayView`.
    private var modelContext: ModelContext {
        StorageService.shared.container.mainContext
    }
    @Environment(\.theme) private var theme

    @State private var selectedId: UUID?
    @State private var editingId:  UUID?
    @State private var cachedElements: [PageElement] = []

    private var pageSize: CGSize { coordinateSpace.baseSize }

    /// Tools that allow sticky interaction (tap-to-edit, long-press
    /// to select). Drawing tools fall through to the canvas.
    private var allowsInteraction: Bool {
        inputs.selectedTool.isCursorMode
            || inputs.selectedTool.isStickyNoteMode
    }

    /// Whether to mount the full-page background tap layer.
    ///
    /// OPEN_ISSUES #1 — element-tap gesture absorption. A full-page
    /// `.contentShape` tap catcher absorbs every tap on the page, so
    /// a catcher mounted while idle starves the overlays stacked
    /// below this one. It only does work with an active selection /
    /// edit to dismiss, or in sticky mode (empty tap creates a
    /// card) — mount it only then.
    private var showsBackgroundCatcher: Bool {
        guard allowsInteraction else { return false }
        return selectedId != nil
            || editingId != nil
            || inputs.selectedTool.isStickyNoteMode
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background placement / dismiss layer — see
            // `showsBackgroundCatcher`. In sticky-tool mode an empty
            // tap creates; with an active selection / edit an empty
            // tap exits it.
            if showsBackgroundCatcher {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        handleBackgroundTap(at: location)
                    }
            }

            ForEach(cachedElements, id: \.id) { element in
                if let content = element.stickyNoteContent {
                    StickyNoteElementView(
                        element: element,
                        content: content,
                        pageSize: pageSize,
                        isSelected: bindingForSelected(elementId: element.id),
                        isEditing:  bindingForEditing(elementId: element.id),
                        onDelete:        { delete(element) },
                        onRequestSelect: { handleLongPress(element) },
                        onRequestEdit:   { handleTap(element) }
                    )
                }
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onAppear { reloadElements() }
        .onChange(of: inputs.selectedTool.identity) { _, newValue in
            // Tool change away from interactive tools clears selection /
            // editing state, mirroring `TextElementsOverlayView`.
            if newValue != .cursor && newValue != .stickyNote {
                exitEditAndDeselect()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .stickyNotesChanged)
        ) { _ in reloadElements() }
    }

    // MARK: - Fetch

    private func reloadElements() {
        cachedElements = PageElementOverlayFetch.elements(
            pageId: pageId,
            kind: .stickyNote,
            context: modelContext
        )
        if let selected = selectedId,
           !cachedElements.contains(where: { $0.id == selected }) {
            selectedId = nil
        }
        if let editing = editingId,
           !cachedElements.contains(where: { $0.id == editing }) {
            editingId = nil
        }
    }

    // MARK: - Tap / long-press handling

    private func handleBackgroundTap(at location: CGPoint) {
        // Editing or selected → exit first; sticky-tool empty tap on
        // a clean overlay creates a new card.
        if editingId != nil || selectedId != nil {
            exitEditAndDeselect()
            return
        }
        if inputs.selectedTool.isStickyNoteMode {
            createNewSticky(at: location)
        }
    }

    /// Tap on an existing sticky — single-tap-to-edit per the Step 7
    /// UX call.
    private func handleTap(_ element: PageElement) {
        selectedId = element.id
        editingId  = element.id
    }

    /// Long-press on an existing sticky — surfaces selection chrome
    /// without dropping the keyboard. Lets the user re-colour or
    /// delete without entering edit mode.
    private func handleLongPress(_ element: PageElement) {
        selectedId = element.id
        editingId  = nil
    }

    private func exitEditAndDeselect() {
        editingId  = nil
        selectedId = nil
        // Mirror upward so the state machine exits
        // `.stickyNoteEditing(_:)`. Without this, a sticky that
        // exited edit via background-tap left the view-model's
        // `editingStickyNoteId` set, jamming the state machine.
        if viewModel.editingStickyNoteId != nil {
            viewModel.editingStickyNoteId = nil
        }
    }

    // MARK: - Selection bindings

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
                    // Mirror upward so EditorStateMachine knows a
                    // sticky-editing mode is active.
                    viewModel.editingStickyNoteId = elementId
                } else if editingId == elementId {
                    editingId = nil
                    if viewModel.editingStickyNoteId == elementId {
                        viewModel.editingStickyNoteId = nil
                    }
                }
            }
        )
    }

    // MARK: - Mutations

    private func createNewSticky(at location: CGPoint) {
        let normCenter = CGPoint(
            x: max(0, min(1, location.x / pageSize.width)),
            y: max(0, min(1, location.y / pageSize.height))
        )
        guard let element = StickyNoteCommit.createSticky(
            atNormalizedCenter: normCenter,
            pageId: pageId,
            notebookId: notebookId,
            pageSize: pageSize,
            context: modelContext
        ) else { return }

        reloadElements()
        selectedId = element.id
        editingId  = element.id
        viewModel.editingStickyNoteId = element.id
        PageElementUndo.registerCreate(
            elementId: element.id,
            kind: .stickyNote,
            canvas: inputs.canvasView,
            actionName: "Create Sticky"
        )
        // Mirror the stroke + shape auto-add trigger so dropping a
        // sticky near the bottom of the last page grows the
        // notebook continuously, regardless of which tool the user
        // is reaching for.
        viewModel.considerAutoAddAfterElement(
            onPageId: pageId,
            normalizedMaxY: element.normalizedY + element.normalizedHeight
        )
    }

    private func delete(_ element: PageElement) {
        let id = element.id
        PageElementUndo.registerDelete(
            elementId: id,
            kind: .stickyNote,
            canvas: inputs.canvasView,
            actionName: "Delete Sticky Note"
        )
        StickyNoteCommit.softDelete(elementId: id, context: modelContext)
        if selectedId == id { selectedId = nil }
        if editingId  == id { editingId  = nil }
        if viewModel.editingStickyNoteId == id {
            viewModel.editingStickyNoteId = nil
        }
        reloadElements()
    }
}
