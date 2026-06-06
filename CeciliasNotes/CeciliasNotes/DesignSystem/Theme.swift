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

    /// The line between list items — primary content boundary.
    public let separator: Color
    /// Section dividers within a panel — barely-there boundary
    /// communicating "secondary grouping" rather than "list row break."
    /// One tier subtler than `separator` (D1 — Bucket 4 consolidation).
    public let hairline: Color
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

    // MARK: Pen defaults

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

    // MARK: Highlight palette (Step 5.5)

    /// Per-theme highlight palette keyed by `colorVariant` string
    /// (`"yellow"`, `"pink"`, `"blue"`, `"green"`). Resolved by
    /// `HighlightElementView` via
    /// `theme.highlightPalette[content.colorVariant]`. Storing the
    /// key on `HighlightContent` rather than a raw hex means a theme
    /// switch re-tints existing highlights without touching rows.
    /// The renderer multiplies by ~0.4 alpha for the `.highlight`
    /// style fill; `.underline` and `.strikethrough` paint at full
    /// opacity.
    public let highlightPalette: [String: Color]

    // MARK: Sticky-note palette (Step 7)

    /// Per-theme sticky-note palette keyed by the same
    /// `colorVariant` strings as `highlightPalette`. Sticky cards
    /// are *opaque* (no alpha multiplier) so the values here are
    /// slightly more saturated than the highlight equivalents —
    /// stickies need to read as a chromatic card on the page, while
    /// highlights are translucent overlays on top of glyphs.
    /// Resolved by `StickyNoteElementView` via
    /// `theme.stickyNotePalette[content.colorVariant]`.
    public let stickyNotePalette: [String: Color]
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
        hairline:        Color.black.opacity(0.04),
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

        // Pen — matches CeciliasNotesTool.Defaults.ceciliasNotesColour(light)
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
        waveformInactive: Color(hex: "#C0C0C0"),

        // Highlight palette (Step 5.5) — Default theme uses bright
        // hues; renderer applies ~0.4 alpha for the .highlight
        // style fill so glyphs remain legible.
        highlightPalette: [
            "yellow": Color(red: 1.00, green: 0.95, blue: 0.40),
            "pink":   Color(red: 1.00, green: 0.70, blue: 0.85),
            "blue":   Color(red: 0.70, green: 0.85, blue: 1.00),
            "green":  Color(red: 0.75, green: 0.95, blue: 0.70),
        ],

        // Sticky-note palette (Step 7) — Default theme. Opaque
        // post-it tones, slightly warmer/more saturated than the
        // highlight palette so stickies read as physical cards.
        stickyNotePalette: [
            "yellow": Color(red: 1.00, green: 0.92, blue: 0.50),
            "pink":   Color(red: 1.00, green: 0.75, blue: 0.85),
            "blue":   Color(red: 0.70, green: 0.85, blue: 1.00),
            "green":  Color(red: 0.75, green: 0.95, blue: 0.70),
        ]
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

        // Recessive — from inkRecessive{Primary..Quinary} dark.
        // recessiveTertiary bumped #3F3F3D → #5E5E5C in Phase G after
        // on-device verification: the MONDAY eyebrow rendered at the
        // old value was unreadable against the Midnight library
        // background (#1A1A1A — only ~12pt luminance difference). The
        // new value gives a ~26pt difference, matching the Default
        // theme's #CCCCCC eyebrow against #FAFAF8.
        recessivePrimary:    Color(hex: "#A4A4A2"),
        recessiveSecondary:  Color(hex: "#4D4D4B"),
        recessiveTertiary:   Color(hex: "#5E5E5C"),
        recessiveQuaternary: Color(hex: "#6A6A67"),
        recessiveQuinary:    Color(hex: "#2A2A28"),

        // Accent — from inkAccent{Primary,Secondary} dark
        accent:       Color(hex: "#0A84FF"),
        accentMuted:  Color(hex: "#0A2545"),

        // Borders — alpha overlays on white (dark mode). White at a
        // low alpha over a near-black surface reads much weaker than
        // the equivalent black-on-light alpha, so the hairline /
        // subtle tiers are lifted to stay visible (dividers were
        // effectively invisible on the dark library home).
        separator:       Color.white.opacity(0.14),
        hairline:        Color.white.opacity(0.12),
        borderSubtle:    Color.white.opacity(0.16),
        borderDefault:   Color.white.opacity(0.20),
        borderEmphasis:  Color.white.opacity(0.30),

        // Semantic
        success:  Color(hex: "#30D158"),
        warning:  Color(hex: "#FF9F0A"),
        danger:   Color(hex: "#FF453A"),

        // Page — from inkCanvasBackground dark + architecture-doc starts
        pageBackground:  Color(hex: "#1A1A1A"),
        pageLines:       Color(hex: "#2E2E30"),
        pageDots:        Color(hex: "#3A3A3C"),
        pageMargin:      Color(hex: "#222224"),

        // Pen — matches CeciliasNotesTool.Defaults.ceciliasNotesColour(dark)
        defaultInkColor: Color(hex: "#F5F5F2"),

        // Assets
        appIconAssetPrefix:        "AppIcon-Midnight",
        widgetBackgroundAssetName: "WidgetBackground-Midnight",
        splashAssetName:           "Splash-Midnight",

        // Cover palette — Midnight-tuned variants (Phase C).
        // Each tone preserves its hue identity from the Default palette
        // (NotebookCoverTone) but shifts luminance to read correctly
        // against the Midnight library background (#111110). Bipolar
        // distribution preserved: 3 paper tones (78-94% luminance) +
        // 5 fabric/leather tones (15-36%). See the Phase C palette
        // proposal for per-tone reasoning. The picker doesn't read
        // from this field yet; CustomisePanel still iterates
        // NotebookCoverTone.allCases. Wiring is a post-Step-0.75
        // feature.
        coverPalette: [
            Color(hex: "#E8E0D0"),  // parchment  (warm aged-paper, soft on dark)
            Color(hex: "#F0F0EC"),  // studioWhite (gallery white, soft warmth)
            Color(hex: "#C8C8C4"),  // ash        (light cool grey)
            Color(hex: "#5C5C58"),  // coal       (medium warm grey, lifted from #2E2E2E)
            Color(hex: "#3A3A52"),  // midnight   (medium blue-indigo, the navy cover tone)
            Color(hex: "#4A4E46"),  // moss       (medium olive, green undertone preserved)
            Color(hex: "#4E3E46"),  // dusk       (medium mauve, pink-purple undertone)
            Color(hex: "#262624"),  // inkBlack   (near-black; deliberate user choice only)
        ],

        // Waveform
        waveformActive:   Color(hex: "#0A84FF"),
        waveformInactive: Color(hex: "#48484A"),

        // Highlight palette (Step 5.5) — Midnight uses muted
        // versions of the same hues so highlights stay visible on
        // the dark paper without eye-searing brightness. The
        // renderer applies the same ~0.4 alpha for fill style.
        highlightPalette: [
            "yellow": Color(red: 0.80, green: 0.72, blue: 0.30),
            "pink":   Color(red: 0.80, green: 0.50, blue: 0.65),
            "blue":   Color(red: 0.50, green: 0.65, blue: 0.85),
            "green":  Color(red: 0.55, green: 0.75, blue: 0.50),
        ],

        // Sticky-note palette (Step 7) — Midnight theme. Muted
        // versions of the same hues so stickies don't burn against
        // the dark paper. Starting values; on-device tuning may
        // adjust per the Phase G Step-0.75 calibration pass —
        // none has happened yet for sticky-specific tones.
        stickyNotePalette: [
            "yellow": Color(red: 0.65, green: 0.60, blue: 0.35),
            "pink":   Color(red: 0.65, green: 0.50, blue: 0.55),
            "blue":   Color(red: 0.45, green: 0.55, blue: 0.65),
            "green":  Color(red: 0.50, green: 0.60, blue: 0.45),
        ]
    )

    /// Every theme available to the picker. Adding a theme means
    /// appending here.
    static let all: [Theme] = [.default, .midnight]
}

// MARK: - SwiftUI environment

extension EnvironmentValues {
    @Entry var theme: Theme = .default
}
