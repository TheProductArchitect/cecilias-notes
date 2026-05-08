import SwiftUI
import UIKit

/// The wordmark composition: a single lowercase letter followed by a
/// full stop, set in Bricolage Grotesque Bold with -0.03em tracking.
/// The letter colour is environment-aware (`Color.brandLetter`); the dot
/// is the brand accent (`Color.brandDot`).
///
/// Used in onboarding, the Library top-left greeting, the personalising
/// transition, the Settings → About preview, and (rasterised) the app
/// icons. Wherever the wordmark appears in the UI, it goes through this
/// view — there is no second source of truth.
///
/// Font fallback: if Bricolage Grotesque hasn't been bundled yet
/// (`Resources/Fonts/BricolageGrotesque-VariableFont_*.ttf`), we fall
/// back to the system bold so the layout still works during development.
/// The icon-generation script does the same so placeholder PNGs render
/// even before the font lands.
struct BrandWordmark: View {
    let letter: Character
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(String(letter).lowercased())
                .font(BrandFont.wordmark(size: size))
                .kerning(-0.03 * size)
                .foregroundColor(.brandLetter)
                .accessibilityHidden(true)
            Text(".")
                .font(BrandFont.wordmark(size: size))
                .foregroundColor(.brandDot)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wordmark \(String(letter).lowercased()).")
    }
}

// MARK: - Brand font

/// Single source of truth for the wordmark typeface. Declared once so
/// the SwiftUI `BrandWordmark` view and the CoreGraphics-based
/// `BrandIconRenderer` resolve the same PostScript name (or fall back
/// the same way).
enum BrandFont {

    /// PostScript name expected on disk. Confirm with the actual
    /// `BricolageGrotesque-VariableFont_*.ttf` you bundle — the variable
    /// font ships a single PostScript name that the system reports;
    /// adjust here if Apple's font tools surface a different one for
    /// your specific file.
    static let postScriptName = "BricolageGrotesque-Bold"

    /// SwiftUI `Font` for the wordmark at a given pixel size, falling
    /// back to system bold if Bricolage hasn't been registered.
    static func wordmark(size: CGFloat) -> Font {
        if isBricolageRegistered {
            return .custom(postScriptName, size: size)
        }
        return .system(size: size, weight: .bold, design: .default)
    }

    /// UIFont equivalent for code paths that need UIKit (the icon
    /// renderer's CoreText draw path).
    static func wordmarkUIFont(size: CGFloat) -> UIFont {
        if let f = UIFont(name: postScriptName, size: size) {
            return f
        }
        return .systemFont(ofSize: size, weight: .bold)
    }

    /// Cached lookup — `UIFont(name:size:)` returns nil if the font
    /// isn't registered, but we don't want to pay that lookup on every
    /// SwiftUI body re-evaluation.
    private static let isBricolageRegistered: Bool = {
        UIFont(name: postScriptName, size: 12) != nil
    }()
}
