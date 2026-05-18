import Foundation
import UIKit

/// Tracks whether the current device has ever seen an Apple Pencil
/// touch. Once true, stays true across launches — there's no useful
/// signal for "pencil is no longer paired" and intermittent pairing
/// shouldn't flicker the canvas's drawing policy back to anyInput
/// every time the user puts their Pencil down.
///
/// Detection is passive: callers route `UITouch` events through
/// `recordPencilSeen(from:)`. The first pencil-type touch flips the
/// stored bit and posts `.inputCapabilityChanged` so observers can
/// re-apply input policies.
///
/// On first install `hasPencil` is `false` — the user is treated as
/// finger-only until proven otherwise. This is the safer default:
/// fresh installs without a Pencil get finger drawing in `.auto`
/// mode, and a Pencil user gets pencilOnly the moment they first
/// touch the canvas.
final class InputCapabilityDetector: @unchecked Sendable {

    static let shared = InputCapabilityDetector()

    private let userDefaults: UserDefaults
    private let hasSeenPencilKey = "input.hasSeenPencil"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Has a pencil touch ever been observed on this device?
    var hasPencil: Bool {
        userDefaults.bool(forKey: hasSeenPencilKey)
    }

    /// Inspect a UITouch — if it's a pencil and we haven't flagged
    /// yet, flag and post the change notification. No-op for
    /// non-pencil touches and for subsequent pencil touches after
    /// the first.
    func recordTouch(_ touch: UITouch) {
        guard touch.type == .pencil else { return }
        guard !hasPencil else { return }
        userDefaults.set(true, forKey: hasSeenPencilKey)
        #if DEBUG
        print("[Input] first pencil touch observed — hasPencil flipped to true")
        #endif
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .inputCapabilityChanged,
                object: nil
            )
        }
    }

    /// Bulk variant for `Set<UITouch>` from `touchesBegan(_:with:)`.
    func recordTouches(_ touches: Set<UITouch>) {
        guard !hasPencil else { return }
        for touch in touches where touch.type == .pencil {
            recordTouch(touch)
            return  // first hit is enough
        }
    }

    /// Test/debug — flips the flag explicitly. Production code uses
    /// `recordTouch(_:)` exclusively.
    func _forceHasPencil(_ value: Bool) {
        userDefaults.set(value, forKey: hasSeenPencilKey)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .inputCapabilityChanged,
                object: nil
            )
        }
    }
}

extension Notification.Name {
    /// Fires when `InputCapabilityDetector.hasPencil` changes (first
    /// pencil touch, or test-only reset). The canvas listens to
    /// re-apply its drawing policy without waiting for a settings
    /// change.
    static let inputCapabilityChanged = Notification.Name("input.capabilityChanged")
}
