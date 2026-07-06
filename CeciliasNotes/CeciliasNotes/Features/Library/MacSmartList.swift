import Foundation

/// macOS sidebar smart filters (Today / This week / Untagged / Recording).
enum MacSmartList: String, CaseIterable, Identifiable {
    case today
    case thisWeek
    case untagged
    case recording

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today:     return "today"
        case .thisWeek:  return "this week"
        case .untagged:  return "untagged"
        case .recording: return "recording"
        }
    }

    var systemImage: String {
        switch self {
        case .today:     return "sun.max"
        case .thisWeek:  return "calendar"
        case .untagged:  return "tag.slash"
        case .recording: return "waveform"
        }
    }
}
