import Combine
import UIKit

/// Watches the system keyboard and surfaces enough state for SwiftUI
/// surfaces to opt out of keyboard-driven safe-area reflow when the
/// keyboard is *floating* on iPad.
///
/// Background: SwiftUI's default keyboard avoidance shifts the entire
/// layout up to keep focused fields visible. That's the right call for
/// the docked / split keyboards which span the full width of the
/// screen, but wrong for iPad's compact floating keyboard — which
/// occupies a narrow ~370pt patch anywhere on screen and doesn't
/// require the rest of the layout to move at all. Reading
/// `UIResponder.keyboardFrameEndUserInfoKey` and comparing the reported
/// width against the screen lets us tell the two apart.
@MainActor
final class KeyboardObserver: ObservableObject {

    static let shared = KeyboardObserver()

    @Published private(set) var isKeyboardVisible:  Bool    = false
    @Published private(set) var isFloatingKeyboard: Bool    = false
    @Published private(set) var keyboardHeight:     CGFloat = 0

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        updateState(from: note, visible: true)
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        updateState(from: note, visible: true)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        // Defer the @Published writes to the next runloop tick.
        // `UIResponder.keyboardWill{Show,Hide,ChangeFrame}` fire
        // synchronously inside the same runloop tick as the
        // SwiftUI view update that caused the first-responder
        // change — publishing here triggers the "Publishing
        // changes from within view updates" warning and, under
        // sustained churn, can cascade into a render loop.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isKeyboardVisible  = false
            self.isFloatingKeyboard = false
            self.keyboardHeight     = 0
        }
    }

    private func updateState(from note: Notification, visible: Bool) {
        guard let frameEnd = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? CGRect
        else { return }

        // Floating keyboards report a width well below the screen
        // width (~370pt regardless of orientation); docked / split
        // keyboards span the full screen width. A 0.9 ratio cleanly
        // separates the two without depending on a hard-coded 370pt
        // constant that Apple may tune in future iPadOS releases.
        let screenWidth  = UIScreen.main.bounds.width
        let widthRatio   = screenWidth > 0 ? frameEnd.width / screenWidth : 1
        let floating     = widthRatio < 0.9
        let height       = floating ? 0 : frameEnd.height

        // Defer the @Published writes — see `keyboardWillHide`
        // header comment for the SwiftUI view-update race.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isFloatingKeyboard = floating
            self.isKeyboardVisible  = visible
            self.keyboardHeight     = height
        }
    }
}
