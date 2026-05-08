import Foundation
import PencilKit
import UIKit

/// Singleton cache of page thumbnails. NSCache evicts under memory pressure.
/// Generation always happens off the main actor; results are stored on the main actor.
final class PageThumbnailCache {

    static let shared = PageThumbnailCache()
    private init() {
        cache.totalCostLimit = 100 * 1024 * 1024  // 100MB (Stage 10 perf target)
    }

    private let cache = NSCache<NSUUID, UIImage>()

    // MARK: Public API

    /// Returns a cached thumbnail synchronously, or nil if not cached.
    func thumbnail(for pageId: UUID) -> UIImage? {
        cache.object(forKey: pageId as NSUUID)
    }

    /// Generates a thumbnail off the main actor and caches the result.
    /// `targetSize` is in points; output respects screen scale.
    func generate(for page: Page, targetSize: CGSize) async -> UIImage? {
        if let cached = thumbnail(for: page.id) { return cached }

        let pageId    = page.id
        let pageRect  = CGRect(origin: .zero, size: page.pageSize.pointSize)
        let strokeData = page.strokeData
        let theme     = await UITraitCollection.current.userInterfaceStyle

        return await Task.detached(priority: .utility) { [cache] () -> UIImage? in
            let image = await Self.render(
                strokeData: strokeData,
                pageRect: pageRect,
                targetSize: targetSize,
                isDark: theme == .dark
            )
            if let image {
                cache.setObject(image, forKey: pageId as NSUUID, cost: image.byteCount)
            }
            return image
        }.value
    }

    func set(_ image: UIImage, for pageId: UUID) {
        cache.setObject(image, forKey: pageId as NSUUID, cost: image.byteCount)
    }

    func invalidate(pageId: UUID) {
        cache.removeObject(forKey: pageId as NSUUID)
    }

    func invalidateAll() {
        cache.removeAllObjects()
    }

    // MARK: Rendering

    /// Composites the page paper colour + drawing into a single bitmap.
    private static func render(
        strokeData: Data?,
        pageRect: CGRect,
        targetSize: CGSize,
        isDark: Bool
    ) async -> UIImage? {
        let scale: CGFloat = targetSize.width / pageRect.width

        let format = UIGraphicsImageRendererFormat()
        format.scale = await UIScreen.main.scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { ctx in
            // Paper background
            let bg: UIColor = isDark ? UIColor(hex: "#1C1C1A") : UIColor(hex: "#FAFAF8")
            bg.setFill()
            ctx.fill(CGRect(origin: .zero, size: targetSize))

            // Drawing
            guard let data = strokeData,
                  let drawing = try? PKDrawing(data: data) else { return }

            // Render the drawing's natural rect, then draw it scaled to fit the thumbnail
            let drawingImage = drawing.image(from: pageRect, scale: scale)
            drawingImage.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

// MARK: - UIImage byte cost

private extension UIImage {
    var byteCount: Int {
        guard let cg = cgImage else { return 0 }
        return cg.height * cg.bytesPerRow
    }
}
