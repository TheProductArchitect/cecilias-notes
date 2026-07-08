#if os(macOS)
import AppKit
import CoreText
import SwiftUI

/// Renders the dock icon — same letter + dot composition as iOS
/// `BrandIconRenderer`, applied via `NSApplication.applicationIconImage`.
///
/// Bundle `AppIcon` assets stay square (macOS masks them at display time).
/// Runtime `applicationIconImage` overrides are **not** masked by the system,
/// so we bake in the Big Sur squircle here.
enum MacBrandIconRenderer {
    static let backgroundHex = "#F4F3EE"
    static let letterHex = "#06060A"

    /// macOS Big Sur+ dock / Finder icon corner radius as a fraction of side length.
    static let squircleCornerRatio: CGFloat = 0.2237

    @MainActor
    static func render(letter: Character, size: CGFloat) -> NSImage {
        let pixelSize = max(1, Int(size.rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: size, height: size))
        }

        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(bitmapImageRep: rep)
        graphicsContext?.imageInterpolation = .high
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let ctx = graphicsContext?.cgContext else { return image }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)

        ctx.clear(bounds)

        ctx.saveGState()
        ctx.addPath(squirclePath(in: bounds))
        ctx.clip()

        ctx.setFillColor(NSColor(hex: backgroundHex).cgColor)
        ctx.fill(bounds)

        let letterChar = String(letter).lowercased()
        let fontSize = size * 0.7
        let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let letterColour = NSColor(hex: letterHex)
        let dotColour = NSColor(ThemeManager.shared.current.accent)

        let letterAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: letterColour,
        ]
        let dotAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: dotColour,
        ]

        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: letterChar, attributes: letterAttrs))
        attributed.append(NSAttributedString(string: ".", attributes: dotAttrs))

        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        // Bitmap context uses AppKit's bottom-left origin — CoreText's native
        // orientation. No UIKit-style flip (that shipped upside-down icons).
        let drawX = (size - width) / 2
        let baselineFromBottom = (size - ascent + descent) / 2
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: drawX, y: baselineFromBottom)
        CTLineDraw(line, ctx)

        ctx.restoreGState()
        return image
    }

    private static func squirclePath(in rect: CGRect) -> CGPath {
        let radius = rect.width * squircleCornerRatio
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        return path
    }
}

#endif
