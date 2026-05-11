import Foundation
import PDFKit
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
    /// `targetSize` is in points; output respects screen scale. Rendering
    /// is forced to light-mode trait collection so paper colour and
    /// PencilKit dynamic stroke colours resolve deterministically — the
    /// previous implementation read `UITraitCollection.current` from a
    /// non-main executor, which sometimes returned `.unspecified` and
    /// sometimes the dark style, producing solid-black thumbnails when
    /// dark-resolved strokes happened to be drawn over the dark paper
    /// background.
    func generate(for page: Page, targetSize: CGSize) async -> UIImage? {
        if let cached = thumbnail(for: page.id) { return cached }

        let pageId    = page.id
        let pageRect  = CGRect(origin: .zero, size: page.pageSize.pointSize)
        let strokeData = page.strokeData
        // Snapshot the PDF backing on the main actor so the detached
        // render task can read a sendable URL + index pair without
        // touching the SwiftData model off-actor.
        let pdfBacking: (url: URL, index: Int)? = {
            guard let index = page.pdfPageIndex else { return nil }
            let url = StorageService.shared.sourcePDFURL(page.notebookId)
            return FileManager.default.fileExists(atPath: url.path)
                ? (url, index)
                : nil
        }()

        return await Task.detached(priority: .utility) { [cache] () -> UIImage? in
            let image = await Self.render(
                strokeData: strokeData,
                pageRect: pageRect,
                targetSize: targetSize,
                pdfBacking: pdfBacking
            )
            if let image {
                cache.setObject(image, forKey: pageId as NSUUID, cost: image.uncheckedByteCount)
            }
            return image
        }.value
    }

    func set(_ image: UIImage, for pageId: UUID) {
        cache.setObject(image, forKey: pageId as NSUUID, cost: image.uncheckedByteCount)
    }

    func invalidate(pageId: UUID) {
        cache.removeObject(forKey: pageId as NSUUID)
    }

    func invalidateAll() {
        cache.removeAllObjects()
    }

    // MARK: Rendering

    /// Composites the page paper colour + drawing into a single bitmap.
    /// Always rendered in a light-mode trait collection — page strip
    /// thumbnails should match the paper-white look of the printed page
    /// regardless of the system appearance, and PKDrawing strokes need
    /// a stable trait when resolving dynamic ink colours.
    private static func render(
        strokeData: Data?,
        pageRect: CGRect,
        targetSize: CGSize,
        pdfBacking: (url: URL, index: Int)?
    ) async -> UIImage? {
        let scale: CGFloat = targetSize.width / pageRect.width

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)

        var output: UIImage?
        lightTraits.performAsCurrent {
            output = renderer.image { ctx in
                // Paper background — always paper white, even in dark mode.
                UIColor(hex: "#FAFAF8").setFill()
                ctx.fill(CGRect(origin: .zero, size: targetSize))

                // PDF page background if this page is PDF-backed.
                if let pdfBacking,
                   let doc  = PDFDocument(url: pdfBacking.url),
                   pdfBacking.index < doc.pageCount,
                   let page = doc.page(at: pdfBacking.index) {
                    drawPDFPage(page, in: ctx.cgContext, target: CGRect(origin: .zero, size: targetSize))
                }

                guard let data = strokeData,
                      let drawing = try? PKDrawing(data: data) else { return }

                let drawingImage = drawing.image(from: pageRect, scale: scale)
                drawingImage.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        }
        return output
    }

    /// Same letterbox-fit as `PageRenderer.drawPDFPage` — keeps the
    /// PDF aspect ratio inside the target rect, centred.
    private static func drawPDFPage(_ page: PDFPage, in ctx: CGContext, target: CGRect) {
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return }
        let scale = min(
            target.width  / pageBounds.width,
            target.height / pageBounds.height
        )
        let drawnW = pageBounds.width  * scale
        let drawnH = pageBounds.height * scale
        let offsetX = (target.width  - drawnW) / 2
        let offsetY = (target.height - drawnH) / 2

        ctx.saveGState()
        ctx.translateBy(x: offsetX, y: offsetY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: pageBounds.height)
        ctx.scaleBy(x: 1, y: -1)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
    }
}

// MARK: - UIImage byte cost

private extension UIImage {
    /// Cost estimate for `NSCache.setObject(_:forKey:cost:)`. Marked
    /// `nonisolated` so the property can be read from a detached Task
    /// — `UIImage` is `@MainActor` in Swift 6, but the underlying
    /// `cgImage` / `height` / `bytesPerRow` are immutable bitmap data
    /// safe to read off the main actor.
    nonisolated var uncheckedByteCount: Int {
        guard let cg = cgImage else { return 0 }
        return cg.height * cg.bytesPerRow
    }
}
