import UIKit

/// Fix 2 — gates the iOS 26 alternate-icon swap behind two state
/// conditions so `LSIconAlertManager` can acquire its alert-token.
///
/// Background: `setAlternateIconName(_:)` fails near onboarding
/// completion — EAGAIN, then `NSCocoaErrorDomain 3072 "cancelled"`.
/// Device logs show `UIKeyboardImpl` snapshotting in a "not in
/// visible window" state between attempts. Hypothesis: the
/// onboarding name field's keyboard is mid-dismiss when the swap
/// fires, and the keyboard layer's teardown blocks the icon-change
/// alert's presentation-token acquisition.
///
/// `whenReady(_:)` defers its completion until BOTH:
///   1. the scene is foreground-active, and
///   2. the keyboard is fully dismissed (a `keyboardDidHide` with no
///      later `keyboardDidShow`).
///
/// A 10s timeout fires the completion anyway so a missed
/// notification can't strand the icon update forever.
///
/// IMPORTANT: reference `IconUpdateGate.shared` early in app launch
/// (see `CeciliasNotesApp`) so its keyboard observers are installed
/// BEFORE the onboarding text field raises the keyboard — otherwise
/// the gate can't know a keyboard is currently up and fires early.
@MainActor
final class IconUpdateGate {

    static let shared = IconUpdateGate()

    private var keyboardVisible: Bool = false
    private var sceneActive: Bool
    private var pendingCompletion: (() -> Void)?

    private init() {
        // Seed scene state from the current world — the gate is
        // often created while a scene is already foreground-active,
        // and `didActivateNotification` won't re-fire for it.
        sceneActive = UIApplication.shared.connectedScenes.contains {
            $0.activationState == .foregroundActive
        }

        let center = NotificationCenter.default

        center.addObserver(
            forName: UIResponder.keyboardDidShowNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardVisible = true
                #if DEBUG
                print("[BrandIcon][diag] gate — keyboardDidShow")
                #endif
            }
        }
        center.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keyboardVisible = false
                #if DEBUG
                print("[BrandIcon][diag] gate — keyboardDidHide")
                #endif
                self.checkAndFire()
            }
        }
        center.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sceneActive = true
                #if DEBUG
                print("[BrandIcon][diag] gate — scene didActivate")
                #endif
                self.checkAndFire()
            }
        }
        center.addObserver(
            forName: UIScene.willDeactivateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sceneActive = false
                #if DEBUG
                print("[BrandIcon][diag] gate — scene willDeactivate")
                #endif
            }
        }
    }

    /// No-op accessor — referencing it forces `init` (and the
    /// keyboard observers) to run early. Call once at app launch.
    func prime() {}

    /// Run `completion` once the gate is ready (scene active +
    /// keyboard dismissed), or after a 10s safety timeout.
    func whenReady(_ completion: @escaping () -> Void) {
        if isReady {
            #if DEBUG
            print("[BrandIcon][diag] gate ready immediately — firing")
            #endif
            completion()
            return
        }
        #if DEBUG
        print("[BrandIcon][diag] gate waiting — keyboardVisible=\(keyboardVisible) sceneActive=\(sceneActive)")
        #endif
        pendingCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let pending = self.pendingCompletion else { return }
            #if DEBUG
            print("[BrandIcon][diag] gate timeout (10s) — firing anyway")
            #endif
            self.pendingCompletion = nil
            pending()
        }
    }

    private var isReady: Bool { sceneActive && !keyboardVisible }

    private func checkAndFire() {
        guard isReady, let pending = pendingCompletion else { return }
        #if DEBUG
        print("[BrandIcon][diag] gate now ready — firing pending completion")
        #endif
        pendingCompletion = nil
        pending()
    }
}
