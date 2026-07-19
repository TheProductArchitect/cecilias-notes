import PencilKit

/// Lightweight editor inputs for per-page overlays. Passing this
/// instead of the full `EditorViewModel` keeps overlays from
/// re-rendering on unrelated `@Published` churn (zoom ticks,
/// keyboard state, recording session, etc.).
struct EditorPageOverlayInputs: Equatable {
    var selectedTool: CeciliasNotesTool
    var canvasView: PKCanvasView?

    /// Canvas identity is part of equality. Overlays register
    /// element undo entries with `canvasView?.undoManager` (each
    /// canvas owns a private per-page manager), and the coordinator
    /// skips overlay-input refreshes when inputs compare equal. When
    /// equality ignored the canvas, a page whose overlay mounted
    /// before its canvas (the overlay warm band is wider) kept
    /// `canvasView == nil` forever — element deletes then registered
    /// undo into NOTHING, and the toolbar's undo skipped the delete
    /// and replayed the previous stroke entry instead.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedTool.identity == rhs.selectedTool.identity
            && lhs.canvasView === rhs.canvasView
    }
}
