import Combine
import Foundation
import GameController

/// Tracks hardware-keyboard modifier-key state globally so any
/// SwiftUI view can read the current Shift state without needing
/// to be the first responder.
///
/// Observes `GCKeyboard.coalesced` (GameController framework —
/// available on all iOS 14+ devices; no entitlement required).
/// When no hardware keyboard is connected, `isShiftHeld` stays
/// false and the feature is transparently disabled.
///
/// **Usage:**
/// ```swift
/// @ObservedObject private var modifierKeys = ModifierKeyObserver.shared
///
/// // in a gesture:
/// if modifierKeys.isShiftHeld { ... }
/// ```
@MainActor
final class ModifierKeyObserver: ObservableObject {

    static let shared = ModifierKeyObserver()

    /// True while the Shift key is physically held on a connected
    /// hardware keyboard. Always false when no hardware keyboard is
    /// attached.
    @Published private(set) var isShiftHeld: Bool = false

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(keyboardConnected(_:)),
            name: .GCKeyboardDidConnect,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(keyboardDisconnected(_:)),
            name: .GCKeyboardDidDisconnect,
            object: nil
        )
        if let keyboard = GCKeyboard.coalesced {
            attachHandlers(to: keyboard)
        }
    }

    @objc private func keyboardConnected(_ note: Notification) {
        if let keyboard = note.object as? GCKeyboard {
            attachHandlers(to: keyboard)
        }
    }

    @objc private func keyboardDisconnected(_ note: Notification) {
        isShiftHeld = false
    }

    private func attachHandlers(to keyboard: GCKeyboard) {
        let handler: GCControllerButtonValueChangedHandler = { [weak self] _, _, _ in
            Task { @MainActor [weak self] in self?.refreshShiftState() }
        }
        let input = keyboard.keyboardInput
        input?.button(forKeyCode: .leftShift)?.pressedChangedHandler  = handler
        input?.button(forKeyCode: .rightShift)?.pressedChangedHandler = handler
    }

    private func refreshShiftState() {
        guard let input = GCKeyboard.coalesced?.keyboardInput else {
            isShiftHeld = false
            return
        }
        isShiftHeld =
            (input.button(forKeyCode: .leftShift)?.isPressed  ?? false) ||
            (input.button(forKeyCode: .rightShift)?.isPressed ?? false)
    }
}
