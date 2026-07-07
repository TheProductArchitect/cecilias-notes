import AppKit
import PencilKit

/// Caches downscaled stroke previews so large iPad drawings don't
/// re-render at full resolution on every SwiftUI pass.
@MainActor
enum MacStrokeThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func image(
        cacheKey: String,
        strokeData: Data,
        maxPixelHeight: CGFloat = 840
    ) -> NSImage? {
        // Fold the payload size into the key so an iPad-side edit
        // (synced stroke data changes) invalidates the entry instead
        // of pinning the first-ever render for the app's lifetime.
        let cacheKey = "\(cacheKey)-\(strokeData.count)"
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached
        }
        guard let drawing = try? PKDrawing(data: strokeData),
              !drawing.bounds.isEmpty else { return nil }

        let bounds = drawing.bounds
        let scale = min(2, maxPixelHeight / max(bounds.height, 1))
        let image = drawing.image(from: bounds, scale: scale)
        cache.setObject(image, forKey: cacheKey as NSString)
        return image
    }
}
