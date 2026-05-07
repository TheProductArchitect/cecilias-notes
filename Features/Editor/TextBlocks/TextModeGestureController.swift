import UIKit

// MARK: - ContentLayerGestureController

/// Transparent UIView that gates finger touches to the correct content overlay.
///
/// Routing logic (evaluated top-to-bottom):
///   1. Stylus touches (.type == .stylus) → always nil → PKCanvasView handles them.
///   2. Audio overlay: always checked regardless of tool — pins must always be tappable.
///   3. Text mode + finger → routes to textOverlay if it can handle the point.
///   4. Non-drawing tool + finger → routes to mediaOverlay if it can handle the point.
///   5. Otherwise → nil → UIScrollView handles pan / pinch.
///
/// Both overlays' isUserInteractionEnabled are kept in sync with the routing flags
/// by CanvasContainerView.updateUIView — the hitTest delegate here is the final gate.
final class ContentLayerGestureController: UIView {

    /// True when the selected tool is .text.
    var isTextMode: Bool = false

    /// True when the selected tool is NOT a drawing tool (pen/pencil/highlighter).
    var isMediaInteractionEnabled: Bool = false

    /// The text block overlay view.
    weak var textOverlay: UIView?

    /// The media attachment overlay view.
    weak var mediaOverlay: UIView?

    /// The audio annotation pins overlay view — always interactive.
    weak var audioOverlay: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Apple Pencil: never intercept — let it fall through to PKCanvasView.
        if let touches = event?.allTouches,
           touches.contains(where: { $0.type == .stylus }) {
            return nil
        }

        // Audio pins: always routed regardless of current tool.
        if let overlay = audioOverlay, overlay.isUserInteractionEnabled {
            let converted = convert(point, to: overlay)
            if let hit = overlay.hitTest(converted, with: event) { return hit }
        }

        // Text mode: give text overlay first crack.
        if isTextMode, let overlay = textOverlay, overlay.isUserInteractionEnabled {
            let converted = convert(point, to: overlay)
            if let hit = overlay.hitTest(converted, with: event) { return hit }
        }

        // Non-drawing mode: let media overlay handle taps on images.
        if isMediaInteractionEnabled, let overlay = mediaOverlay, overlay.isUserInteractionEnabled {
            let converted = convert(point, to: overlay)
            if let hit = overlay.hitTest(converted, with: event) { return hit }
        }

        // Nothing handled it — pass through to UIScrollView.
        return nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Always active since audio overlay is always routed.
        true
    }
}

// MARK: - Backwards-compatible typealias
// Stage 5 code referenced TextModeGestureController; keep it alive during the
// transition. New code should use ContentLayerGestureController directly.
typealias TextModeGestureController = ContentLayerGestureController
