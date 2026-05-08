import CoreGraphics
import CoreText
import UIKit

/// Programmatic app-icon renderer. Produces the lowercase-letter-plus-dot
/// composition that defines the brand at any pixel size: off-white square
/// background, letter in near-black (Bricolage Grotesque Bold, falling
/// back to system bold), full stop in the brand accent.
///
/// Used at runtime by the in-app preview (Settings → About → icon
/// thumbnail) and offline by `Scripts/GenerateBrandIcons.swift` to
/// produce the 182 PNGs (26 letters × 7 iOS-required sizes) that get
/// committed to the bundle for `setAlternateIconName` to switch between.
///
/// Implementation notes
///   • Background is the same off-white in light + dark — iOS doesn't
///     theme app icons, so there is no "dark variant" to render.
///   • Letter is sized so the cap-height occupies ~60% of the icon
///     height; the dot baseline-aligns to the letter.
///   • Tracking is -0.03em via CoreText's `kCTKernAttributeName`.
///   • The PostScript name comes from `BrandFont.postScriptName`. The
///     renderer reads it through `BrandFont.wordmarkUIFont(size:)` so
///     the runtime preview and the offline generator agree on which
///     font (or fallback) is used.
enum BrandIconRenderer {

    static let backgroundHex: String = "#F4F3EE"
    static let letterHex:     String = "#06060A"

    /// Render an icon with the given lowercase letter at the given pixel
    /// size. The dot colour resolves to the brand accent (`brandDot` →
    /// `inkAccentPrimary`) at the moment of rendering.
    static func render(letter: Character, size: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let bounds = CGRect(x: 0, y: 0, width: size, height: size)

            // 1. Off-white background — full bleed; iOS adds the
            //    rounded-rect mask.
            cg.setFillColor(UIColor(hex: backgroundHex).cgColor)
            cg.fill(bounds)

            // 2. Wordmark composition. Caller-supplied letter (lowercased
            //    + trimmed) and a literal "." follow it.
            let letterChar = String(letter).lowercased()
            let dotChar    = "."

            // Sizing: letter cap-height ≈ 60% of icon height. Bricolage's
            // cap-height-to-em ratio is ~0.7, so font size ≈ 0.6 / 0.7 ≈ 0.86.
            // We err slightly smaller so descender-free glyphs (a, c, e, m,
            // n, o, r, s, u, v, w, x, z) and ascender glyphs (b, d, f, h,
            // k, l, t) both sit inside the safe area.
            let fontSize  = size * 0.78
            let baseFont  = BrandFont.wordmarkUIFont(size: fontSize)
            let kern      = -0.03 * fontSize

            let letterColour = UIColor(hex: letterHex)
            // brandDot resolves to the existing accent — keep the call
            // site through the SwiftUI Color so the design-system
            // mapping stays single-sourced, then bridge to UIColor.
            let dotColour    = UIColor.inkAccentPrimary

            let letterAttrs: [NSAttributedString.Key: Any] = [
                .font:  baseFont,
                .foregroundColor: letterColour,
                .kern:  kern,
            ]
            let dotAttrs: [NSAttributedString.Key: Any] = [
                .font:  baseFont,
                .foregroundColor: dotColour,
                .kern:  kern,
            ]

            let attributed = NSMutableAttributedString()
            attributed.append(NSAttributedString(string: letterChar, attributes: letterAttrs))
            attributed.append(NSAttributedString(string: dotChar,    attributes: dotAttrs))

            // 3. Layout the line via CoreText so we can position by the
            //    typographic baseline rather than UIKit's text-rect
            //    centring (which would shift accidentally between
            //    glyphs of different height).
            let line = CTLineCreateWithAttributedString(attributed)
            var ascent:  CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

            let drawX = (size - typographicWidth) / 2
            // Centre the cap-height vertically (cap ≈ ascent for sans-serif,
            // close enough). Flip y because CoreText's origin is bottom-left.
            let drawYBaseline = (size + ascent - descent) / 2
            cg.saveGState()
            cg.textMatrix = .identity
            cg.translateBy(x: 0, y: size)
            cg.scaleBy(x: 1, y: -1)
            cg.textPosition = CGPoint(x: drawX, y: size - drawYBaseline)
            CTLineDraw(line, cg)
            cg.restoreGState()
        }
    }

    // MARK: iOS-required output sizes

    /// All sizes the icon-generation script writes out. iOS picks the
    /// closest match for the device class at runtime; smaller sizes
    /// (Settings, Spotlight) tend to look fine downscaled from a single
    /// 1024×1024 master, but Apple's docs explicitly call out the per-size
    /// list — providing them all keeps the system from picking the wrong
    /// rendering.
    static let outputSizes: [CGFloat] = [
        60,    // Settings (iPad), 60×60@1x
        76,    // iPad legacy
        83.5,  // iPad Pro 12.9"
        120,   // Settings/Spotlight @3x; iPhone home
        152,   // iPad home @2x
        167,   // iPad Pro home @2x
        1024,  // App Store / marketing
    ]

    /// All 26 lowercase Latin letters.
    static let allLetters: [Character] = (UnicodeScalar("a").value...UnicodeScalar("z").value)
        .compactMap { UnicodeScalar($0).map { Character($0) } }
}
