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
final class CeciliasNotesPKCanvasView: PKCanvasView {

    /// Set by the canvas coordinator. Given a hit-test point in this
    /// canvas's coordinate space and the originating event, returns
    /// `true` when the canvas should yield the touch to the overlay
    /// layer beneath it — i.e. a *finger* tap landing on an interactive
    /// element (audio strip, image, sticky, text) while a drawing tool
    /// is active. Returning nil from `hitTest` lets UIKit continue to
    /// the sibling overlay below, so the element's controls receive the
    /// tap. Pencil touches must always draw, so the closure returns
    /// `false` for them. Nil closure → behave exactly like PKCanvasView.
    var shouldYieldTouchToOverlay: ((CGPoint, UIEvent?) -> Bool)?

    /// Per-canvas undo scope. PKCanvasView registers its stroke undo
    /// entries with `self.undoManager`, which by default resolves to
    /// the shared UIWindow manager through the responder chain. The
    /// continuous canvas mounts one PKCanvasView per warm-band page,
    /// so with the shared manager every page's strokes interleaved on
    /// ONE stack: tapping undo could silently revert a stroke on a
    /// different (even off-screen) page, and unmounting a canvas on
    /// scroll left dead entries behind — the undo button lit up but
    /// tapping it did nothing. A private manager per canvas scopes
    /// undo to the page the user is looking at; the toolbar reads
    /// `viewModel.canvasView?.undoManager`, which always points at
    /// the active page's canvas.
    private let pageUndoManager = UndoManager()
    override var undoManager: UndoManager? { pageUndoManager }

    /// Opt out of iPadOS's system-wide editing gestures (three-finger
    /// swipe left/right = undo/redo, three-finger tap = the edit HUD).
    /// PencilKit registers every stroke with `undoManager`, so a
    /// multi-finger scroll across an inked canvas routinely read as
    /// the undo swipe — users watched strokes "undo themselves"
    /// without ever touching the undo button. The toolbar's undo /
    /// redo buttons and the squeeze wheel call `undoManager`
    /// directly, so they keep working.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        .none
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if shouldYieldTouchToOverlay?(point, event) == true {
            return nil
        }
        return super.hitTest(point, with: event)
    }

    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        if gestureRecognizer is UIHoverGestureRecognizer {
            // Refuse silently. The system only adds these from its own
            // internal setup — there's no caller in our code that adds
            // hover recognisers to the canvas.
            return
        }
        super.addGestureRecognizer(gestureRecognizer)
    }

    /// Step 3: route every incoming touch through
    /// `InputCapabilityDetector` so the first pencil touch on any
    /// canvas flips `hasPencil` to true. The detector itself
    /// no-ops after the first hit, so the per-touch cost is one
    /// `UserDefaults.bool(forKey:)` read on the hot drawing path.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        InputCapabilityDetector.shared.recordTouches(touches)
        super.touchesBegan(touches, with: event)
    }
}
