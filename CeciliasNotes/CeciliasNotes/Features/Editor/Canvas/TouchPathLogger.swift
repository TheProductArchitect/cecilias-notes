import UIKit

#if DEBUG
/// DIAGNOSTIC — observe-only tap logging across the editor's view
/// hierarchy.
///
/// Image / sticky / audio-button gestures have been "fixed" at the
/// modifier-order level 4+ times and keep regressing. The element
/// views render (`[GestureAudit] … body render` fires) but their
/// `[ImageGesture] / [StickyGesture] / [AudioPlay] 1. tap received`
/// logs never fire — something ABOVE the element view absorbs the
/// touch, and no patch has identified what.
///
/// `attach(to:label:)` installs a non-consuming
/// `UITapGestureRecognizer` on a layer. When a tap reaches that
/// layer it logs `[TouchPath] <label> tap at <point>` and lets the
/// touch pass straight through (`cancelsTouchesInView = false`,
/// plus a delegate that recognises simultaneously with everything
/// and blocks nothing). Tapping an element and reading the
/// `[TouchPath]` sequence shows exactly which layer the touch dies
/// at — the layer that logs last is the absorber (or the one just
/// below it).
///
/// DEBUG-only. No behaviour change: every recogniser is pass-through.
@MainActor
enum TouchPathLogger {

    /// Pass-through delegate — recognise alongside every other
    /// recogniser, require nothing to fail, be required by nothing.
    /// Guarantees the logger never alters touch delivery.
    private final class PassThroughDelegate: NSObject, UIGestureRecognizerDelegate {
        static let shared = PassThroughDelegate()

        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldRequireFailureOf other: UIGestureRecognizer
        ) -> Bool { false }

        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool { false }
    }

    /// Recogniser action target. UIKit does not strongly retain a
    /// recogniser's target, so each `Target` is kept alive as an
    /// associated object on the recogniser it serves.
    private final class Target: NSObject {
        let label: String
        init(label: String) { self.label = label }

        @objc func fire(_ g: UITapGestureRecognizer) {
            let loc = g.location(in: nil)   // window coordinates
            print("[TouchPath] \(label) tap at \(loc)")
        }
    }

    private static var targetKey: UInt8 = 0

    /// Install an observe-only tap logger on `view`. Safe to call
    /// repeatedly; each call adds one recogniser.
    static func attach(to view: UIView, label: String) {
        let target = Target(label: label)
        let tap = UITapGestureRecognizer(
            target: target, action: #selector(Target.fire(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan   = false
        tap.delaysTouchesEnded   = false
        tap.delegate             = PassThroughDelegate.shared
        // Retain the target for the recogniser's lifetime.
        objc_setAssociatedObject(
            tap, &targetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        view.addGestureRecognizer(tap)
        print("[TouchPath] installed logger '\(label)' on \(type(of: view))")
    }
}
#endif
