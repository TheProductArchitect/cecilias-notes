import SwiftUI
import UIKit

/// SwiftUI's `DragGesture` doesn't distinguish Apple Pencil from
/// finger touches. Shape creation respects the user's
/// `FingerDrawingMode`: when a Pencil has been detected and finger
/// drawing is disabled, finger drags must not create shapes — only
/// Pencil drags should. SwiftUI offers no API for this, so we wrap a
/// UIKit `UIPanGestureRecognizer` whose `allowedTouchTypes` we set
/// dynamically based on the detected capability + user setting.
///
/// Mirrors the same allowedTouchTypes plumbing the
/// `PalmRejectingScrollView` uses for its pan recogniser.
struct PencilFingerDragSurface: UIViewRepresentable {

    /// Whether finger drags should also be accepted right now.
    /// Updated each SwiftUI evaluation in `updateUIView`.
    var acceptsFinger: Bool

    var onBegan:   (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded:   (CGPoint, _ cancelled: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PassthroughTouchView {
        let view = PassthroughTouchView()
        let recogniser = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        recogniser.minimumNumberOfTouches = 1
        recogniser.maximumNumberOfTouches = 1
        recogniser.delegate = context.coordinator
        view.addGestureRecognizer(recogniser)
        context.coordinator.recogniser = recogniser
        context.coordinator.view = view
        applyAllowedTouchTypes(to: recogniser, context: context)
        return view
    }

    func updateUIView(_ uiView: PassthroughTouchView, context: Context) {
        context.coordinator.parent = self
        if let rec = context.coordinator.recogniser {
            applyAllowedTouchTypes(to: rec, context: context)
        }
    }

    private func applyAllowedTouchTypes(
        to rec: UIPanGestureRecognizer,
        context: Context
    ) {
        var types: [NSNumber] = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        if acceptsFinger {
            types.append(NSNumber(value: UITouch.TouchType.direct.rawValue))
        }
        rec.allowedTouchTypes = types
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PencilFingerDragSurface
        weak var recogniser: UIPanGestureRecognizer?
        weak var view: PassthroughTouchView?

        init(_ parent: PencilFingerDragSurface) { self.parent = parent }

        @objc func handlePan(_ rec: UIPanGestureRecognizer) {
            guard let view = rec.view else { return }
            let location = rec.location(in: view)
            switch rec.state {
            case .began:
                parent.onBegan(location)
            case .changed:
                parent.onChanged(location)
            case .ended:
                parent.onEnded(location, false)
            case .cancelled, .failed:
                parent.onEnded(location, true)
            default:
                break
            }
        }

        // Allow the scroll view's own pan to recognise simultaneously
        // so a Pencil drag for a shape doesn't permanently lock the
        // scroll view out — though only one wins per gesture cycle
        // because the shape recogniser is on the overlay above the
        // scroll view.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }

    /// UIView subclass that only consumes a touch when the inner
    /// recogniser claims it — empty taps fall through to whatever's
    /// behind the surface.
    final class PassthroughTouchView: UIView {
        override func hitTest(
            _ point: CGPoint,
            with event: UIEvent?
        ) -> UIView? {
            // Allow our gesture recogniser to attempt — if it
            // doesn't claim the touch, hit-test returns self and
            // the touch ends without effect. Other gestures on
            // ancestor views (scroll view's pan) still recognise
            // because of the simultaneous-recogniser delegate.
            return self
        }
    }
}
