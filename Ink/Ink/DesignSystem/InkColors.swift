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
}
