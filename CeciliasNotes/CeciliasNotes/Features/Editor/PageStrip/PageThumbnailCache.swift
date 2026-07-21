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
/// Cache keys are composite `(pageId, contentStamp, pdfFingerprint,
/// elementsFingerprint)` where `contentStamp` is `page.updatedAt`
/// and `elementsFingerprint` digests the active elements' own
/// `updatedAt` stamps. Every stroke persist bumps the page's
/// `updatedAt` (and stroke rewrites that bypass `updatePageStrokes`
/// call `StrokeCommit.stampPage`); text / sticky / shape / image
/// edits stamp their element row, which the fingerprint picks up.
/// A change produces a new key and old entries orphan and evict
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
        /// Combined count + latest `updatedAt` across the page's
        /// active elements. Text / sticky / shape edits stamp the
        /// ELEMENT row, not `page.updatedAt` — without this the key
        /// never changed for those kinds and the strip served stale
        /// thumbnails forever.
        let elementsFingerprint: UInt64
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
            let layers = Self.loadElementLayersOffMain(pageId: pageId, container: container)
            #if DEBUG
            dlog("[Thumb] render begin pageId=\(pageId) stamp=\(key.contentStamp) strokes=\(drawing?.strokes.count ?? 0) images=\(layers.images.count) texts=\(layers.texts.count) stickies=\(layers.stickies.count) shapes=\(layers.shapes.count) highlights=\(layers.highlights.count) audio=\(layers.audios.count)")
            #endif
            let image = await Self.render(
                drawing: drawing,
                layers: layers,
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
    /// pure property read plus one small element-row fetch — this
    /// runs per strip-row body evaluation, and reading stroke bytes
    /// here is exactly the main-thread SQLite storm the stamp-based
    /// key exists to prevent.
    func composeKey(for page: Page) -> Key {
        let meta = Self.lookupElementsMetadata(forPageId: page.id)
        return Key(
            pageId: page.id,
            contentStamp: page.updatedAt,
            pdfFingerprint: meta.pdfIndex.map { UInt64($0) + 1 } ?? 0,
            elementsFingerprint: meta.fingerprint
        )
    }

    /// One element-row fetch (property reads only, no blobs)
    /// yielding both key ingredients:
    ///   • `pdfIndex` — page index of the full-bleed PDF backing,
    ///     mirroring `lookupPDFBacking` minus the file-exists check.
    ///   • `fingerprint` — order-independent digest of the active
    ///     elements: count folded with every element's `updatedAt`
    ///     bit pattern. Text / sticky / shape / image edits stamp
    ///     the ELEMENT row, not `page.updatedAt`, so this is what
    ///     makes the composite key change (and the strip re-render)
    ///     when non-stroke content changes.
    @MainActor
    static func lookupElementsMetadata(
        forPageId pageId: UUID
    ) -> (pdfIndex: Int?, fingerprint: UInt64) {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pageId && $0.deletedAt == nil
            }
        )
        guard let elements = try? context.fetch(descriptor) else { return (nil, 0) }

        var acc = UInt64(elements.count)
        for element in elements {
            acc = acc &+ element.updatedAt
                .timeIntervalSinceReferenceDate.bitPattern
        }

        let candidates = elements.filter { $0.kind == .pdfPage }
        let fullBleed = candidates.first {
            $0.zIndex == 0 &&
                $0.normalizedX == 0 && $0.normalizedY == 0 &&
                $0.normalizedWidth == 1 && $0.normalizedHeight == 1
        } ?? candidates.first
        return (fullBleed?.pdfPageContent?.pageIndex, acc)
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

    /// Plain-text projection of a `.text` element. The thumbnail is
    /// far too small for rich-text fidelity; plain `text` + `size`
    /// gives the visual gist without unarchiving attributed data
    /// off-main.
    struct TextLayer: Sendable {
        let text: String
        let size: TextSize
        let rect: CGRect
        let rotation: Double
        let zIndex: Int
    }

    struct StickyLayer: Sendable {
        let text: String
        let colorVariant: String
        let rect: CGRect
        let rotation: Double
        let zIndex: Int
    }

    struct ShapeLayer: Sendable {
        let kind: ShapeKind
        let strokeColorHex: String
        let strokeWidth: Double
        let fillColorHex: String?
        let fillOpacity: Double
        let rect: CGRect
        let rotation: Double
        let zIndex: Int
    }

    struct HighlightLayer: Sendable {
        let style: HighlightStyle
        let colorVariant: String
        let rect: CGRect
    }

    struct AudioLayer: Sendable {
        let rect: CGRect
    }

    /// Every element layer the thumbnail composites, snapshotted as
    /// Sendable values off the main actor.
    struct ElementLayers: Sendable {
        var images: [ImageLayer] = []
        var texts: [TextLayer] = []
        var stickies: [StickyLayer] = []
        var shapes: [ShapeLayer] = []
        var highlights: [HighlightLayer] = []
        var audios: [AudioLayer] = []
    }

    /// Fetch + decode the page's elements on a background
    /// `ModelContext`. The thumbnail used to composite only paper +
    /// PDF + ink + images — text / sticky / shape / highlight /
    /// audio content was invisible in the strip, so mostly-text
    /// pages all looked like blank paper ("can't tell which page
    /// I'm jumping to").
    nonisolated private static func loadElementLayersOffMain(
        pageId: UUID,
        container: ModelContainer
    ) -> ElementLayers {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pageId && $0.deletedAt == nil
            }
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        var layers = ElementLayers()

        for element in elements {
            let rect = CGRect(
                x: element.normalizedX,
                y: element.normalizedY,
                width: element.normalizedWidth,
                height: element.normalizedHeight
            )
            switch element.kind {
            case .image:
                guard let content = element.imageContent else { continue }
                // In-row bytes first (canonical, CloudKit-synced),
                // falling back to the on-disk file for legacy rows
                // that predate the in-row column — those images
                // rendered in the editor but were missing from the
                // strip thumbnail. Crop applied to match the editor
                // (ImageDataView crops; an uncropped thumbnail lied
                // about the page).
                let bytes = content.imageData
                    ?? (try? Data(contentsOf: content.fileURL))
                guard let bytes, let raw = UIImage(data: bytes) else { continue }
                let image = ImageDataView.applyCrop(
                    to: raw,
                    x: content.cropOriginX, y: content.cropOriginY,
                    w: content.cropWidth, h: content.cropHeight
                )
                layers.images.append(ImageLayer(
                    image: image, rect: rect,
                    rotation: element.rotation, zIndex: element.zIndex
                ))
            case .text:
                guard let content = element.textContent,
                      !content.text.isEmpty else { continue }
                layers.texts.append(TextLayer(
                    text: content.text, size: content.size, rect: rect,
                    rotation: element.rotation, zIndex: element.zIndex
                ))
            case .stickyNote:
                guard let content = element.stickyNoteContent else { continue }
                layers.stickies.append(StickyLayer(
                    text: content.text, colorVariant: content.colorVariant,
                    rect: rect,
                    rotation: element.rotation, zIndex: element.zIndex
                ))
            case .shape:
                guard let content = element.shapeContent else { continue }
                layers.shapes.append(ShapeLayer(
                    kind: content.shapeKind,
                    strokeColorHex: content.strokeColorHex,
                    strokeWidth: content.strokeWidth,
                    fillColorHex: content.fillColorHex,
                    fillOpacity: content.fillOpacity,
                    rect: rect,
                    rotation: element.rotation, zIndex: element.zIndex
                ))
            case .highlight:
                guard let content = element.highlightContent else { continue }
                // Highlight rects live on the content row in
                // normalised PDF-page coordinates; for the strip's
                // tiny scale drawing them in page space (matching
                // ExportService) is a faithful-enough hint.
                layers.highlights.append(HighlightLayer(
                    style: content.style,
                    colorVariant: content.colorVariant,
                    rect: CGRect(
                        x: content.rectOriginX, y: content.rectOriginY,
                        width: content.rectWidth, height: content.rectHeight
                    )
                ))
            case .audio:
                layers.audios.append(AudioLayer(rect: rect))
            case .stroke, .pdfPage:
                // Ink and PDF backing composite via their dedicated
                // paths (PKDrawing / drawPDFPage).
                continue
            }
        }

        layers.images.sort { $0.zIndex < $1.zIndex }
        layers.texts.sort { $0.zIndex < $1.zIndex }
        layers.stickies.sort { $0.zIndex < $1.zIndex }
        layers.shapes.sort { $0.zIndex < $1.zIndex }
        return layers
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
        "\(k.pageId.uuidString)|\(k.contentStamp.timeIntervalSinceReferenceDate)|\(k.pdfFingerprint)|\(k.elementsFingerprint)" as NSString
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
        layers: ElementLayers,
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
                for layer in layers.images {
                    let target = denormalize(layer.rect, in: targetSize)
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

                // Compositing order below mirrors ExportService's
                // page rasterisation: highlights under ink, then
                // shapes / text / stickies / audio markers on top.
                drawHighlights(layers.highlights, in: ctx.cgContext, targetSize: targetSize)

                if let drawing {
                    // `PKDrawing.image(from:scale:)` rasterises the
                    // stored drawing into a UIImage at the supplied
                    // scale. We then draw it into our composite at the
                    // target size to overlay the paper / PDF background.
                    let drawingImage = drawing.image(from: pageRect, scale: scale)
                    drawingImage.draw(in: CGRect(origin: .zero, size: targetSize))
                }

                let fontScale = targetSize.width / pageRect.width
                drawShapes(layers.shapes, in: ctx.cgContext, targetSize: targetSize, fontScale: fontScale)
                drawTexts(layers.texts, in: ctx.cgContext, targetSize: targetSize, fontScale: fontScale)
                drawStickies(layers.stickies, in: ctx.cgContext, targetSize: targetSize, fontScale: fontScale)
                drawAudioMarkers(layers.audios, in: ctx.cgContext, targetSize: targetSize)
            }
        }
        return output
    }

    nonisolated private static func denormalize(_ rect: CGRect, in targetSize: CGSize) -> CGRect {
        CGRect(
            x: rect.origin.x * targetSize.width,
            y: rect.origin.y * targetSize.height,
            width: rect.width * targetSize.width,
            height: rect.height * targetSize.height
        )
    }

    /// Applies rotation about the rect's centre, then runs `body`
    /// with the rect translated to origin — the pattern every
    /// rotated element draw shares.
    nonisolated private static func withElementTransform(
        _ ctx: CGContext, rect: CGRect, rotation: Double,
        _ body: (CGRect) -> Void
    ) {
        ctx.saveGState()
        if rotation != 0 {
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: CGFloat(rotation))
            ctx.translateBy(x: -rect.width / 2, y: -rect.height / 2)
        } else {
            ctx.translateBy(x: rect.minX, y: rect.minY)
        }
        body(CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    nonisolated private static func drawTexts(
        _ texts: [TextLayer], in ctx: CGContext,
        targetSize: CGSize, fontScale: CGFloat
    ) {
        for layer in texts {
            let rect = denormalize(layer.rect, in: targetSize)
            guard rect.width > 1, rect.height > 1 else { continue }
            // Same point sizes the editor uses (TextSize.pointSize
            // is MainActor-isolated under default isolation, so the
            // mapping is inlined here), scaled by the page →
            // thumbnail ratio so line breaks land roughly where
            // they do on the real page. Tiny but legible enough to
            // identify the page — which is the job.
            let basePointSize: CGFloat
            switch layer.size {
            case .small:   basePointSize = 14
            case .body:    basePointSize = 17
            case .heading: basePointSize = 24
            }
            let font = UIFont.systemFont(
                ofSize: max(1.5, basePointSize * fontScale),
                weight: layer.size == .heading ? .semibold : .regular
            )
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
            ]
            withElementTransform(ctx, rect: rect, rotation: layer.rotation) { box in
                (layer.text as NSString).draw(
                    with: box,
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: attrs,
                    context: nil
                )
            }
        }
    }

    nonisolated private static func drawStickies(
        _ stickies: [StickyLayer], in ctx: CGContext,
        targetSize: CGSize, fontScale: CGFloat
    ) {
        for layer in stickies {
            let rect = denormalize(layer.rect, in: targetSize)
            guard rect.width > 1, rect.height > 1 else { continue }
            withElementTransform(ctx, rect: rect, rotation: layer.rotation) { box in
                ctx.setFillColor(stickyColor(layer.colorVariant).cgColor)
                ctx.fill(box)
                guard !layer.text.isEmpty else { return }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: max(1.5, 13 * fontScale)),
                    .foregroundColor: UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
                ]
                (layer.text as NSString).draw(
                    with: box.insetBy(dx: 1, dy: 1),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: attrs,
                    context: nil
                )
            }
        }
    }

    nonisolated private static func drawShapes(
        _ shapes: [ShapeLayer], in ctx: CGContext,
        targetSize: CGSize, fontScale: CGFloat
    ) {
        for layer in shapes {
            let rect = denormalize(layer.rect, in: targetSize)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            withElementTransform(ctx, rect: rect, rotation: layer.rotation) { box in
                let stroke = UIColor(hex: layer.strokeColorHex)
                let fill = layer.fillColorHex.map {
                    UIColor(hex: $0).withAlphaComponent(CGFloat(layer.fillOpacity))
                }
                ctx.setStrokeColor(stroke.cgColor)
                ctx.setLineWidth(max(0.4, CGFloat(layer.strokeWidth) * fontScale))
                if let fill { ctx.setFillColor(fill.cgColor) }
                switch layer.kind {
                case .rectangle, .roundedRectangle:
                    if fill != nil { ctx.fill(box) }
                    ctx.stroke(box)
                case .ellipse, .star, .heart, .callout:
                    // Decorative shapes approximate as their bounding
                    // ellipse at thumbnail scale — same call
                    // ExportService makes.
                    if fill != nil { ctx.fillEllipse(in: box) }
                    ctx.strokeEllipse(in: box)
                case .triangle:
                    ctx.move(to: CGPoint(x: box.midX, y: 0))
                    ctx.addLine(to: CGPoint(x: 0, y: box.height))
                    ctx.addLine(to: CGPoint(x: box.width, y: box.height))
                    ctx.closePath()
                    if fill != nil {
                        ctx.fillPath()
                        ctx.move(to: CGPoint(x: box.midX, y: 0))
                        ctx.addLine(to: CGPoint(x: 0, y: box.height))
                        ctx.addLine(to: CGPoint(x: box.width, y: box.height))
                        ctx.closePath()
                    }
                    ctx.strokePath()
                case .line, .arrow:
                    ctx.move(to: CGPoint(x: 0, y: box.height / 2))
                    ctx.addLine(to: CGPoint(x: box.width, y: box.height / 2))
                    ctx.strokePath()
                }
            }
        }
    }

    nonisolated private static func drawHighlights(
        _ highlights: [HighlightLayer], in ctx: CGContext, targetSize: CGSize
    ) {
        for layer in highlights {
            let rect = denormalize(layer.rect, in: targetSize)
            ctx.saveGState()
            switch layer.style {
            case .highlight:
                ctx.setFillColor(highlightColor(layer.colorVariant).cgColor)
                ctx.fill(rect)
            case .underline:
                ctx.setStrokeColor(UIColor.darkGray.cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                ctx.strokePath()
            case .strikethrough:
                ctx.setStrokeColor(UIColor.darkGray.cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: rect.minX, y: rect.midY))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    /// Tiny rounded pill where the audio strip sits — enough to say
    /// "this page has a recording" at 80pt without drawing symbol
    /// images off-main.
    nonisolated private static func drawAudioMarkers(
        _ audios: [AudioLayer], in ctx: CGContext, targetSize: CGSize
    ) {
        for layer in audios {
            var rect = denormalize(layer.rect, in: targetSize)
            rect.size.height = max(rect.height, 2)
            rect.size.width = max(rect.width, 6)
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: rect.height / 2, cornerHeight: rect.height / 2,
                transform: nil
            )
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(UIColor(red: 0.55, green: 0.45, blue: 0.85, alpha: 0.45).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// Bright Default-theme sticky palette — same constants
    /// ExportService bakes into exported PDFs so the strip and the
    /// export read the same.
    nonisolated private static func stickyColor(_ key: String) -> UIColor {
        switch key {
        case "pink":  return UIColor(red: 1.00, green: 0.75, blue: 0.85, alpha: 1.0)
        case "blue":  return UIColor(red: 0.70, green: 0.85, blue: 1.00, alpha: 1.0)
        case "green": return UIColor(red: 0.75, green: 0.95, blue: 0.70, alpha: 1.0)
        default:      return UIColor(red: 1.00, green: 0.92, blue: 0.50, alpha: 1.0)
        }
    }

    nonisolated private static func highlightColor(_ key: String) -> UIColor {
        switch key {
        case "pink":  return UIColor(red: 1.00, green: 0.70, blue: 0.85, alpha: 0.4)
        case "blue":  return UIColor(red: 0.70, green: 0.85, blue: 1.00, alpha: 0.4)
        case "green": return UIColor(red: 0.75, green: 0.95, blue: 0.70, alpha: 0.4)
        default:      return UIColor(red: 1.00, green: 0.95, blue: 0.40, alpha: 0.4)
        }
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
