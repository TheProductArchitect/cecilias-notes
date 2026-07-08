#if os(macOS)
import AppKit
import CoreText
import SwiftUI

/// Renders the dock icon — same letter + dot composition as iOS
/// `BrandIconRenderer`, applied via `NSApplication.applicationIconImage`.
enum MacBrandIconRenderer {
    static let backgroundHex = "#F4F3EE"
    static let letterHex = "#06060A"

    @MainActor
    static func render(letter: Character, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)

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

        // `lockFocus` yields a standard AppKit context: origin at the
        // BOTTOM-left, y increasing upward — CoreText's native
        // orientation. No flip transform: adding the UIKit-style
        // translate+scale(1,-1) here (as the iOS renderer needs)
        // mirrors every glyph vertically and ships an upside-down
        // dock icon.
        let drawX = (size - width) / 2
        let baselineFromBottom = (size - ascent + descent) / 2
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: drawX, y: baselineFromBottom)
        CTLineDraw(line, ctx)
        ctx.restoreGState()

        return image
    }
}

#endif
