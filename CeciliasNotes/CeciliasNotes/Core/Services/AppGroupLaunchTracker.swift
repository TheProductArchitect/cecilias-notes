import Foundation

/// Cross-target launch tracker, backed by the App Group's shared
/// `UserDefaults`. Two responsibilities:
///
///   • `lastOpenDate` — the wall-clock time the main app last
///     reached `RootView`. Read once at launch to decide whether to
///     show full / compressed / skipped splash. The value is
///     refreshed at the moment of *that read* so the next launch's
///     elapsed-since-last-open is always computed against the
///     previous run.
///   • `markOpened(at:)` — explicit override used when the launch
///     time isn't `Date.now` (e.g. tests, scenario reproduction).
///
/// Lives in the App Group (`group.com.wave.venu.Ink`) so both the
/// main app and the CeciliasNotesWidget extension see the same value. The
/// widget doesn't use this directly today but the spec calls for it
/// to be readable from the extension.
///
/// No network, no telemetry — just a single `Date` written to
/// shared UserDefaults.
enum AppGroupLaunchTracker {

    private static let suiteName    = "group.com.wave.venu.Ink"
    private static let lastOpenKey  = "app.launch.lastOpenDate"

    private static var defaults: UserDefaults? {
        // Falls back to `.standard` in dev builds where the App Group
        // entitlement isn't provisioned — preserves splash skip
        // behaviour locally without crashing if the suite is missing.
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static var lastOpenDate: Date? {
        guard let raw = defaults?.object(forKey: lastOpenKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    /// Stamp `now` (default `Date()`) as the launch time. Idempotent.
    static func markOpened(at date: Date = Date()) {
        defaults?.set(date.timeIntervalSince1970, forKey: lastOpenKey)
    }

    /// Read the previous launch time, then immediately overwrite with
    /// `now` so the next launch sees a fresh anchor. Returns the time
    /// elapsed since the previous launch, or `nil` for a first-ever
    /// launch.
    static func consumeElapsedSinceLastOpen() -> TimeInterval? {
        let previous = lastOpenDate
        markOpened()
        guard let previous else { return nil }
        return Date().timeIntervalSince(previous)
    }
}
