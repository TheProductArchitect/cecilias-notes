import Foundation

/// Single source of truth for the "summarise dictations" preference,
/// shared by the iPad (`MeetingSummaryCommit`) and Mac
/// (`MacMeetingSummary`) summary paths and the Settings toggle.
///
/// Default ON. The in-editor floating prompt shown when a dictation
/// starts writes this key so a per-session choice sticks as the new
/// default; Settings → Audio & Transcription exposes the same key.
enum DictationSummaryPreference {
    static let key = "ceciliasnotes.dictation.autoSummary"

    /// `true` when the user wants post-dictation summaries. Absent
    /// key → default ON.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}
