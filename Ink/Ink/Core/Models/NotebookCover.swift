import Foundation

/// Curated cover presets surfaced in the Customise panel carousel.
///
/// Each case maps to an existing `(coverColorHex, CoverTexture)` pair —
/// the same fields the renderer already consumes for `NotebookCardView`.
/// This is a *projection* over the existing cover surface, not a schema
/// addition; we don't store a `NotebookCover` in SwiftData. The user's
/// last-used choice is persisted via `@AppStorage` and applied at create
/// time. After creation, the notebook lives in terms of its underlying
/// `coverColorHex` + `coverTexture`, so pre-existing notebooks are
/// untouched.
public enum NotebookCover: String, CaseIterable, Codable, Sendable {
    case cream
    case parchment
    case sand
    case blush
    case terracotta
    case sage
    case moss
    case ocean
    case midnight
    case lavender
    case slate
    case charcoal

    public var displayName: String {
        switch self {
        case .cream:      return "Cream"
        case .parchment:  return "Parchment"
        case .sand:       return "Sand"
        case .blush:      return "Blush"
        case .terracotta: return "Terracotta"
        case .sage:       return "Sage"
        case .moss:       return "Moss"
        case .ocean:      return "Ocean"
        case .midnight:   return "Midnight"
        case .lavender:   return "Lavender"
        case .slate:      return "Slate"
        case .charcoal:   return "Charcoal"
        }
    }

    /// The hex colour the renderer should fill the cover with.
    public var colorHex: String {
        switch self {
        case .cream:      return "#F5EFE0"
        case .parchment:  return "#E8DEC2"
        case .sand:       return "#D8C7A4"
        case .blush:      return "#E8C2C2"
        case .terracotta: return "#B86B4A"
        case .sage:       return "#9DB39C"
        case .moss:       return "#5C7A5A"
        case .ocean:      return "#3A6B8C"
        case .midnight:   return "#1F2A44"
        case .lavender:   return "#B8A8D0"
        case .slate:      return "#6E7480"
        case .charcoal:   return "#3A3A3A"
        }
    }

    /// Texture overlay to pair with the colour. Curated rather than
    /// permuting every (colour × texture) — some pairings just look bad.
    public var texture: CoverTexture {
        switch self {
        case .cream, .parchment, .sand:    return .linen
        case .blush, .terracotta:           return .craft
        case .sage, .moss:                  return .ruled
        case .ocean, .midnight:             return .grid
        case .lavender:                     return .dot
        case .slate, .charcoal:             return .none
        }
    }

    /// Initial / default value used by `@AppStorage`.
    public static let `default`: NotebookCover = .cream

    // MARK: AppStorage bridge — RawRepresentable<String> already gives us
    // `@AppStorage` compatibility on iOS 17+, but we keep an explicit helper
    // for callers that work with strings (e.g. legacy hex defaults).

    public static func from(rawValue: String?) -> NotebookCover {
        if let raw = rawValue, let v = NotebookCover(rawValue: raw) { return v }
        return .default
    }
}
