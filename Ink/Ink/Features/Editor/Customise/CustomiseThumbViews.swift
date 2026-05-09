import SwiftUI
import UIKit

// MARK: - CoverThumbView

/// Live thumbnail of a `NotebookCover` — paints colour + texture using
/// the same `CoverTextureCanvas` the library cards already use, so the
/// thumbnail matches what the user will see on the card.
struct CoverThumbView: View {
    let cover: NotebookCover
    let size: CGSize

    var body: some View {
        ZStack {
            Color(UIColor(hex: cover.colorHex))
            CoverTextureCanvas(texture: cover.texture)
                .opacity(0.85)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            // Subtle inner edge so very pale covers (cream, parchment)
            // remain distinguishable on the elevated panel background.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
        )
    }
}

// MARK: - TemplateThumbView

/// Static preview of a `PageTemplate`, rendered by drawing the existing
/// `PageRenderer` (UIView) into a `UIImage` at thumb size and caching it
/// per (template, size, appearance) tuple. Going through `layer.render(in:)`
/// uses the same Core Graphics draw path the live canvas uses, so what the
/// user sees in the carousel is what they'll get on the page.
///
/// Earlier this view tried to scale a live `PageRenderer` UIView via
/// `CGAffineTransform` inside a SwiftUI host. That looked blank because
/// the host's bounds settled *after* the renderer had already drawn at
/// `.zero` size. Static rasterisation removes the timing dependency.
struct TemplateThumbView: View {
    let template: PageTemplate
    let size: CGSize

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(uiImage: TemplateThumbCache.image(for: template, size: size, scheme: colorScheme))
            .resizable()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Cache + renderer

private enum TemplateThumbCache {
    private struct Key: Hashable {
        let templateRaw: String
        let widthPt:    Int
        let heightPt:   Int
        let isDark:     Bool
    }

    private static var cache: [Key: UIImage] = [:]

    static func image(for template: PageTemplate, size: CGSize, scheme: ColorScheme) -> UIImage {
        let isDark = (scheme == .dark)
        let key = Key(
            templateRaw: template.jsonString,
            widthPt:     Int(size.width.rounded()),
            heightPt:    Int(size.height.rounded()),
            isDark:      isDark
        )
        if let hit = cache[key] { return hit }
        let img = render(template: template, size: size, isDark: isDark)
        cache[key] = img
        return img
    }

    private static func render(template: PageTemplate, size: CGSize, isDark: Bool) -> UIImage {
        let pagePoints = PageSize.a4.pointSize
        let scale = min(size.width / pagePoints.width, size.height / pagePoints.height)

        let renderer = PageRenderer(pageSize: .a4, template: template)
        renderer.frame = CGRect(origin: .zero, size: pagePoints)
        renderer.overrideUserInterfaceStyle = isDark ? .dark : .light

        // Default UIGraphicsImageRenderer is opaque, so unpainted
        // pixels fall through to black. Using a non-opaque format
        // means a missed draw is *transparent*, not black — easier to
        // notice if things break, and harmless here since we paint
        // every pixel of the page in `draw(_:)`.
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let imageRenderer = UIGraphicsImageRenderer(size: size, format: format)

        return imageRenderer.image { ctx in
            // Centre the scaled page within the thumb so the portrait
            // page sits centred horizontally inside the 80×104 box.
            let scaledW = pagePoints.width  * scale
            let scaledH = pagePoints.height * scale
            let dx = (size.width  - scaledW) / 2
            let dy = (size.height - scaledH) / 2
            ctx.cgContext.translateBy(x: dx, y: dy)
            ctx.cgContext.scaleBy(x: scale, y: scale)

            // Call `draw(_:)` directly so PageRenderer paints into the
            // image-renderer's CG context. The previous build used
            // `renderer.layer.render(in:)`, but a CALayer that has
            // never been displayed in a window has no backing store —
            // `render(in:)` becomes a no-op and the opaque image's
            // default black background showed through, producing the
            // "all black" template thumbs the user reported.
            renderer.draw(renderer.bounds)
        }
    }
}
