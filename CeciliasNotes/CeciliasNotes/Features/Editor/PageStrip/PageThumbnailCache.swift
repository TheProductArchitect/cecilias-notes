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
/// Phase 4E: cache keys are now composite `(pageId,
/// strokeFingerprint, pdfFingerprint)`. A new sketch produces a new
/// fingerprint and therefore a new entry; old entries orphan and
/// evict naturally. Manual `invalidate(pageId:)` is no longer needed
/// from the save path — the row asks for the thumbnail that matches
/// the current fingerprint and the cache either hits or renders.
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
        let strokeFingerprint: UInt64
        let pdfFingerprint: UInt64
    }

    /// Cheap, deterministic 64-bit fingerprint of stroke bytes. Uses
    /// FNV-1a folded over a stride so a 100KB drawing is processed in
    /// ~1KB samples — fast enough to call on every body evaluation
    /// without blocking the main thread. Sample-based; two different
    /// drawings could theoretically collide, but a single new stroke
    /// changes the size and the high-frequency samples reliably.
    static func fingerprint(of data: Data?) -> UInt64 {
        guard let data, !data.isEmpty else { return 0 }
        var hash: UInt64 = 14695981039346656037   // FNV offset basis
        let prime: UInt64 = 1099511628211
        let stride = max(1, data.count / 1024)
        var index = 0
        // Include the byte count so size deltas alone produce a new
        // fingerprint even when the sampled positions happen to match.
        let countBytes = withUnsafeBytes(of: UInt64(data.count).littleEndian) { Array($0) }
        for b in countBytes {
            hash ^= UInt64(b)
            hash = hash &* prime
        }
        while index < data.count {
            hash ^= UInt64(data[index])
            hash = hash &* prime
            index += stride
        }
        return hash
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
            print("[Thumb] cache hit pageId=\(page.id) fp=\(key.strokeFingerprint)")
            #endif
            return cached
        }

        // Snapshot the data we need off the main actor before
        // detaching. Step 8: stroke bytes read via the V6
        // singleton through the storage helper instead of the
        // retired `Page.strokeData` field; PDF backing still
        // resolves via the V6 PageElement lookup (Step 5.5).
        let pageId    = page.id
        let pageRect  = CGRect(origin: .zero, size: page.pageSize.pointSize)
        let strokeData = StorageService.shared.strokeData(for: page)
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
            print("[Thumb] await in-flight pageId=\(pageId) fp=\(key.strokeFingerprint)")
            #endif
            return await existing.value
        }

        let task = Task.detached(priority: .utility) { [weak self] () -> UIImage? in
            #if DEBUG
            print("[Thumb] render begin pageId=\(pageId) fp=\(key.strokeFingerprint) strokes=\(strokeData?.count ?? 0)")
            #endif
            let image = await Self.render(
                strokeData: strokeData,
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
            print("[Thumb] render end   pageId=\(pageId) fp=\(key.strokeFingerprint) success=\(image != nil)")
            #endif
            return image
        }
        inflight.withLock { state in state[key] = task }

        let result = await task.value

        inflight.withLock { state in state[key] = nil }

        return result
    }

    /// Compose a `Key` from a page on the main actor. Cheap — the
    /// fingerprint sample-walks the stroke bytes (~1KB of work for a
    /// 100KB drawing). Step 8 reads through the V6 storage helper.
    func composeKey(for page: Page) -> Key {
        let pdfIndex = Self.lookupPDFBacking(forPageId: page.id)?.index
        let strokeData = StorageService.shared.strokeData(for: page)
        return Key(
            pageId: page.id,
            strokeFingerprint: Self.fingerprint(of: strokeData),
            pdfFingerprint: pdfIndex.map { UInt64($0) + 1 } ?? 0
        )
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
        "\(k.pageId.uuidString)|\(k.strokeFingerprint)|\(k.pdfFingerprint)" as NSString
    }

    // MARK: Rendering

    /// Composites the page paper colour + drawing into a single
    /// bitmap. Always rendered in a light-mode trait collection — page
    /// strip thumbnails should match the paper-white look of the
    /// printed page regardless of the system appearance, and PKDrawing
    /// strokes need a stable trait when resolving dynamic ink colours.
    private static func render(
        strokeData: Data?,
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

                guard let data = strokeData,
                      let drawing = try? PKDrawing(data: data) else { return }

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
