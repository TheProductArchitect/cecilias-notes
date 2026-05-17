import SwiftUI
import UIKit

// MARK: - Theme

/// Single source of truth for every theme-driven colour and asset in the
/// app. Two instances ship in 1.0 — `Theme.default` (light) and
/// `Theme.midnight` (dark). Add a third by creating another static instance
/// and appending to `Theme.all`; no other code needs to change.
///
/// Selection is owned by `ThemeManager`. Views read the current theme via
/// `@Environment(\.theme)`. Non-SwiftUI code paths can call
/// `ThemeManager.shared.current` directly.
///
/// Hex values land here from `CeciliasNotesColors.swift`'s previous dynamic
/// providers (Phase A inventory), preserving the values that were tuned in
/// device testing. Per-token light/dark values are split across the two
/// static instances rather than living in `Color { trait in … }` closures.
public struct Theme: Identifiable, Equatable, Hashable {

    // MARK: Identity

    public let id: String                                  // "default" | "midnight"
    public let displayName: String                         // "Default" | "Midnight"
    public let interfaceStyle: UIUserInterfaceStyle        // .light | .dark

    // MARK: Foundation

    /// Window-level background. The colour behind everything else.
    public let background: Color
    /// Panels, cards, sheets — the default surface that sits on top of
    /// `background`.
    public let surface: Color
    /// Floating chrome that sits above `surface` (popovers, hover states,
    /// the recording controls panel). One tier above `surface`.
    public let surfaceElevated: Color

    // MARK: Foreground tiers

    /// Primary text and dominant icon colour.
    public let foreground: Color
    /// Secondary text — section labels, captions, "updated 5m ago".
    public let foregroundMuted: Color
    /// Tertiary text — placeholders, deemphasised metadata.
    public let foregroundSubtle: Color

    // MARK: Recessive greys (Phase A2 — 5 tuned tiers from CeciliasNotesColors)

    /// Most-contrasted recessive: legible-but-quiet text (sidebar labels,
    /// sub-titles). Stays readable; doesn't compete with `foreground`.
    public let recessivePrimary: Color
    /// Absent text — eyebrow labels, splash signoff. Reads as "present
    /// but stepping back."
    public let recessiveSecondary: Color
    /// Lowest-contrast text and dividers — date eyebrows, separators
    /// within recessive groups. Approaches the surface luminance.
    public let recessiveTertiary: Color
    /// Subtle tile / background tint, typically used with `.opacity(0.3)`
    /// for hover and pressed states.
    public let recessiveQuaternary: Color
    /// Sidebar and pill background fills — wash-light overlays that
    /// blend into the surface but still register visually.
    public let recessiveQuinary: Color

    // MARK: Accent

    /// Brand blue, selection chrome, primary CTAs.
    public let accent: Color
    /// Accent backgrounds (e.g. selected row tint) and disabled accent
    /// states. Low-opacity sibling of `accent`.
    public let accentMuted: Color

    // MARK: Borders & separators (Flag #2 — 4 fields)

    /// The line between list items — semantically different from a
    /// card outline even when the value matches.
    public let separator: Color
    /// Hairline outline (typically alpha 0.06–0.08).
    public let borderSubtle: Color
    /// Standard outline weight (typically alpha 0.12).
    public let borderDefault: Color
    /// Focused / emphasised outline (typically alpha 0.24).
    public let borderEmphasis: Color

    // MARK: Semantic

    public let success: Color
    public let warning: Color
    public let danger: Color

    // MARK: Page-specific

    /// The paper colour the user draws on.
    public let pageBackground: Color
    /// Ruled-line colour for `lined` templates.
    public let pageLines: Color
    /// Dot colour for `dotGrid` templates.
    public let pageDots: Color
    /// Subtle margin indicator (e.g. the soft band at the page edge).
    public let pageMargin: Color

    // MARK: Ink defaults

    /// New strokes drawn after switching themes use this as the default
    /// pen colour. Existing strokes keep their stored colours.
    public let defaultInkColor: Color

    // MARK: Asset references

    /// e.g. "AppIcon-Default" — used by `ThemeManager.updateAppIcon()` to
    /// pick the right per-letter icon family. Per-theme icon variants are
    /// post-1.0; in 1.0 only "AppIcon-Default" is wired up.
    public let appIconAssetPrefix: String
    /// Widget background asset name. Widget itself follows system
    /// appearance in 1.0; this exists for future use.
    public let widgetBackgroundAssetName: String
    /// Splash background asset name (the LaunchScreen colour asset).
    public let splashAssetName: String

    // MARK: Cover palette

    /// The 8 cover tones offered when creating a new notebook. The
    /// Default theme's palette mirrors `NotebookCoverTone`'s existing
    /// hex values; the Midnight palette ships later (Phase C).
    public let coverPalette: [Color]

    // MARK: Waveform (legacy)

    /// Audio-playback waveform colours. Used by legacy data rendering
    /// only — new recordings (post-V6) don't use waveform display.
    public let waveformActive: Color
    public let waveformInactive: Color
}

// MARK: - The two shipped themes

extension Theme {

    static let `default`: Theme = Theme(
        id: "default",
        displayName: "Default",
        interfaceStyle: .light,

        // Foundation — from inkBackground{Primary,Secondary,Elevated} light
        background:       Color(hex: "#FAFAF8"),
        surface:          Color(hex: "#F2F2F0"),
        surfaceElevated:  Color(hex: "#FFFFFF"),

        // Foreground — from inkText{Primary,Secondary,Tertiary} light
        foreground:        Color(hex: "#1D1D1B"),
        foregroundMuted:   Color(hex: "#6B6B68"),
        foregroundSubtle:  Color(hex: "#ADADAA"),

        // Recessive — from inkRecessive{Primary..Quinary} light
        recessivePrimary:    Color(hex: "#555555"),
        recessiveSecondary:  Color(hex: "#BBBBBB"),
        recessiveTertiary:   Color(hex: "#CCCCCC"),
        recessiveQuaternary: Color(hex: "#999999"),
        recessiveQuinary:    Color(hex: "#DDDDDD"),

        // Accent — from inkAccent{Primary,Secondary} light
        accent:       Color(hex: "#007AFF"),
        accentMuted:  Color(hex: "#E8F1FF"),

        // Borders — alpha overlays on black (light mode)
        separator:       Color.black.opacity(0.06),
        borderSubtle:    Color.black.opacity(0.06),
        borderDefault:   Color.black.opacity(0.12),
        borderEmphasis:  Color.black.opacity(0.24),

        // Semantic
        success:  Color(hex: "#34C759"),
        warning:  Color(hex: "#FF9500"),
        danger:   Color(hex: "#FF3B30"),

        // Page — from inkCanvasBackground light + architecture-doc starts
        pageBackground:  Color(hex: "#FFFFFF"),
        pageLines:       Color(hex: "#E0E0E0"),
        pageDots:        Color(hex: "#D0D0D0"),
        pageMargin:      Color(hex: "#F0F0F0"),

        // Ink — matches CeciliasNotesTool.Defaults.ceciliasNotesColour(light)
        defaultInkColor: Color(hex: "#1D1D1B"),

        // Assets
        appIconAssetPrefix:        "AppIcon-Default",
        widgetBackgroundAssetName: "WidgetBackground-Default",
        splashAssetName:           "Splash-Default",

        // Cover palette — the existing NotebookCoverTone hex values
        coverPalette: [
            Color(hex: "#f5f0e8"),  // parchment
            Color(hex: "#ffffff"),  // studioWhite
            Color(hex: "#e8e8e4"),  // ash
            Color(hex: "#2e2e2e"),  // coal
            Color(hex: "#1a1a2e"),  // midnight
            Color(hex: "#2a2e28"),  // moss
            Color(hex: "#2e2228"),  // dusk
            Color(hex: "#0a0a0a"),  // inkBlack
        ],

        // Waveform
        waveformActive:   Color(hex: "#007AFF"),
        waveformInactive: Color(hex: "#C0C0C0")
    )

    static let midnight: Theme = Theme(
        id: "midnight",
        displayName: "Midnight",
        interfaceStyle: .dark,

        // Foundation — from inkBackground{Primary,Secondary,Elevated} dark,
        // with surfaceElevated bumped one tier (Flag #1 decision) to give
        // floating chrome subtle separation from `surface` in dark mode.
        background:       Color(hex: "#111110"),
        surface:          Color(hex: "#1C1C1A"),
        surfaceElevated:  Color(hex: "#2C2C2C"),

        // Foreground — from inkText{Primary,Secondary,Tertiary} dark
        foreground:        Color(hex: "#F5F5F2"),
        foregroundMuted:   Color(hex: "#8E8E8A"),
        foregroundSubtle:  Color(hex: "#555552"),

        // Recessive — from inkRecessive{Primary..Quinary} dark
        recessivePrimary:    Color(hex: "#A4A4A2"),
        recessiveSecondary:  Color(hex: "#4D4D4B"),
        recessiveTertiary:   Color(hex: "#3F3F3D"),
        recessiveQuaternary: Color(hex: "#6A6A67"),
        recessiveQuinary:    Color(hex: "#2A2A28"),

        // Accent — from inkAccent{Primary,Secondary} dark
        accent:       Color(hex: "#0A84FF"),
        accentMuted:  Color(hex: "#0A2545"),

        // Borders — alpha overlays on white (dark mode)
        separator:       Color.white.opacity(0.08),
        borderSubtle:    Color.white.opacity(0.08),
        borderDefault:   Color.white.opacity(0.12),
        borderEmphasis:  Color.white.opacity(0.24),

        // Semantic
        success:  Color(hex: "#30D158"),
        warning:  Color(hex: "#FF9F0A"),
        danger:   Color(hex: "#FF453A"),

        // Page — from inkCanvasBackground dark + architecture-doc starts
        pageBackground:  Color(hex: "#1A1A1A"),
        pageLines:       Color(hex: "#2E2E30"),
        pageDots:        Color(hex: "#3A3A3C"),
        pageMargin:      Color(hex: "#222224"),

        // Ink — matches CeciliasNotesTool.Defaults.ceciliasNotesColour(dark)
        defaultInkColor: Color(hex: "#F5F5F2"),

        // Assets
        appIconAssetPrefix:        "AppIcon-Midnight",
        widgetBackgroundAssetName: "WidgetBackground-Midnight",
        splashAssetName:           "Splash-Midnight",

        // Cover palette — Phase C will replace with Midnight-tuned values.
        // Until then, mirror Default so the field is non-empty.
        coverPalette: [
            Color(hex: "#f5f0e8"),
            Color(hex: "#ffffff"),
            Color(hex: "#e8e8e4"),
            Color(hex: "#2e2e2e"),
            Color(hex: "#1a1a2e"),
            Color(hex: "#2a2e28"),
            Color(hex: "#2e2228"),
            Color(hex: "#0a0a0a"),
        ],

        // Waveform
        waveformActive:   Color(hex: "#0A84FF"),
        waveformInactive: Color(hex: "#48484A")
    )

    /// Every theme available to the picker. Adding a theme means
    /// appending here.
    static let all: [Theme] = [.default, .midnight]
}

// MARK: - SwiftUI environment

extension EnvironmentValues {
    @Entry var theme: Theme = .default
}
