import Foundation
import os

/// Tracks whether the current / previous process session wedged the
/// main thread. Used by launch recovery so a force-quit after an
/// ANR doesn't auto-resume the notebook that caused the freeze.
///
/// The in-memory latch is updated from the watchdog queue (not via
/// `DispatchQueue.main.async`) so a true ANR still records a hang
/// before the user backgrounds the app.
enum SessionHealth {

    private nonisolated static let hangFlagKey = "ceciliasnotes.session.hadMainThreadHang"
    private nonisolated static let latchLock = OSAllocatedUnfairLock(initialState: false)

    /// Call from the watchdog queue when the main runloop misses a
    /// ping. `nonisolated` is the point: it runs while main is HUNG,
    /// so it must never require the main actor — the lock and
    /// UserDefaults are the thread-safety story.
    nonisolated static func recordMainThreadHangFromWatchdog() {
        latchLock.withLock { $0 = true }
        UserDefaults.standard.set(true, forKey: hangFlagKey)
    }

    /// Whether the current session has already been flagged as hung.
    static var hadHangThisSession: Bool {
        latchLock.withLock { $0 }
    }

    /// Read + clear the cross-launch hang flag. Returns `true` when
    /// the *previous* session recorded a main-thread stall.
    static func consumeHadHangOnPriorSession() -> Bool {
        let hadHang = UserDefaults.standard.bool(forKey: hangFlagKey)
        if hadHang {
            UserDefaults.standard.set(false, forKey: hangFlagKey)
        }
        latchLock.withLock { $0 = false }
        return hadHang
    }
}

extension SessionHealth: @unchecked Sendable {}
