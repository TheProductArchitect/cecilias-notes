import Foundation
import os.lock
import PDFKit
import PencilKit
import SwiftData
import UIKit

/// Singleton cache of page thumbnails. NSCache evicts under memory
/// pressure. Generation always happens off the main actor; results
/// are stored on the main actor.
///
/// Cache keys are composite `(pageId, contentStamp, pdfFingerprint)`
/// where `contentStamp` is `page.updatedAt`. Every stroke persist
/// bumps the page's `updatedAt` (and stroke rewrites that bypass
/// `updatePageStrokes` call `StrokeCommit.stampPage`), so a new
/// sketch produces a new key and old entries orphan and evict
/// naturally — no manual invalidate from the save path.
///
/// The key used to be a fingerprint OF THE STROKE BYTES — which
/// meant every `composeKey` pulled the full multi-MB stroke blob
/// out of SQLite ON THE MAIN ACTOR, and the render path fetched it
/// a second time. While drawing, every debounced save re-keyed and
/// re-rendered the strip row: two main-thread blob reads per page
/// per 1.2 s, the dominant source of the "drew a few strokes and
/// the app stopped responding" ANR. `composeKey` must stay a pure
/// property read; the render path resolves strokes from
/// `StrokeCache` or a background `ModelContext`, never main.
///
/// In-flight de-duplication: when two concurrent saves both call
/// `generate(for:targetSize:)` for the same key, the second call
/// awaits the first's result instead of starting a second render
/// task. This kills the historical race where two parallel renders
/// completed out of order and the older snapshot overwrote the
/// newer one in the cache.
final class PageThumbnailCache {

    static let shared = PageThumbnailCache()
    private init() {
        cache.totalCostLimit = 100 * 1024 * 1024  // 100MB (Stage 10 perf target)
    }

    // MARK: - Cache key

    struct Key: Hashable {
        let pageId: UUID
        let contentStamp: Date
        let pdfFingerprint: UInt64
    }

    // MARK: - Storage

    /// `NSCache` is documented thread-safe; `nonisolated(unsafe)`
    /// vouches for that across the Sendable boundary so the
    /// detached render Task can write into it without Swift 6
    /// complaining about "non-Sendable type ... cannot exit
    /// main actor-isolated context."
    private nonisolated(unsafe) let cache = NSCache<NSString, UIImage>()

    /// In-flight render coalescer. Keyed by the composite `Key`.
    /// When a second `generate` lands while the first is still
    /// running it awaits the same task instead of starting a new
    /// one. Guarded by an `OSAllocatedUnfairLock` — async-safe in
    /// a way `NSLock` is not (NSLock requires unlock on the same
    /// thread that locked, which Swift concurrency can't
    /// guarantee across `await` suspensions).
    private let inflight = OSAllocatedUnfairLock<[Key: Task<UIImage?, Never>]>(
        initialState: [:]
    )

    // MARK: Public API

    /// Returns the cached thumbnail for an exact composite key, or
    /// `nil` if not cached. The row should pass the latest fingerprint
    /// computed from `page.strokeData`.
    func thumbnail(for key: Key) -> UIImage? {
        cache.object(forKey: cacheKey(key))
    }

    /// Generates a thumbnail for the given key off the main actor and
    /// caches the result. Concurrent calls for the same key share the
    /// underlying task.
    func generate(for page: Page, targetSize: CGSize) async -> UIImage? {
        let key = composeKey(for: page)

        if let cached = thumbnail(for: key) {
            #if DEBUG
            dlog("[Thumb] cache hit pageId=\(page.id) stamp=\(key.contentStamp)")
            #endif
            return cached
        }

        // Snapshot cheap values on the main actor; NEVER the stroke
        // blob. Right after drawing the `StrokeCache` is guaranteed
        // warm (savePageAsync writes through before bumping
        // `page.updatedAt`), so the common regen path hands the
        // already-decoded PKDrawing (Sendable) to the render task.
        // A cold cache falls back to a background-ModelContext
        // fetch + decode inside the detached task.
        let pageId    = page.id
        let pageRect  = CGRect(origin: .zero, size: page.pageSize.pointSize)
        let warmDrawing = StrokeCache.shared.drawing(forPage: pageId)
        let container = StorageService.shared.container
        // Step 5.5: PDF backing now comes from the V6 PageElement
        // model. The first full-bleed `.pdfPage` element on the
        // page identifies the file + page index; rasterising it
        // off the main actor matches the legacy thumbnail path.
        let pdfBacking: (url: URL, index: Int)? = Self.lookupPDFBacking(forPageId: pageId)

        // In-flight dedupe. `withLock` holds the unfair lock for
        // the duration of the closure, then releases — never
        // across an `await`. Two cases:
        //   • An existing task is in-flight → return its value
        //     (no await held under lock).
        //   • No task in-flight → create one + register it under
        //     lock so a second `generate` call sees the same task.
        if let existing = inflight.withLock({ state -> Task<UIImage?, Never>? in
            state[key]
        }) {
            #if DEBUG
            dlog("[Thumb] await in-flight pageId=\(pageId) stamp=\(key.contentStamp)")
            #endif
            return await existing.value
        }

        let task = Task.detached(priority: .utility) { [weak self] () -> UIImage? in
            let drawing = warmDrawing
                ?? Self.loadDrawingOffMain(pageId: pageId, container: container)
            let imageLayers = Self.loadImageLayersOffMain(pageId: pageId, container: container)
            #if DEBUG
            dlog("[Thumb] render begin pageId=\(pageId) stamp=\(key.contentStamp) strokes=\(drawing?.strokes.count ?? 0) images=\(imageLayers.count)")
            #endif
            let image = await Self.render(
                drawing: drawing,
                imageLayers: imageLayers,
                pageRect: pageRect,
                targetSize: targetSize,
                pdfBacking: pdfBacking
            )
            if let image, let self {
                self.cache.setObject(
                    image,
                    forKey: self.cacheKey(key),
                    cost: image.uncheckedByteCount
                )
            }
            #if DEBUG
            dlog("[Thumb] render end   pageId=\(pageId) stamp=\(key.contentStamp) success=\(image != nil)")
            #endif
            return image
        }
        inflight.withLock { state in state[key] = task }

        let result = await task.value

        inflight.withLock { state in state[key] = nil }

        return result
    }

    /// Compose a `Key` from a page on the main actor. MUST stay a
    /// pure property read plus the small PDF-element lookup — this
    /// runs per strip-row body evaluation, and reading stroke bytes
    /// here is exactly the main-thread SQLite storm the stamp-based
    /// key exists to prevent.
    func composeKey(for page: Page) -> Key {
        let pdfIndex = Self.lookupPDFBacking(forPageId: page.id)?.index
        return Key(
            pageId: page.id,
            contentStamp: page.updatedAt,
            pdfFingerprint: pdfIndex.map { UInt64($0) + 1 } ?? 0
        )
    }

    /// Fetch + decode the page's stroke blob on a background
    /// `ModelContext`. Called ONLY from the detached render task —
    /// the whole point is that the multi-MB read never touches the
    /// main actor.
    nonisolated private static func loadDrawingOffMain(
        pageId: UUID,
        container: ModelContainer
    ) -> PKDrawing? {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pageId && $0.deletedAt == nil
            }
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        guard let data = elements
                .first(where: { $0.kind == .stroke })?
                .strokeContent?.strokeData,
              !data.isEmpty else { return nil }
        return try? PKDrawing(data: data)
    }

    /// One decoded image element ready for thumbnail compositing —
    /// plain Sendable values, no model objects.
    struct ImageLayer: Sendable {
        let image: UIImage
        /// Normalised (0…1) page rect.
        let rect: CGRect
        let rotation: Double
        let zIndex: Int
    }

    /// Fetch + decode the page's image elements on a background
    /// `ModelContext`. Thumbnails composited only paper + PDF + ink
    /// — pages whose content is photos/imports rendered as blank
    /// paper in the strip ("thumbnails won't show images").
    nonisolated private static func loadImageLayersOffMain(
        pageId: UUID,
        container: ModelContainer
    ) -> [ImageLayer] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pageId && $0.deletedAt == nil
            }
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        return elements
            .filter { $0.kind == .image }
            .compactMap { element -> ImageLayer? in
                guard let content = element.imageContent else { return nil }
                // In-row bytes first (canonical, CloudKit-synced),
                // falling back to the on-disk file for legacy rows
                // that predate the in-row column — those images
                // rendered in the editor but were missing from the
                // strip thumbnail. Crop applied to match the editor
                // (ImageDataView crops; an uncropped thumbnail lied
                // about the page).
                let bytes = content.imageData
                    ?? (try? Data(contentsOf: content.fileURL))
                guard let bytes, let raw = UIImage(data: bytes) else { return nil }
                let image = ImageDataView.applyCrop(
                    to: raw,
                    x: content.cropOriginX, y: content.cropOriginY,
                    w: content.cropWidth, h: content.cropHeight
                )
                return ImageLayer(
                    image: image,
                    rect: CGRect(
                        x: element.normalizedX,
                        y: element.normalizedY,
                        width: element.normalizedWidth,
                        height: element.normalizedHeight
                    ),
                    rotation: element.rotation,
                    zIndex: element.zIndex
                )
            }
            .sorted { $0.zIndex < $1.zIndex }
    }

    /// Step 5.5: replaces the legacy `Page.pdfPageIndex` /
    /// `Notebook.sourcePDFURL` read. Returns `(file URL, page
    /// index)` for the first full-bleed `PageElement(.pdfPage)`
    /// scoped to `pageId`, or `nil` if no PDF element is anchored
    /// to this page. Synchronous main-actor read — cheap, used
    /// only when composing thumbnail cache keys.
    @MainActor
    static func lookupPDFBacking(forPageId pageId: UUID) -> (url: URL, index: Int)? {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pageId && $0.deletedAt == nil }
        )
        guard let elements = try? context.fetch(descriptor) else { return nil }
        // Prefer a full-bleed element (zIndex 0 + bounds (0,0,1,1)) —
        // that's the Workflow A imported page. Workflow B's
        // embedded references would otherwise mask it.
        let candidates = elements.filter { $0.kind == .pdfPage }
        let fullBleed = candidates.first {
            $0.zIndex == 0 &&
                $0.normalizedX == 0 && $0.normalizedY == 0 &&
                $0.normalizedWidth == 1 && $0.normalizedHeight == 1
        } ?? candidates.first
        guard let element = fullBleed,
              let content = element.pdfPageContent else { return nil }
        let url = content.pdfFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, content.pageIndex)
    }

    /// Clear every entry. Used by the storage-reset path.
    func invalidateAll() {
        cache.removeAllObjects()
        inflight.withLock { state in
            for (_, task) in state { task.cancel() }
            state.removeAll()
        }
    }

    // MARK: - Internals

    nonisolated private func cacheKey(_ k: Key) -> NSString {
        "\(k.pageId.uuidString)|\(k.contentStamp.timeIntervalSinceReferenceDate)|\(k.pdfFingerprint)" as NSString
    }

    // MARK: Rendering

    /// Composites the page paper colour + drawing into a single
    /// bitmap. Always rendered in a light-mode trait collection — page
    /// strip thumbnails should match the paper-white look of the
    /// printed page regardless of the system appearance, and PKDrawing
    /// strokes need a stable trait when resolving dynamic ink colours.
    /// `nonisolated` is load-bearing: under
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an unannotated
    /// static func is MainActor-isolated, so awaiting it from the
    /// detached render task would hop the whole rasterisation
    /// (PDFDocument open + PKDrawing.image) back onto main.
    nonisolated private static func render(
        drawing: PKDrawing?,
        imageLayers: [ImageLayer],
        pageRect: CGRect,
        targetSize: CGSize,
        pdfBacking: (url: URL, index: Int)?
    ) async -> UIImage? {
        let scale: CGFloat = targetSize.width / pageRect.width

        let format = UIGraphicsImageRendererFormat()
        // `UIScreen.main.scale` is MainActor-isolated under Swift 6,
        // and this whole render path runs on a detached executor.
        // Hard-coding 2.0 produces correct thumbnails on every modern
        // device (Retina @2x and Super-Retina @3x both look acceptable
        // for an 80pt thumbnail) and removes the cross-actor call.
        format.scale = 2.0
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

                // Image elements, z-ordered, below the ink — matches
                // the editor's compositing (ink draws over photos).
                for layer in imageLayers {
                    let target = CGRect(
                        x: layer.rect.origin.x * targetSize.width,
                        y: layer.rect.origin.y * targetSize.height,
                        width: layer.rect.width * targetSize.width,
                        height: layer.rect.height * targetSize.height
                    )
                    if layer.rotation != 0 {
                        let cg = ctx.cgContext
                        cg.saveGState()
                        cg.translateBy(x: target.midX, y: target.midY)
                        cg.rotate(by: CGFloat(layer.rotation))
                        cg.translateBy(x: -target.midX, y: -target.midY)
                        layer.image.draw(in: target)
                        cg.restoreGState()
                    } else {
                        layer.image.draw(in: target)
                    }
                }

                guard let drawing else { return }

                // `PKDrawing.image(from:scale:)` rasterises the
                // stored drawing into a UIImage at the supplied
                // scale. We then draw it into our composite at the
                // target size to overlay the paper / PDF background.
                let drawingImage = drawing.image(from: pageRect, scale: scale)
                drawingImage.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        }
        return output
    }

    /// Letterbox-fit a PDF page into `target`. Keeps aspect ratio,
    /// centred.
    nonisolated private static func drawPDFPage(_ page: PDFPage, in ctx: CGContext, target: CGRect) {
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
