import Foundation
import PDFKit
import PencilKit
import SwiftData
import UIKit

/// Step 10: PDF export quality recovery for PDF-derived notebooks.
/// Step 5.5 retired the legacy `exportAnnotatedPDF` path that
/// preserved the source PDF's text layer + hyperlinks during
/// export. This file restores the equivalent against the V6
/// `PageElement(.pdfPage) + PDFPageContent` model.
///
/// **What gets preserved.** For each notebook page that has a
/// full-bleed PDF backing element, the export copies the source
/// PDF page directly (text remains selectable / searchable;
/// hyperlinks remain clickable; embedded fonts stay intact). The
/// user's strokes / highlights / sticky notes / images / text
/// elements composite on top as PDFKit annotations.
///
/// **What still rasterises.** Pages with no PDF backing (e.g.
/// blank pages added after import) fall through to the standard
/// `ExportService.exportNotebook` rasterise pipeline. The two
/// paths coexist — a mixed notebook produces a mixed export.
@MainActor
enum PDFDerivedExport {

    /// Returns the source `pdfDocumentId` if a notebook is
    /// PDF-derived (its first non-deleted page has a full-bleed
    /// `PageElement(.pdfPage)` at `zIndex == 0`). Returns `nil`
    /// otherwise. Cheap synchronous SwiftData fetch.
    static func derivationSource(
        for notebook: Notebook,
        context: ModelContext? = nil
    ) -> UUID? {
        let context = context ?? StorageService.shared.context
        let pages = (notebook.pages ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.pageNumber < $1.pageNumber }
        guard let first = pages.first else { return nil }
        return fullBleedPDF(forPageId: first.id, context: context)?.pdfDocumentId
    }

    /// Returns the full-bleed PDF backing for a given page if one
    /// exists. "Full-bleed" = element bounds (0,0,1,1) at zIndex 0
    /// — matches the import path's seeding contract.
    static func fullBleedPDF(
        forPageId pageId: UUID,
        context: ModelContext? = nil
    ) -> PDFPageContent? {
        let context = context ?? StorageService.shared.context
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            }
        )
        let candidates = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.kind == .pdfPage }
        let fullBleed = candidates.first {
            $0.zIndex == 0
            && $0.normalizedX == 0 && $0.normalizedY == 0
            && $0.normalizedWidth == 1 && $0.normalizedHeight == 1
        } ?? candidates.first
        return fullBleed?.pdfPageContent
    }

    /// Export a PDF-derived notebook. Writes a fresh PDF whose
    /// pages are copied from the source document with annotations
    /// composited on top.
    static func export(
        notebook: Notebook,
        pages: [Page],
        outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void,
        context: ModelContext? = nil
    ) throws -> Int {
        let context = context ?? StorageService.shared.context
        let outDoc = PDFDocument()

        let total = pages.count
        var insertedIndex = 0

        for (i, page) in pages.enumerated() {
            if let pdfBacking = fullBleedPDF(forPageId: page.id, context: context),
               let pageCopy = copiedPDFPage(from: pdfBacking) {
                annotate(
                    page: page,
                    pdfPage: pageCopy,
                    context: context
                )
                outDoc.insert(pageCopy, at: insertedIndex)
                insertedIndex += 1
            } else {
                // No PDF backing — rasterise the page via the
                // standard renderer and insert as a flat image.
                if let raster = rasterisePage(page) {
                    let imagePage = PDFPage(image: raster) ?? PDFPage()
                    outDoc.insert(imagePage, at: insertedIndex)
                    insertedIndex += 1
                }
            }
            progress(Double(i + 1) / Double(total))
        }

        guard outDoc.write(to: outputURL) else {
            throw ExportError.pdfWriteFailed
        }
        return insertedIndex
    }

    // MARK: - Page copy

    /// Returns a `PDFPage` copy of the source document's
    /// `pageIndex`. PDFKit's page instances are owned by their
    /// document, so we serialise + re-deserialise the page bytes
    /// through `dataRepresentation()` to get a detachable copy.
    private static func copiedPDFPage(from content: PDFPageContent) -> PDFPage? {
        let url = content.pdfFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let doc = PDFDocument(url: url),
              content.pageIndex < doc.pageCount,
              let original = doc.page(at: content.pageIndex)
        else { return nil }
        // `dataRepresentation()` returns the single page as its
        // own PDF; round-trip it through `PDFDocument` to detach
        // from the source document's lifetime.
        guard let data = original.dataRepresentation,
              let detachedDoc = PDFDocument(data: data),
              let detachedPage = detachedDoc.page(at: 0)
        else { return nil }
        return detachedPage
    }

    // MARK: - Annotation overlay

    /// Composite every active overlay PageElement on `page` onto
    /// the supplied `PDFPage`. Strokes → image stamp, highlights →
    /// `PDFAnnotationSubtype.highlight` (with `.color` carrying
    /// the variant tint), stickies → freeText, text elements →
    /// freeText, images → image stamp.
    private static func annotate(
        page: Page,
        pdfPage: PDFPage,
        context: ModelContext
    ) {
        let bounds = pdfPage.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return }

        attachStrokes(forPage: page, bounds: bounds, on: pdfPage, context: context)
        attachHighlights(forPage: page, bounds: bounds, on: pdfPage, context: context)
        attachStickies(forPage: page, bounds: bounds, on: pdfPage, context: context)
        attachTextElements(forPage: page, bounds: bounds, on: pdfPage, context: context)
        attachImages(forPage: page, bounds: bounds, on: pdfPage, context: context)
    }

    // MARK: Strokes

    private static func attachStrokes(
        forPage page: Page,
        bounds: CGRect,
        on pdfPage: PDFPage,
        context: ModelContext
    ) {
        guard let data = StorageService.shared.strokeData(for: page),
              let drawing = try? PKDrawing(data: data) else { return }
        let strokeImage = drawing.image(
            from: CGRect(origin: .zero, size: bounds.size),
            scale: 2.0
        )
        let annotation = ImageStampAnnotation(
            bounds: CGRect(origin: .zero, size: bounds.size),
            image:  strokeImage
        )
        pdfPage.addAnnotation(annotation)
    }

    // MARK: Highlights

    private static func attachHighlights(
        forPage page: Page,
        bounds: CGRect,
        on pdfPage: PDFPage,
        context: ModelContext
    ) {
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            }
        )
        let elements = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.kind == .highlight }
        for element in elements {
            guard let content = element.highlightContent else { continue }
            // HighlightContent stores its rect in normalised
            // PDF-page coordinates (Step 5.5 design). PDF
            // coordinate space is bottom-left; the y stored is
            // top-anchored, so flip it.
            let w = CGFloat(content.rectWidth)  * bounds.width
            let h = CGFloat(content.rectHeight) * bounds.height
            let x = CGFloat(content.rectOriginX) * bounds.width
            let yTop = CGFloat(content.rectOriginY) * bounds.height
            let y = bounds.height - yTop - h
            let rect = CGRect(x: x, y: y, width: w, height: h)
            let subtype: PDFAnnotationSubtype
            switch content.style {
            case .highlight:     subtype = .highlight
            case .underline:     subtype = .underline
            case .strikethrough: subtype = .strikeOut
            }
            let annotation = PDFAnnotation(
                bounds: rect,
                forType: subtype,
                withProperties: nil
            )
            annotation.color = uiColor(forHighlightVariant: content.colorVariant)
            pdfPage.addAnnotation(annotation)
        }
    }

    private static func uiColor(forHighlightVariant key: String) -> UIColor {
        switch key {
        case "pink":   return UIColor(red: 1.00, green: 0.70, blue: 0.85, alpha: 0.4)
        case "blue":   return UIColor(red: 0.70, green: 0.85, blue: 1.00, alpha: 0.4)
        case "green":  return UIColor(red: 0.75, green: 0.95, blue: 0.70, alpha: 0.4)
        default:       return UIColor(red: 1.00, green: 0.95, blue: 0.40, alpha: 0.4)
        }
    }

    // MARK: Stickies

    private static func attachStickies(
        forPage page: Page,
        bounds: CGRect,
        on pdfPage: PDFPage,
        context: ModelContext
    ) {
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            }
        )
        let elements = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.kind == .stickyNote }
        for element in elements {
            guard let content = element.stickyNoteContent else { continue }
            let w = CGFloat(element.normalizedWidth)  * bounds.width
            let h = CGFloat(element.normalizedHeight) * bounds.height
            let x = CGFloat(element.normalizedX) * bounds.width
            let yTop = CGFloat(element.normalizedY) * bounds.height
            let y = bounds.height - yTop - h
            let rect = CGRect(
                x: max(0, min(bounds.width  - w, x)),
                y: max(0, min(bounds.height - h, y)),
                width:  max(40, w),
                height: max(24, h)
            )
            let annotation = PDFAnnotation(
                bounds: rect, forType: .freeText, withProperties: nil
            )
            annotation.contents  = content.text
            annotation.font      = UIFont(name: "Helvetica", size: 11)
                ?? .systemFont(ofSize: 11)
            annotation.fontColor = .black
            annotation.color     = uiColor(forStickyVariant: content.colorVariant)
            pdfPage.addAnnotation(annotation)
        }
    }

    private static func uiColor(forStickyVariant key: String) -> UIColor {
        switch key {
        case "pink":   return UIColor(red: 1.00, green: 0.75, blue: 0.85, alpha: 1.0)
        case "blue":   return UIColor(red: 0.70, green: 0.85, blue: 1.00, alpha: 1.0)
        case "green":  return UIColor(red: 0.75, green: 0.95, blue: 0.70, alpha: 1.0)
        default:       return UIColor(red: 1.00, green: 0.92, blue: 0.50, alpha: 1.0)
        }
    }

    // MARK: Text elements

    private static func attachTextElements(
        forPage page: Page,
        bounds: CGRect,
        on pdfPage: PDFPage,
        context: ModelContext
    ) {
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            }
        )
        let elements = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.kind == .text }
        for element in elements {
            guard let content = element.textContent,
                  !content.text.isEmpty else { continue }
            let w = CGFloat(element.normalizedWidth)  * bounds.width
            let h = CGFloat(element.normalizedHeight) * bounds.height
            let x = CGFloat(element.normalizedX) * bounds.width
            let yTop = CGFloat(element.normalizedY) * bounds.height
            let y = bounds.height - yTop - h
            let rect = CGRect(x: x, y: y, width: w, height: h)
            let annotation = PDFAnnotation(
                bounds: rect, forType: .freeText, withProperties: nil
            )
            annotation.contents  = content.text
            annotation.font      = UIFont.systemFont(ofSize: CGFloat(content.size.pointSize))
            annotation.fontColor = .black
            annotation.color     = .clear
            pdfPage.addAnnotation(annotation)
        }
    }

    // MARK: Images

    private static func attachImages(
        forPage page: Page,
        bounds: CGRect,
        on pdfPage: PDFPage,
        context: ModelContext
    ) {
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            },
            // `createdAt` tiebreaker is load-bearing: inserted images
            // all share zIndex 0, so a zIndex-only sort left the
            // stacking order ARBITRARY per export — a 20-image page
            // came out shuffled relative to the editor. Annotations
            // stack in add order, so fetch order IS z-order here.
            sortBy: [SortDescriptor(\.zIndex), SortDescriptor(\.createdAt)]
        )
        let elements = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.kind == .image }
        for element in elements {
            guard let content = element.imageContent else { continue }
            // In-row bytes first — a notebook imported from a
            // `.ceciliabook` (or synced via CloudKit) may not have
            // its local file cache written yet; exporting before
            // viewing the page dropped those images. Crop applied to
            // match the editor's rendering.
            let bytes = content.imageData
                ?? (try? Data(contentsOf: content.fileURL))
            guard let bytes, let raw = UIImage(data: bytes) else { continue }
            let image = ImageDataView.applyCrop(
                to: raw,
                x: content.cropOriginX, y: content.cropOriginY,
                w: content.cropWidth, h: content.cropHeight
            )
            let w = CGFloat(element.normalizedWidth)  * bounds.width
            let h = CGFloat(element.normalizedHeight) * bounds.height
            let x = CGFloat(element.normalizedX) * bounds.width
            let yTop = CGFloat(element.normalizedY) * bounds.height
            let y = bounds.height - yTop - h
            let rect = CGRect(x: x, y: y, width: w, height: h)
            let annotation = ImageStampAnnotation(
                bounds: rect,
                image: image,
                rotation: CGFloat(element.rotation)
            )
            pdfPage.addAnnotation(annotation)
        }
    }

    // MARK: Rasterise fallback

    /// Last-resort rasteriser for notebook pages that have no PDF
    /// backing (a blank page inserted into a PDF-derived notebook,
    /// for example). Uses the standard PageRenderer-equivalent
    /// path: paper colour + template + strokes + text-blocks.
    /// Stand-alone here so the PDFKit pipeline above doesn't have
    /// to fork.
    private static func rasterisePage(_ page: Page) -> UIImage? {
        // Non-PDF page spliced into a PDF-derived notebook (a blank
        // page the user added). Route through the main exporter's
        // fresh-page renderer so the rasterised output picks up V6
        // text, sticky, shape, and highlight elements — the
        // earlier version drew only paper + strokes, so anything
        // the user added through the V6 surfaces silently dropped.
        return ExportService.shared.rasterisePageForFallback(page)
    }
}

// MARK: - ImageStampAnnotation

/// Reusable PDFAnnotation subclass that paints a UIImage into its
/// bounds. Used for both the stroke composite and per-image
/// element overlays in the PDF-derived export. PDFKit caches the
/// rendered tiles.
final class ImageStampAnnotation: PDFAnnotation {
    private let image: UIImage
    /// Editor-space rotation in radians (clockwise-positive in the
    /// editor's y-down space). `0` for the stroke composite.
    private let rotation: CGFloat

    nonisolated init(bounds: CGRect, image: UIImage, rotation: CGFloat = 0) {
        self.image = image
        self.rotation = rotation
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    nonisolated override init(bounds: CGRect, forType annotationType: PDFAnnotationSubtype, withProperties properties: [AnyHashable: Any]?) {
        fatalError("ImageStampAnnotation requires init(bounds:image:)")
    }

    @available(*, unavailable)
    nonisolated required init?(coder: NSCoder) {
        fatalError("ImageStampAnnotation does not support coder")
    }

    nonisolated override func draw(with box: PDFDisplayBox, in context: CGContext) {
        super.draw(with: box, in: context)
        context.saveGState()
        defer { context.restoreGState() }
        // Rotation about the stamp's centre. The editor rotates in
        // y-down screen space; this context is y-up, so the sign
        // flips to keep the on-screen direction.
        if rotation != 0 {
            context.translateBy(x: bounds.midX, y: bounds.midY)
            context.rotate(by: -rotation)
            context.translateBy(x: -bounds.midX, y: -bounds.midY)
        }
        // The annotation context is PDF page space — y-UP, exactly
        // why the caller computes `bounds.height - yTop - h` for the
        // annotation origin. `UIImage.draw` assumes a y-DOWN UIKit
        // context, so drawing it here unflipped rendered every
        // stamped image VERTICALLY MIRRORED (device report: exported
        // page of ~20 photos "flipped"). Flip the context across the
        // stamp's horizontal midline before handing it to UIKit.
        context.translateBy(x: 0, y: bounds.minY + bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        image.draw(in: bounds)
    }
}

