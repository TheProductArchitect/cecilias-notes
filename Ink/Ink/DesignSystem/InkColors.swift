import UIKit
import SwiftUI

// MARK: - UIColor tokens (dynamic provider — works inside UIKit contexts)

public extension UIColor {

    // MARK: Background
    static let inkBackgroundPrimary = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#111110")
            : UIColor(hex: "#FAFAF8")
    }
    static let inkBackgroundSecondary = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#1C1C1A")
            : UIColor(hex: "#F2F2F0")
    }
    static let inkBackgroundTertiary = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#252522")
            : UIColor(hex: "#E8E8E5")
    }
    static let inkBackgroundElevated = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#1C1C1A")
            : UIColor(hex: "#FFFFFF")
    }

    // MARK: Text
    static let inkTextPrimary = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#F5F5F2")
            : UIColor(hex: "#1D1D1B")
    }
    static let inkTextSecondary = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#8E8E8A")
            : UIColor(hex: "#6B6B68")
    }
    static let inkTextTertiary = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#555552")
            : UIColor(hex: "#ADADAA")
    }

    // MARK: Accent
    static let inkAccentPrimary = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#0A84FF")
            : UIColor(hex: "#007AFF")
    }
    static let inkAccentSecondary = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#0A2545")
            : UIColor(hex: "#E8F1FF")
    }

    // MARK: Border
    static let inkBorderSubtle = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.08)
            : UIColor(white: 0, alpha: 0.06)
    }
    static let inkBorderDefault = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.12)
            : UIColor(white: 0, alpha: 0.12)
    }
    static let inkBorderEmphasis = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.24)
            : UIColor(white: 0, alpha: 0.24)
    }

    // MARK: Destructive
    static let inkDestructive = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#FF453A")
            : UIColor(hex: "#FF3B30")
    }

    // MARK: Recording (audio "live" indicator)
    /// Distinct from destructive semantically even though the hex is similar.
    /// Use for the recording dot, mic-on indicator, etc.
    static let inkRecording = UIColor(hex: "#FF3B30")

    // MARK: Canvas
    /// Canvas host surface — white in light mode, `#1a1a1a` in dark
    /// mode. Page templates and PencilKit strokes render on top.
    static let inkCanvasBackground = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#1A1A1A")
            : UIColor(hex: "#FFFFFF")
    }

    // MARK: Hex convenience init
    convenience init(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.hasPrefix("#") ? String(sanitized.dropFirst()) : sanitized

        var rgb: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&rgb)

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255
        let b = CGFloat(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - SwiftUI Color bridge

public extension Color {
    static let inkBackgroundPrimary   = Color(UIColor.inkBackgroundPrimary)
    static let inkBackgroundSecondary = Color(UIColor.inkBackgroundSecondary)
    static let inkBackgroundTertiary  = Color(UIColor.inkBackgroundTertiary)
    static let inkBackgroundElevated  = Color(UIColor.inkBackgroundElevated)

    static let inkTextPrimary   = Color(UIColor.inkTextPrimary)
    static let inkTextSecondary = Color(UIColor.inkTextSecondary)
    static let inkTextTertiary  = Color(UIColor.inkTextTertiary)

    static let inkAccentPrimary   = Color(UIColor.inkAccentPrimary)
    static let inkAccentSecondary = Color(UIColor.inkAccentSecondary)

    static let inkBorderSubtle   = Color(UIColor.inkBorderSubtle)
    static let inkBorderDefault  = Color(UIColor.inkBorderDefault)
    static let inkBorderEmphasis = Color(UIColor.inkBorderEmphasis)

    static let inkDestructive = Color(UIColor.inkDestructive)
    static let inkRecording   = Color(UIColor.inkRecording)
    static let inkCanvasBackground = Color(UIColor.inkCanvasBackground)

    // MARK: - Brand wordmark tokens
    //
    // Used by `BrandWordmark` everywhere the lowercase letter + dot
    // composition appears (onboarding, library greeting, app icons,
    // Settings preview).
    //
    // `brandLetter` is environment-aware so the letter has high contrast
    // against either light or dark surfaces. `brandDot` is fixed —
    // resolves to `inkAccentPrimary` (the existing brand colour) so the
    // dot reads consistently regardless of the surface it lands on.

    /// Letter colour: near-black on light, off-white on dark.
    static let brandLetter = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(hex: "#F4F3EE")
            : UIColor(hex: "#06060A")
    })

    /// Dot colour: the existing brand accent — fixed regardless of theme.
    static let brandDot = Color.inkAccentPrimary

    /// Brand accent: Apple blue (#007AFF light / #0A84FF dark). Alias of
    /// `inkAccentPrimary` exposed under the brand name for splash, home
    /// header and About screen call-sites.
    static let brandAccent = Color.inkAccentPrimary

    // MARK: - Redesign tokens (Phase A foundation)
    //
    // Near-black/near-white anchors for places that need a fixed value
    // regardless of theme (e.g. hard-coded ghost-letter overlays on
    // light cover stock). `inkNearBlack` and `inkNearWhite` are
    // intentionally non-adaptive — pair them with the surface they sit
    // against, not with the system theme.

    static let inkNearBlack = Color(hex: "#0a0a0a")
    static let inkNearWhite = Color(hex: "#ffffff")

    // MARK: Recessive opacity tokens
    //
    // Five rungs of low-contrast greys for sidebar labels, eyebrows,
    // dividers, and other "present-but-quiet" text. The light values
    // are the visible greys (#aaa…#ddd, lightest last). On dark mode
    // the same hex values are darkened equivalents — sampled from the
    // existing dark-grey ramp so contrast against the dark background
    // stays comparable. They do not invert; they shift to the analogous
    // dark-mode rung.

    // Primary, quaternary, and quinary were tuned across two
    // device-testing passes — the original rungs (`#aaaaaa…#dddddd`)
    // sat right at the edge of legibility, and Phase D's contrast
    // pass moved them firmly into "readable but recessive" territory.
    // The dark-mode rungs are calibrated so light-mode-darker ↔
    // dark-mode-lighter (more contrast against the surface).
    static let inkRecessivePrimary = Color(
        light: Color(hex: "#555555"),
        dark:  Color(hex: "#a4a4a2")
    )
    static let inkRecessiveSecondary = Color(
        light: Color(hex: "#bbbbbb"),
        dark:  Color(hex: "#4d4d4b")
    )
    static let inkRecessiveTertiary = Color(
        light: Color(hex: "#cccccc"),
        dark:  Color(hex: "#3f3f3d")
    )
    static let inkRecessiveQuaternary = Color(
        light: Color(hex: "#999999"),
        dark:  Color(hex: "#6a6a67")
    )
    static let inkRecessiveQuinary = Color(
        light: Color(hex: "#dddddd"),
        dark:  Color(hex: "#2a2a28")
    )
}

// MARK: - Color convenience initialisers

public extension Color {
    /// Hex string → Color. Accepts "#RRGGBB" or "RRGGBB". Invalid input
    /// resolves to black (the rgb scanner returns 0).
    init(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        let rgb = UInt64(cleaned, radix: 16) ?? 0
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >>  8) & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }

    /// Theme-adaptive Color built from explicit light / dark values.
    /// Use for tokens whose dark-mode variant is *not* a simple
    /// luminance flip of the light variant.
    init(light: Color, dark: Color) {
        self = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }
}
