import SwiftUI

/// One of eight cover tones a notebook can wear. Tones are *not*
/// theme-adaptive — a parchment notebook stays parchment in both light
/// and dark mode. The text colour and ghost-letter colour are paired
/// with the surface they sit on, not with the system theme.
///
/// `inkBlack` is reserved for explicit user choice — the auto-assigner
/// in `CoverToneAssigner` never picks it, so users who deliberately go
/// near-black are visually distinct from the default rotation.
enum NotebookCoverTone: String, Codable, CaseIterable {
    case parchment
    case studioWhite
    case ash
    case coal
    case midnight
    case moss
    case dusk
    case inkBlack

    /// Cover background. Fixed across themes.
    var background: Color {
        switch self {
        case .parchment:    return Color(hex: "#f5f0e8")
        case .studioWhite:  return Color(hex: "#ffffff")
        case .ash:          return Color(hex: "#e8e8e4")
        case .coal:         return Color(hex: "#2e2e2e")
        case .midnight:     return Color(hex: "#1a1a2e")
        case .moss:         return Color(hex: "#2a2e28")
        case .dusk:         return Color(hex: "#2e2228")
        case .inkBlack:     return Color(hex: "#0a0a0a")
        }
    }

    /// Foreground text colour paired with the background. Also fixed
    /// across themes.
    var textColor: Color {
        switch self {
        case .parchment:    return Color(hex: "#1a1209")
        case .studioWhite,
             .ash:          return Color(hex: "#0a0a0a")
        case .coal,
             .midnight,
             .moss,
             .dusk,
             .inkBlack:     return Color(hex: "#ffffff")
        }
    }

    /// Tint for the oversized ghost letter that bleeds behind cover
    /// content. 5% black on light tones, 5% white on dark.
    var ghostLetterColor: Color {
        isLight
            ? Color.black.opacity(0.05)
            : Color.white.opacity(0.05)
    }

    /// True when the cover needs a 0.5px hairline border so it doesn't
    /// disappear into a white surface (only studio-white).
    var requiresBorder: Bool { self == .studioWhite }

    /// True for the three light-stock tones. Drives ghost-letter colour
    /// and the "is this a light cover" decision points elsewhere.
    var isLight: Bool {
        switch self {
        case .parchment, .studioWhite, .ash: return true
        default:                             return false
        }
    }
}
