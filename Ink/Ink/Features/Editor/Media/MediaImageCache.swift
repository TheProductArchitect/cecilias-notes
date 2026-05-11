import Foundation
import UIKit

/// Singleton cache of decoded `UIImage`s for `MediaAttachmentView`. Backed by
/// `NSCache` so the system evicts under memory pressure. Cost: bytes-per-row × height.
///
/// 100MB cost limit — Stage 10 spec target. The pageThumbnailCache uses an
/// independent budget of the same size; both can coexist within a typical iPad
/// session footprint.
final class MediaImageCache {

    static let shared = MediaImageCache()
    private init() {
        cache.totalCostLimit = 100 * 1024 * 1024
    }

    private let cache = NSCache<NSURL, UIImage>()

    /// Returns a decoded image for the given URL, loading from disk on cache miss.
    /// Decoding is performed on a background priority — callers should await.
    func image(at url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        return await Task.detached(priority: .userInitiated) { [cache] () -> UIImage? in
            guard let image = UIImage(contentsOfFile: url.path) else { return nil }
            cache.setObject(image, forKey: url as NSURL, cost: image.uncheckedByteCount)
            return image
        }.value
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func invalidateAll() {
        cache.removeAllObjects()
    }
}

private extension UIImage {
    /// Cost estimate for `NSCache.setObject(_:forKey:cost:)`. Marked
    /// `nonisolated` — see `PageThumbnailCache` for rationale.
    nonisolated var uncheckedByteCount: Int {
        guard let cg = cgImage else { return 0 }
        return cg.height * cg.bytesPerRow
    }
}
