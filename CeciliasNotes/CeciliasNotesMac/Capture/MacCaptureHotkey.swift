import AppKit

/// User-configurable global quick-capture shortcut (Settings → Capture).
enum MacCaptureHotkey: String, CaseIterable, Identifiable {
    case optionCommandSpace = "optionCommandSpace"
    case controlCommandSpace = "controlCommandSpace"
    case commandShiftN = "commandShiftN"
    case disabled = "disabled"

    var id: String { rawValue }

    static let storageKey = "mac.capture.globalHotkey"

    static var current: MacCaptureHotkey {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? MacCaptureHotkey.optionCommandSpace.rawValue
        return MacCaptureHotkey(rawValue: raw) ?? .optionCommandSpace
    }

    var label: String {
        switch self {
        case .optionCommandSpace: return "⌥⌘Space"
        case .controlCommandSpace: return "⌃⌘Space"
        case .commandShiftN: return "⌘⇧N"
        case .disabled: return "Off"
        }
    }

    func matches(_ event: NSEvent) -> Bool {
        switch self {
        case .disabled:
            return false
        case .optionCommandSpace:
            return event.modifierFlags.contains([.command, .option])
                && event.charactersIgnoringModifiers?.lowercased() == " "
        case .controlCommandSpace:
            return event.modifierFlags.contains([.command, .control])
                && event.charactersIgnoringModifiers?.lowercased() == " "
        case .commandShiftN:
            return event.modifierFlags.contains([.command, .shift])
                && event.charactersIgnoringModifiers?.lowercased() == "n"
        }
    }
}
