import UIKit
import SwiftUI

// MARK: - CeciliasNotesColors (post-D2 reduced form)
//
// Before Step 0.75 D2 this file held 200+ lines: UIColor / Color
// dynamic-provider tokens for the entire design system (inkBackground*,
// inkText*, inkAccent*, inkBorder*, inkRecessive*, inkDestructive,
// inkCanvasBackground, brandLetter/brandDot/brandAccent, inkNearBlack,
// inkNearWhite). All of that has migrated to `Theme.swift` and is
// consumed via `@Environment(\.theme)` in SwiftUI views, or
// `UIColor(ThemeManager.shared.current.X)` in UIKit code paths.
//
// What remains here are the genuinely-utility hex-color initializers
// that don't belong on the Theme value type:
//
//   • `Color(hex:)` / `UIColor(hex:)` — used in ~120 places to build
//     fixed-hex colour values (cover-tone palettes in NotebookCoverTone,
//     sticky-note tones, status traffic-lights in the sidebar's iCloud
//     indicator, etc.). The Theme struct itself uses them to define
//     its own colour fields.
//
//   • `Color(light:dark:)` — adaptive-via-trait-collection bridge for
//     the small set of remaining theme-independent dual-tone tokens
//     (cover ghost-letter overlays in CustomisePanel). NOT a substitute
//     for theme.X reads; only used where the value should pin to the
//     SURFACE underneath rather than the user's chosen theme.
//
//   • `Color.coverTextBlack` — fixed near-black for cover-stock text
//     overlays (CustomisePanel). Intentionally non-adaptive per the
//     Phase A2 Bucket 6 decision: pair with the known cover tone,
//     not the user's theme.

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
    /// Resolves against the trait collection — i.e. follows the
    /// `.preferredColorScheme(_:)` modifier applied at the SwiftUI
    /// root, which is itself driven by `ThemeManager.current`'s
    /// `interfaceStyle`. Use only when you need a dual-tone value
    /// that isn't a theme field — most reads should go through
    /// `@Environment(\.theme)` instead.
    init(light: Color, dark: Color) {
        self = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }

    /// Fixed near-black for cover-stock text overlays (CustomisePanel).
    /// Intentionally non-adaptive — pair with the known cover surface
    /// it sits against, not with the user's theme. Phase A2 Bucket 6
    /// decision: renamed from `inkNearBlack` after the D2 mass
    /// migration to reflect the only remaining use-case.
    static let coverTextBlack = Color(hex: "#0a0a0a")
}

public extension UIColor {

    /// Hex string → UIColor. Accepts "#RRGGBB" or "RRGGBB". Invalid
    /// input resolves to black.
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
