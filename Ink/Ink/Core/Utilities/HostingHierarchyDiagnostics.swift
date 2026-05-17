#if DEBUG
import Foundation
import ObjectiveC.runtime
import UIKit

/// DEBUG-only instrumentation that pinpoints the source of the
///   "Adding '_UIReparentingView' as a subview of UIHostingController.view
///    is not supported"
/// runtime warning.
///
/// **Why the prior `addSubview(_:)` swizzle missed it:** UIKit's
/// public `addSubview(_:)` is *one* entry point, but most internal
/// callers (including SwiftUI's hosting-controller machinery) funnel
/// through the private `_addSubview:positioned:relativeTo:`. Hooking
/// the public selector therefore catches only application-level adds
/// — not the ones that fire the runtime warning.
///
/// This version swizzles `didAddSubview(_:)` instead. `didAddSubview`
/// is documented and is called by every internal add path *after*
/// the subview lands, so we observe every parent/subview pair the
/// system actually wires up.
///
/// To avoid stalling the editor mount (which fires this many times
/// per opening of a notebook), the call-stack capture is moved off
/// the main thread — we snapshot `Thread.callStackSymbols`
/// synchronously (cheap; just walks the current stack) and then
/// dispatch the actual `print` work to a background utility queue.
///
/// Install once from `CeciliasNotesApp.init`:
/// ```swift
/// #if DEBUG
/// HostingHierarchyDiagnostics.installOnce()
/// #endif
/// ```
enum HostingHierarchyDiagnostics {

    /// Feature flag — defaults OFF. The `_UIReparentingView` warning
    /// was conclusively traced to SwiftUI itself (zero Cecilia's Notes frames in
    /// every captured stack — parents are always
    /// `_UIHostingView` / `_UIContextMenuView` /
    /// `PresentationHostingController`). It's a cosmetic Apple-side
    /// warning, not a bug in our code. Leaving the swizzle code here
    /// behind a flag so we can re-enable it cheaply if a future
    /// recurrence ever points back at our binary, but installed=false
    /// by default so we don't pay the per-add overhead.
    static var isEnabled = false

    private static var installed = false
    static let logQueue = DispatchQueue(
        label: "ink.diag.logger",
        qos: .utility
    )

    static func installOnce() {
        guard isEnabled, !installed else { return }
        installed = true

        // Swizzle `didAddSubview(_:)` — invoked from every add path
        // (public, private, layout-driven). Catches what `addSubview:`
        // alone misses.
        guard let original = class_getInstanceMethod(
                  UIView.self,
                  #selector(UIView.didAddSubview(_:))
              ),
              let swizzled = class_getInstanceMethod(
                  UIView.self,
                  #selector(UIView.ink_diag_didAddSubview(_:))
              )
        else {
            print("[CeciliasNotesDiag] Failed to install — selectors not found.")
            return
        }
        method_exchangeImplementations(original, swizzled)
        print("[CeciliasNotesDiag] Hosting hierarchy diagnostics installed (didAddSubview).")
    }
}

extension UIView {

    /// Swizzled `didAddSubview(_:)`. After
    /// `method_exchangeImplementations` the system invokes this body
    /// instead of the original; calling
    /// `ink_diag_didAddSubview(subview)` from here re-enters the
    /// original implementation under its swapped selector.
    @objc func ink_diag_didAddSubview(_ subview: UIView) {
        // Call through to UIKit's original `didAddSubview:` first.
        ink_diag_didAddSubview(subview)

        // Fast subview-class filter. The class-name string compare
        // is the cheapest match short of an `isKind(of:)` against a
        // class we can't reference directly (private SwiftUI type).
        let subviewClassName = NSStringFromClass(type(of: subview))
        guard subviewClassName.contains("ReparentingView") else { return }

        // Capture the call-stack snapshot synchronously on the
        // current thread — it walks the frames in-place, no
        // symbolication yet, so it's cheap. The expensive part is
        // formatting + printing, which we defer off the main
        // thread to avoid blocking editor mount.
        let frames        = Thread.callStackSymbols
        let parentClass   = NSStringFromClass(type(of: self))
        let owningVC      = self.next as? UIViewController
        let ownerClass    = owningVC.map { NSStringFromClass(type(of: $0)) } ?? "<no VC>"

        HostingHierarchyDiagnostics.logQueue.async {
            print("[CeciliasNotesDiag] FOUND _UIReparentingView add")
            print("[CeciliasNotesDiag] parent view: \(parentClass)")
            print("[CeciliasNotesDiag] parent VC:   \(ownerClass)")
            print("[CeciliasNotesDiag] subview:     \(subviewClassName)")
            print("[CeciliasNotesDiag] call stack:")
            for line in frames.prefix(25) {
                print("[CeciliasNotesDiag]   \(line)")
            }
            print("[CeciliasNotesDiag] ──")
        }
    }
}
#endif
