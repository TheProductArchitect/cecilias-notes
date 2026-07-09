import PencilKit

/// Lightweight editor inputs for per-page overlays. Passing this
/// instead of the full `EditorViewModel` keeps overlays from
/// re-rendering on unrelated `@Published` churn (zoom ticks,
/// keyboard state, recording session, etc.).
struct EditorPageOverlayInputs: Equatable {
    var selectedTool: CeciliasNotesTool
    var canvasView: PKCanvasView?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedTool.identity == rhs.selectedTool.identity
    }
}
