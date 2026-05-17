import PencilKit
import UIKit

/// `PKCanvasView` subclass that refuses every `UIHoverGestureRecognizer`
/// the system tries to install on it.
///
/// **Why this exists**: on iPadOS 17.5+ with Apple Pencil Pro, the
/// system attaches a `UIHoverGestureRecognizer` to `PKCanvasView` to
/// power the Pencil-hover stroke preview. Each hover event triggers a
/// layout pass that visibly shifts the canvas's already-rendered
/// strokes downward — concretely, drawing a few strokes then hovering
/// the Pencil over the page makes the strokes jump. We don't render a
/// hover preview anywhere in the editor and the side-effect on the
/// drawing buffer is a hard regression.
///
/// **Why a subclass and not a post-hoc disable**: the previous fix
/// walked `gestureRecognizers` and disabled hover recognisers on a
/// `DispatchQueue.main.async` after canvas mount. PKCanvasView appears
/// to install the recogniser **lazily on the first hover event**, not
/// on mount, so the post-hoc walk was a no-op. Overriding
/// `addGestureRecognizer(_:)` intercepts at install time, which is
/// the only point at which "the recogniser definitely exists" is
/// guaranteed. Pencil double-tap + squeeze still work — they go
/// through `UIPencilInteraction`, not gesture recognisers.
///
/// Pencil-down drawing is unaffected: that path uses
/// `touchesBegan/Moved/Ended` on the canvas, not a hover recogniser.
///
/// See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.D.
final class InkPKCanvasView: PKCanvasView {

    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        if gestureRecognizer is UIHoverGestureRecognizer {
            // Refuse silently. The system only adds these from its own
            // internal setup — there's no caller in our code that adds
            // hover recognisers to the canvas.
            return
        }
        super.addGestureRecognizer(gestureRecognizer)
    }
}
