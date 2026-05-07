import CoreGraphics
import UIKit

// MARK: - InkIconRenderer

/// Programmatic app icon renderer. The icon concept: an ink drop forming the
/// stem of a lowercase "i" — the dot of the i is the accent-blue circle above.
/// Single source of truth, drawn from a 100×100 reference grid; scales to any
/// pixel size cleanly.
///
/// Keep `drawInkForm(in:theme:)` synchronised with the master SVG in
/// `Resources/AppIcon.svg`. If you change one, change the other.
final class InkIconRenderer {

    // MARK: Theme

    struct IconTheme {
        var background: UIColor
        var foreground: UIColor
        var accentDot:  UIColor

        static let light = IconTheme(
            background: UIColor(hex: "#FAFAF8"),
            foreground: UIColor(hex: "#1D1D1B"),
            accentDot:  UIColor(hex: "#007AFF")
        )

        static let dark = IconTheme(
            background: UIColor(hex: "#111110"),
            foreground: UIColor(hex: "#F5F5F2"),
            accentDot:  UIColor(hex: "#0A84FF")
        )

        /// iOS 18+ tinted icon — uses system label/tint at runtime.
        static var tinted: IconTheme {
            IconTheme(
                background: .systemBackground,
                foreground: .label,
                accentDot:  .tintColor
            )
        }
    }

    // MARK: Render

    /// Renders the icon at the given pixel size. `cornerRadius` scales by Apple's
    /// superellipse approximation: `size * 0.2237`. iOS-supplied icon masks
    /// will compose over a square output, so corner-rounding is for previews.
    func render(size: CGSize, theme: IconTheme = .light, cornerRadius: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cgCtx  = ctx.cgContext
            let bounds = CGRect(origin: .zero, size: size)
            let scale  = size.width / 100.0   // reference grid is 100×100

            // 1. Rounded background
            let bgPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius)
            theme.background.setFill()
            bgPath.fill()

            // 2. Foreground forms — drawn in 100-grid space
            cgCtx.saveGState()
            cgCtx.scaleBy(x: scale, y: scale)
            drawInkForm(in: cgCtx, theme: theme)
            cgCtx.restoreGState()
        }
    }

    // MARK: Form drawing (100×100 reference grid)

    /// Draws the ink-drop "i" form. All coordinates are in a 100×100 grid;
    /// the caller is responsible for any pre-scaling.
    ///
    /// Mirror of `Resources/AppIcon.svg`:
    /// - Drop body (stem): cubic-bezier teardrop, tip at (50,78), bulges to (32,42)/(68,42)
    /// - Accent dot (i-dot): circle at (50,20), radius 7
    private func drawInkForm(in ctx: CGContext, theme: IconTheme) {

        // Drop body / stem
        let dropPath = CGMutablePath()
        dropPath.move(to: CGPoint(x: 50, y: 78))
        dropPath.addCurve(
            to:        CGPoint(x: 32, y: 42),
            control1:  CGPoint(x: 32, y: 65),
            control2:  CGPoint(x: 32, y: 50)
        )
        dropPath.addCurve(
            to:        CGPoint(x: 50, y: 32),
            control1:  CGPoint(x: 32, y: 28),
            control2:  CGPoint(x: 44, y: 24)
        )
        dropPath.addCurve(
            to:        CGPoint(x: 68, y: 42),
            control1:  CGPoint(x: 56, y: 24),
            control2:  CGPoint(x: 68, y: 28)
        )
        dropPath.addCurve(
            to:        CGPoint(x: 50, y: 78),
            control1:  CGPoint(x: 68, y: 50),
            control2:  CGPoint(x: 68, y: 65)
        )
        dropPath.closeSubpath()

        ctx.addPath(dropPath)
        ctx.setFillColor(theme.foreground.cgColor)
        ctx.fillPath()

        // Accent dot
        let dotRect = CGRect(x: 43, y: 13, width: 14, height: 14)
        ctx.setFillColor(theme.accentDot.cgColor)
        ctx.fillEllipse(in: dotRect)
    }

    // MARK: Asset-catalogue size table

    /// Sizes required for an iPad-only app icon set.
    /// Used by `tools/generate-app-icons` (DEBUG-only build helper).
    static let assetSizes: [(pixelSize: CGFloat, fileName: String)] = [
        (1024, "AppIcon-1024"),        // App Store
        (180,  "AppIcon-60@3x"),       // iPhone (kept for spotlight/settings)
        (120,  "AppIcon-60@2x"),
        (167,  "AppIcon-83.5@2x"),     // iPad Pro
        (152,  "AppIcon-76@2x"),       // iPad
        (76,   "AppIcon-76"),
        (87,   "AppIcon-29@3x"),       // Settings
        (58,   "AppIcon-29@2x"),
        (80,   "AppIcon-40@2x"),       // Spotlight
        (120,  "AppIcon-40@3x")
    ]
}
