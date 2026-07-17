import SwiftUI
import PDFKit
import PencilKit
import SwiftData
import UIKit

// MARK: - Export types

enum PageRange: Equatable {
    case all
    case current(Int)
    case range(ClosedRange<Int>)   // 1-based page numbers

    func resolve(totalPages: Int) -> [Int] {
        switch self {
        case .all:
            return Array(0..<totalPages)
        case .current(let idx):
            return [idx]
        case .range(let r):
            return r.map { $0 - 1 }.filter { $0 >= 0 && $0 < totalPages }
        }
    }
}

enum ExportQuality {
    case standard   // 150 dpi
    case high       // 300 dpi

    var dpi: CGFloat { self == .standard ? 150 : 300 }
    var scale: CGFloat { dpi / 72 }
    var label: String { self == .standard ? "Standard" : "High" }

    func estimatedSizeBytes(pageBounds: CGRect, pageCount: Int) -> Int64 {
        let px = pageBounds.width * scale * pageBounds.height * scale
        return Int64(px * 0.1) * Int64(pageCount)
    }
}

struct ExportOptions {
    var deliveryFormat:        ExportDeliveryFormat = .pdf
    var pageRange:             PageRange       = .all
    var quality:               ExportQuality   = .standard
    var includeTranscriptions: Bool            = false
    var includePageNumbers:    Bool            = true
    var includeCoverPage:      Bool            = true
}

enum ExportDeliveryFormat: String, CaseIterable, Identifiable {
    case pdf
    case markdown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf:       return "PDF"
        case .markdown:  return "Markdown"
        }
    }
}

struct ExportResult {
    var fileURL:       URL
    var fileSizeBytes: Int64
    var pageCount:     Int
    var duration:      TimeInterval
}

// MARK: - ExportService

@MainActor
final class ExportService {

    static let shared = ExportService()

    // MARK: - Main entry point

    func exportNotebook(
        _ notebook: Notebook,
        pages allPages: [Page],
        options: ExportOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult {
        let start      = Date()
        let indices    = options.pageRange.resolve(totalPages: allPages.count)
        let exportPages = indices.map { allPages[$0] }
        let total      = exportPages.count

        guard total > 0 else { throw ExportError.noPages }

        let outputURL  = try makeOutputURL(for: notebook)

        // Step 10: PDF export quality recovery. If this notebook
        // was derived from an imported PDF (first page carries a
        // full-bleed `PageElement(.pdfPage)`), route through the
        // PDFKit-based path that copies source PDF pages directly
        // and composites annotations on top. Preserves text
        // selectability, embedded fonts, and hyperlinks — the
        // regression from Step 5.5 that this step recovers.
        // Non-PDF-derived notebooks fall through to the
        // rasterise pipeline below, unchanged.
        if PDFDerivedExport.derivationSource(for: notebook) != nil {
            let count = try PDFDerivedExport.export(
                notebook:  notebook,
                pages:     exportPages,
                outputURL: outputURL,
                progress:  progress
            )
            let attrs    = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = (attrs[.size] as? Int64) ?? 0
            let duration = Date().timeIntervalSince(start)
            let record = ExportRecord(
                notebookId:    notebook.id,
                notebookTitle: notebook.title,
                fileURL:       outputURL,
                fileSizeBytes: fileSize,
                pageCount:     count,
                exportedAt:    Date()
            )
            await ExportManifest.shared.append(record)
            return ExportResult(
                fileURL:       outputURL,
                fileSizeBytes: fileSize,
                pageCount:     count,
                duration:      duration
            )
        }

        let pageBounds = exportPages[0].pageSize.pointSize.asCGRect
        let pdfInfo    = makePDFInfo(notebook: notebook)

        let renderer   = UIGraphicsPDFRenderer(bounds: pageBounds, format: pdfInfo)
        let coverIncluded = options.includeCoverPage

        try renderer.writePDF(to: outputURL) { ctx in
            // Cover page
            if coverIncluded {
                ctx.beginPage()
                drawCoverPage(ctx: ctx.cgContext, notebook: notebook, bounds: pageBounds)
            }

            // Content pages
            for (localIdx, page) in exportPages.enumerated() {
                let bounds = page.pageSize.pointSize.asCGRect
                ctx.beginPage()
                let cgCtx = ctx.cgContext

                drawTemplate(page.backgroundTemplate, ctx: cgCtx, bounds: bounds)
                drawMediaAttachments(page, ctx: cgCtx, bounds: bounds, notebook: notebook)
                drawV6Highlights(page, ctx: cgCtx, bounds: bounds)
                drawStrokes(page, ctx: cgCtx, bounds: bounds, quality: options.quality)
                drawV6Shapes(page, ctx: cgCtx, bounds: bounds)
                drawTextBlocks(page, ctx: cgCtx, bounds: bounds)
                drawV6TextElements(page, ctx: cgCtx, bounds: bounds)
                drawV6StickyNotes(page, ctx: cgCtx, bounds: bounds)

                if options.includeTranscriptions {
                    drawAudioMarkers(page, ctx: cgCtx, bounds: bounds)
                }
                if options.includePageNumbers {
                    let label = "\(localIdx + 1) / \(total)"
                    drawPageNumber(label, ctx: cgCtx, bounds: bounds)
                }

                let progressValue = Double(localIdx + 1) / Double(total)
                progress(progressValue)
            }
        }

        let attrs    = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let duration = Date().timeIntervalSince(start)

        // Record in manifest
        let record = ExportRecord(
            notebookId:    notebook.id,
            notebookTitle: notebook.title,
            fileURL:       outputURL,
            fileSizeBytes: fileSize,
            pageCount:     total,
            exportedAt:    Date()
        )
        await ExportManifest.shared.append(record)

        return ExportResult(
            fileURL:       outputURL,
            fileSizeBytes: fileSize,
            pageCount:     total,
            duration:      duration
        )
    }

    func exportNotebookMarkdown(
        _ notebook: Notebook,
        pages allPages: [Page],
        options: ExportOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult {
        let start = Date()
        let indices = options.pageRange.resolve(totalPages: allPages.count)
        let exportPages = indices.map { allPages[$0] }
        guard !exportPages.isEmpty else { throw ExportError.noPages }

        progress(0.5)
        let outputURL = try makeMarkdownOutputURL(for: notebook)
        try NotebookMarkdownExport.write(
            notebook: notebook,
            pages: exportPages,
            storage: StorageService.shared,
            to: outputURL
        )
        progress(1)

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let duration = Date().timeIntervalSince(start)
        let record = ExportRecord(
            notebookId: notebook.id,
            notebookTitle: notebook.title,
            fileURL: outputURL,
            fileSizeBytes: fileSize,
            pageCount: exportPages.count,
            exportedAt: Date()
        )
        await ExportManifest.shared.append(record)
        return ExportResult(
            fileURL: outputURL,
            fileSizeBytes: fileSize,
            pageCount: exportPages.count,
            duration: duration
        )
    }

    // MARK: - Annotated PDF export (PDF-backed notebooks)

    /// Export a PDF-backed notebook with strokes preserved as PDF
    /// annotations on the original PDF. Each PDF-backed page is
    /// copied from the source `PDFDocument` and a `.stamp` annotation
    /// is added containing the user's PencilKit strokes rendered to
    /// an image. Non-PDF pages (blank pages added after import)
    /// render as fresh PDF pages — same drawing pipeline as the
    /// regular export.
    ///
    /// Why `.stamp` over `.ink`:
    ///   `.stamp` ships the strokes as a rendered image attached to
    ///   the page. Any PDF reader (Preview, Adobe Reader, Chrome)
    ///   displays it correctly. `.ink` annotations are vector but
    ///   require translating each `PKStroke`'s Bezier path geometry
    ///   into PDF ink-annotation path space — more work than this v1
    ///   warrants. Upgrade path is open if quality complaints arise.
    // Step 5.5: `exportAnnotatedPDF` removed. PDF notebooks
    // export through the standard render path; rebuilding the
    // annotated path against V6 `.pdfPage` + `.highlight`
    // PageElements is queued for Step 10.

    /// Rasterise the page's PencilKit strokes and attach them as a
    /// `.stamp` annotation sized to the PDF page's media box. The
    /// stamp's appearance is set via a PDFAnnotation custom drawing
    /// override — we render the PKDrawing image into the annotation
    /// at draw-time. PDFKit caches the rendered tiles.
    private func attachStrokesAnnotation(
        from drawing: PKDrawing,
        pageBounds: CGRect,
        to pdfPage: PDFPage
    ) {
        // Render PKDrawing into a UIImage sized to the PDF page's
        // media box at 2× scale. Scaling above 2× hits diminishing
        // returns for stroke smoothness and balloons file size.
        let strokeImage = drawing.image(
            from: CGRect(origin: .zero, size: pageBounds.size),
            scale: 2.0
        )

        let annotation = StrokeStampAnnotation(
            bounds: CGRect(origin: .zero, size: pageBounds.size),
            image:  strokeImage
        )
        pdfPage.addAnnotation(annotation)
    }

    /// Add a `PDFAnnotation.freeText` for each sticky element on
    /// the page. PDF freeText annotations show as an in-document
    /// text box in any reader (Preview, Adobe, Chrome). Readers
    /// that surface annotations in a sidebar also list the body
    /// verbatim.
    ///
    /// Step 7: reads V6 `PageElement(.stickyNote) +
    /// StickyNoteContent` rows. Geometry is the element's
    /// normalised top-left rect (flipped into PDF bottom-left
    /// coords); the card's colour variant maps to a hex through
    /// the same palette key the editor renders with.
    private func attachStickyNotes(
        pageId: UUID,
        pageBounds: CGRect,
        to pdfPage: PDFPage
    ) {
        let elements = fetchStickyElements(forPageId: pageId)
        guard !elements.isEmpty else { return }

        for element in elements {
            guard let content = element.stickyNoteContent else { continue }

            let width  = CGFloat(element.normalizedWidth)  * pageBounds.width
            let height = CGFloat(element.normalizedHeight) * pageBounds.height
            let x      = CGFloat(element.normalizedX) * pageBounds.width
            let yTop   = CGFloat(element.normalizedY) * pageBounds.height
            // PDF origin is bottom-left; flip the y.
            let y = pageBounds.height - yTop - height
            let bounds = CGRect(
                x: max(0, min(pageBounds.width  - width,  x)),
                y: max(0, min(pageBounds.height - height, y)),
                width:  max(40, width),
                height: max(24, height)
            )

            let annotation = PDFAnnotation(
                bounds:     bounds,
                forType:    .freeText,
                withProperties: nil
            )
            annotation.contents  = content.text
            annotation.font      = UIFont(name: "Helvetica", size: 11)
                ?? .systemFont(ofSize: 11)
            annotation.fontColor = .black
            annotation.color     = uiColor(forStickyVariant: content.colorVariant)
            pdfPage.addAnnotation(annotation)
        }
    }

    /// Fetch active V6 sticky-note elements for a page. Filter
    /// `kind == .stickyNote` in Swift (iOS 26 `#Predicate`
    /// limitation, same as `fetchImageElements`).
    private func fetchStickyElements(forPageId pageId: UUID) -> [PageElement] {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pageId && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.zIndex), SortDescriptor(\.createdAt)]
        )
        let all = (try? StorageService.shared.context.fetch(descriptor)) ?? []
        return all.filter { $0.kind == .stickyNote }
    }

    /// Map a sticky `colorVariant` key to a PDFAnnotation fill
    /// colour. Mirrors the bright Default-theme sticky palette so
    /// exported PDFs read the same as the on-screen card without
    /// having to round-trip through `Theme`.
    private func uiColor(forStickyVariant key: String) -> UIColor {
        switch key {
        case "pink":   return UIColor(red: 1.00, green: 0.75, blue: 0.85, alpha: 1.0)
        case "blue":   return UIColor(red: 0.70, green: 0.85, blue: 1.00, alpha: 1.0)
        case "green":  return UIColor(red: 0.75, green: 0.95, blue: 0.70, alpha: 1.0)
        default:       return UIColor(red: 1.00, green: 0.92, blue: 0.50, alpha: 1.0)  // yellow
        }
    }

    /// Bake every active image attachment for this page into a
    /// single full-page-sized `.stamp` annotation. Mirrors
    /// `attachStrokesAnnotation` — one stamp per surface so the
    /// PDF stays compact and renders identically in any reader
    /// (Preview, Adobe, Chrome). Skipped for pages with no images.
    private func attachMediaImagesAnnotation(
        pageId: UUID,
        pageBounds: CGRect,
        to pdfPage: PDFPage
    ) {
        // Step 4: read V6 `PageElement(kind: .image)` + `ImageContent`
        // rows in place of the retired `MediaAttachmentStore`. Geometry
        // is identical; `element.rotation` is radians (vs the legacy
        // `record.rotation` degrees), so the multiplier drops.
        let elements = fetchImageElements(forPageId: pageId)
        guard !elements.isEmpty else { return }

        let scale: CGFloat = 2.0
        let pixelSize = CGSize(
            width:  pageBounds.width  * scale,
            height: pageBounds.height * scale
        )
        UIGraphicsBeginImageContextWithOptions(pixelSize, false, scale)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.scaleBy(x: scale, y: scale)

        for element in elements {
            guard let content = element.imageContent,
                  let image = exportImage(for: content) else { continue }
            let rect = CGRect(
                x:      element.normalizedX      * pageBounds.width,
                y:      element.normalizedY      * pageBounds.height,
                width:  element.normalizedWidth  * pageBounds.width,
                height: element.normalizedHeight * pageBounds.height
            )
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: -CGFloat(element.rotation))
            ctx.translateBy(x: -rect.width / 2, y: -rect.height / 2)
            image.draw(in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }
        guard let composite = UIGraphicsGetImageFromCurrentImageContext() else { return }
        let annotation = StrokeStampAnnotation(
            bounds: CGRect(origin: .zero, size: pageBounds.size),
            image:  composite
        )
        pdfPage.addAnnotation(annotation)
    }

    /// Step 4 helper: fetch V6 image elements for a page, sorted by
    /// `zIndex` then `createdAt` so the export render order matches
    /// the editor's stacking. `kind == .image` is filtered in Swift
    /// because the `#Predicate` macro rejects enum-case equality
    /// inside key-path comparisons on iOS 26.
    private func fetchImageElements(forPageId pageId: UUID) -> [PageElement] {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pageId && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.zIndex), SortDescriptor(\.createdAt)]
        )
        let all = (try? StorageService.shared.context.fetch(descriptor)) ?? []
        return all.filter { $0.kind == .image }
    }

    // Step 5.5: `attachTextAnnotations` removed alongside
    // `PDFTextAnnotationStore` + `PDFAnnotationWriter`. Highlights
    // are V6 `PageElement(.highlight)` rows; an exporter that
    // stamps them as real `PDFAnnotation` objects on the exported
    // copy is queued for Step 10 (sync polish).

    // `makeFreshPDFPage` removed (2026-07-17 audit): zero callers —
    // superseded by `rasterisePageForFallback`, which draws the FULL
    // V6 element set; the dead copy silently drew only
    // template/media/strokes/text-blocks and was a trap for the
    // next caller.

    /// Fallback rasteriser shared with `PDFDerivedExport` for
    /// non-PDF pages spliced into a PDF-derived notebook. Walks
    /// the same V6 element kinds as the main export so a sticky
    /// note / shape / typed text element on a blank page in a
    /// PDF notebook actually shows up in the exported file.
    func rasterisePageForFallback(_ page: Page) -> UIImage? {
        guard let notebook = page.notebook else { return nil }
        let bounds = CGRect(origin: .zero, size: page.pageSize.pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        return renderer.image { ctx in
            let cgCtx = ctx.cgContext
            drawTemplate(page.backgroundTemplate, ctx: cgCtx, bounds: bounds)
            drawMediaAttachments(page, ctx: cgCtx, bounds: bounds, notebook: notebook)
            drawV6Highlights(page, ctx: cgCtx, bounds: bounds)
            drawStrokes(page, ctx: cgCtx, bounds: bounds, quality: .standard)
            drawV6Shapes(page, ctx: cgCtx, bounds: bounds)
            drawTextBlocks(page, ctx: cgCtx, bounds: bounds)
            drawV6TextElements(page, ctx: cgCtx, bounds: bounds)
            drawV6StickyNotes(page, ctx: cgCtx, bounds: bounds)
        }
    }

    // MARK: - Thumbnail for live preview

    func renderPreviewThumbnail(
        page: Page,
        notebook: Notebook,
        options: ExportOptions,
        size: CGSize
    ) async -> UIImage? {
        let bounds = page.pageSize.pointSize.asCGRect
        let pdfInfo = makePDFInfo(notebook: notebook)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: pdfInfo)

        let data = renderer.pdfData { ctx in
            if options.includeCoverPage {
                ctx.beginPage()
                drawCoverPage(ctx: ctx.cgContext, notebook: notebook, bounds: bounds)
            }
            ctx.beginPage()
            let cgCtx = ctx.cgContext
            drawTemplate(page.backgroundTemplate, ctx: cgCtx, bounds: bounds)
            drawMediaAttachments(page, ctx: cgCtx, bounds: bounds, notebook: notebook)
            drawV6Highlights(page, ctx: cgCtx, bounds: bounds)
            drawStrokes(page, ctx: cgCtx, bounds: bounds, quality: options.quality)
            drawV6Shapes(page, ctx: cgCtx, bounds: bounds)
            drawTextBlocks(page, ctx: cgCtx, bounds: bounds)
            drawV6TextElements(page, ctx: cgCtx, bounds: bounds)
            drawV6StickyNotes(page, ctx: cgCtx, bounds: bounds)
        }

        guard let pdfDoc  = PDFDocument(data: data),
              let pdfPage = pdfDoc.page(at: options.includeCoverPage ? 1 : 0)
        else { return nil }

        let thumb = pdfPage.thumbnail(of: size, for: .trimBox)
        return thumb
    }

    // MARK: - Output URL

    private func makeOutputURL(for notebook: Notebook) throws -> URL {
        let exportsDir = Self.globalExportsDirectory
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let safeTitle = notebook.title
            .components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60)

        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let base    = "\(safeTitle)_\(dateStr)"
        var url     = exportsDir.appendingPathComponent(base + ".pdf")
        var suffix  = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = exportsDir.appendingPathComponent("\(base)_\(suffix).pdf")
            suffix += 1
        }
        return url
    }

    private func makeMarkdownOutputURL(for notebook: Notebook) throws -> URL {
        let exportsDir = Self.globalExportsDirectory
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let safeTitle = notebook.title
            .components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60)

        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let base = "\(safeTitle)_\(dateStr)"
        var url = exportsDir.appendingPathComponent(base + ".md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = exportsDir.appendingPathComponent("\(base)_\(suffix).md")
            suffix += 1
        }
        return url
    }

    static var globalExportsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CeciliasNotes")
            .appendingPathComponent("Exports")
    }

    // MARK: - PDF info

    private func makePDFInfo(notebook: Notebook) -> UIGraphicsPDFRendererFormat {
        let info = UIGraphicsPDFRendererFormat()
        var docInfo: [String: Any] = [
            kCGPDFContextTitle  as String: notebook.title,
            kCGPDFContextAuthor as String: "Cecilia's Notes",
        ]
        if !notebook.tags.isEmpty {
            docInfo[kCGPDFContextKeywords as String] = notebook.tags.joined(separator: ", ")
        }
        info.documentInfo = docInfo
        return info
    }

    // MARK: - Template background (vector)

    private func drawTemplate(_ template: PageTemplate, ctx: CGContext, bounds: CGRect) {
        // Paper background
        ctx.setFillColor(UIColor(hex: "#FAFAF8").cgColor)
        ctx.fill(bounds)

        let lineColor = UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.25).cgColor
        ctx.setStrokeColor(lineColor)
        ctx.setLineWidth(0.5)

        // 1mm ≈ 2.83pt at 96dpi — matches the SwiftUI `TemplatePatternView`'s
        // full-page geometry so the PDF and the editor canvas line up.
        let mm: (CGFloat) -> CGFloat = { $0 * 2.83 }

        // Centred and edge-flush layouts so the rendered PDF
        // matches the editor's `TemplatePatternView`. The earlier
        // loops started at `spacing` and stopped before the bottom
        // edge, leaving a whole-spacing gap at the top and an
        // irregular gap at the bottom; users called this out as
        // visible "cream strips" above and below the grid.
        let drawHLines: (CGFloat) -> Void = { spacing in
            let lines = max(1, Int(bounds.height / spacing))
            let usedHeight = CGFloat(lines) * spacing
            let topOffset = max(0, (bounds.height - usedHeight) / 2)
            var y = topOffset + spacing
            while y < bounds.height {
                ctx.move(to:    CGPoint(x: 16,                y: y))
                ctx.addLine(to: CGPoint(x: bounds.width - 16, y: y))
                y += spacing
            }
            ctx.strokePath()
        }
        let drawSquareGrid: (CGFloat) -> Void = { spacing in
            // Edge-to-edge: round the cell count, then scale the
            // step so the first/last lines land exactly on the
            // page edges.
            let cellsY = max(1, Int((bounds.height / spacing).rounded()))
            let cellsX = max(1, Int((bounds.width  / spacing).rounded()))
            let stepY = bounds.height / CGFloat(cellsY)
            let stepX = bounds.width  / CGFloat(cellsX)
            for i in 0...cellsY {
                let y = CGFloat(i) * stepY
                ctx.move(to:    CGPoint(x: 0,            y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            }
            for i in 0...cellsX {
                let x = CGFloat(i) * stepX
                ctx.move(to:    CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            }
            ctx.strokePath()
        }
        let drawDotGrid: (CGFloat) -> Void = { spacing in
            ctx.setFillColor(UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.30).cgColor)
            let r: CGFloat = 1.5
            let cellsY = max(1, Int(bounds.height / spacing))
            let cellsX = max(1, Int(bounds.width  / spacing))
            let topOffset  = max(0, (bounds.height - CGFloat(cellsY) * spacing) / 2)
            let leftOffset = max(0, (bounds.width  - CGFloat(cellsX) * spacing) / 2)
            var y = topOffset + spacing
            while y < bounds.height {
                var x = leftOffset + spacing
                while x < bounds.width {
                    ctx.fillEllipse(in: CGRect(x: x - r/2, y: y - r/2, width: r, height: r))
                    x += spacing
                }
                y += spacing
            }
        }

        switch template {
        case .blank:
            break

        case .narrowRuled:    drawHLines(mm(7))
        case .wideRuled:      drawHLines(mm(10))
        case .collegeRuled:
            drawHLines(mm(9))
            // Red margin line on the left.
            let marginX = bounds.width * 0.12
            ctx.setStrokeColor(UIColor(red: 0.88, green: 0.55, blue: 0.55, alpha: 1).cgColor)
            ctx.move(to:    CGPoint(x: marginX, y: 0))
            ctx.addLine(to: CGPoint(x: marginX, y: bounds.height))
            ctx.strokePath()
            ctx.setStrokeColor(lineColor)

        case .twoColumn:
            let centerX = bounds.width / 2
            ctx.move(to:    CGPoint(x: centerX, y: 0))
            ctx.addLine(to: CGPoint(x: centerX, y: bounds.height))
            ctx.strokePath()
            // Lines either side.
            let spacing = mm(9)
            var y = spacing
            while y < bounds.height {
                ctx.move(to:    CGPoint(x: 12,                  y: y))
                ctx.addLine(to: CGPoint(x: centerX - 4,         y: y))
                ctx.move(to:    CGPoint(x: centerX + 4,         y: y))
                ctx.addLine(to: CGPoint(x: bounds.width - 12,   y: y))
                y += spacing
            }
            ctx.strokePath()

        case .dotGrid5:        drawDotGrid(mm(5))
        case .dotGrid10:       drawDotGrid(mm(10))

        case .squareGrid5:     drawSquareGrid(mm(5))
        case .squareGrid10:    drawSquareGrid(mm(10))
        case .engineeringGrid:
            // 1mm sub-grid (lighter), then 5mm main grid.
            ctx.setStrokeColor(UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.10).cgColor)
            ctx.setLineWidth(0.2)
            drawSquareGrid(mm(1))
            ctx.setStrokeColor(lineColor)
            ctx.setLineWidth(0.5)
            drawSquareGrid(mm(5))

        case .cornell:
            let marginX = bounds.width  * 0.20
            let titleY  = bounds.height * 0.15
            ctx.move(to: CGPoint(x: marginX, y: 0))
            ctx.addLine(to: CGPoint(x: marginX, y: bounds.height))
            ctx.move(to: CGPoint(x: 0,           y: titleY))
            ctx.addLine(to: CGPoint(x: bounds.width, y: titleY))
            ctx.strokePath()

        case .music:
            let staffSpacing: CGFloat = 8
            let groupSpacing: CGFloat = 30
            var y: CGFloat = 20
            while y + staffSpacing * 4 < bounds.height {
                for line in 0..<5 {
                    let ly = y + CGFloat(line) * staffSpacing
                    ctx.move(to:    CGPoint(x: 16,                y: ly))
                    ctx.addLine(to: CGPoint(x: bounds.width - 16, y: ly))
                }
                ctx.strokePath()
                y += staffSpacing * 4 + groupSpacing
            }

        case .isoDots:
            // Isometric dot grid — alternating rows offset by half a
            // step, row height = spacing × sin(60°) so the dots form
            // equilateral triangles.
            ctx.setFillColor(UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.30).cgColor)
            let isoSpacing = mm(7)
            let rowHeight  = isoSpacing * 0.866
            let r: CGFloat = 1.5
            var y: CGFloat = rowHeight
            var rowIdx = 0
            while y < bounds.height {
                let xOffset = rowIdx.isMultiple(of: 2) ? 0 : isoSpacing / 2
                var x = isoSpacing / 2 + xOffset
                while x < bounds.width {
                    ctx.fillEllipse(in: CGRect(x: x - r/2, y: y - r/2, width: r, height: r))
                    x += isoSpacing
                }
                y += rowHeight
                rowIdx += 1
            }

        case .storyboard:
            // 2 cols × 3 rows of frame outlines with label gutter
            // beneath each. Matches the SwiftUI thumbnail's layout.
            let cols = 2
            let rows = 3
            let padding: CGFloat     = 12
            let labelHeight: CGFloat = 16
            let cellWidth  = (bounds.width  - padding * CGFloat(cols + 1)) / CGFloat(cols)
            let cellHeight =
                (bounds.height - padding * CGFloat(rows + 1) - labelHeight * CGFloat(rows))
                    / CGFloat(rows)
            for row in 0..<rows {
                for col in 0..<cols {
                    let fx = padding + CGFloat(col) * (cellWidth + padding)
                    let fy = padding + CGFloat(row) * (cellHeight + labelHeight + padding)
                    let frameRect = CGRect(x: fx, y: fy, width: cellWidth, height: cellHeight)
                    let path = CGPath(roundedRect: frameRect, cornerWidth: 1, cornerHeight: 1,
                                      transform: nil)
                    ctx.addPath(path)
                }
            }
            ctx.strokePath()

        case .mindMap:
            // Anchor circle at centre + 6 radial guides at 60°
            // intervals. Guides start from the circle's edge (not
            // centre) so the anchor reads as a contained shape.
            let centerX = bounds.width  / 2
            let centerY = bounds.height / 2
            let radius: CGFloat = 40
            let circleRect = CGRect(
                x: centerX - radius, y: centerY - radius,
                width: radius * 2,   height: radius * 2
            )
            ctx.setStrokeColor(UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.40).cgColor)
            ctx.strokeEllipse(in: circleRect)

            ctx.setStrokeColor(UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.20).cgColor)
            ctx.setLineWidth(0.3)
            let radial = max(bounds.width, bounds.height)
            for i in 0..<6 {
                let angle = Double(i) * .pi / 3
                let startX = centerX + cos(angle) * radius
                let startY = centerY + sin(angle) * radius
                let endX   = centerX + cos(angle) * radial
                let endY   = centerY + sin(angle) * radial
                ctx.move(to:    CGPoint(x: startX, y: startY))
                ctx.addLine(to: CGPoint(x: endX,   y: endY))
            }
            ctx.strokePath()
            ctx.setStrokeColor(lineColor)
            ctx.setLineWidth(0.5)

        case .calendarWeek:
            // 7 columns (Mon-Sun) × 14 hourly rows, with a header row
            // and a left time column.
            let headerH:  CGFloat = 24
            let timeColW: CGFloat = 28
            let cols = 7
            let rows = 14
            let colWidth  = (bounds.width  - timeColW) / CGFloat(cols)
            let rowHeightCal = (bounds.height - headerH)  / CGFloat(rows)

            // Header rule.
            ctx.move(to:    CGPoint(x: 0,            y: headerH))
            ctx.addLine(to: CGPoint(x: bounds.width, y: headerH))
            ctx.strokePath()

            // Vertical column dividers.
            ctx.setStrokeColor(UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.20).cgColor)
            ctx.setLineWidth(0.3)
            for i in 0...cols {
                let x = timeColW + CGFloat(i) * colWidth
                ctx.move(to:    CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            }
            ctx.strokePath()

            // Hourly row dividers (lighter still).
            ctx.setStrokeColor(UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.15).cgColor)
            ctx.setLineWidth(0.2)
            for i in 1..<rows {
                let y = headerH + CGFloat(i) * rowHeightCal
                ctx.move(to:    CGPoint(x: timeColW,     y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            }
            ctx.strokePath()
            ctx.setStrokeColor(lineColor)
            ctx.setLineWidth(0.5)

        case .dayPlanner:
            // Time column on the left + 16 hourly rows.
            let timeColW = bounds.width * 0.18
            let rowsDP   = 16
            let rowHeightDP = bounds.height / CGFloat(rowsDP)

            ctx.move(to:    CGPoint(x: timeColW, y: 0))
            ctx.addLine(to: CGPoint(x: timeColW, y: bounds.height))
            ctx.strokePath()

            ctx.setStrokeColor(UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.20).cgColor)
            ctx.setLineWidth(0.3)
            for i in 1..<rowsDP {
                let y = CGFloat(i) * rowHeightDP
                ctx.move(to:    CGPoint(x: 0,            y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            }
            ctx.strokePath()
            ctx.setStrokeColor(lineColor)
            ctx.setLineWidth(0.5)

        case .taskList:
            // Checkbox + ruled line per row.
            let rowHeightTL: CGFloat = mm(10)
            let checkSize:   CGFloat = 12
            let leftPad:     CGFloat = 20
            var ty = rowHeightTL
            while ty < bounds.height {
                let box = CGRect(
                    x: leftPad,
                    y: ty - checkSize / 2,
                    width: checkSize, height: checkSize
                )
                let path = CGPath(roundedRect: box, cornerWidth: 1, cornerHeight: 1,
                                  transform: nil)
                ctx.addPath(path)
                ctx.strokePath()

                ctx.setStrokeColor(UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.20).cgColor)
                ctx.setLineWidth(0.3)
                ctx.move(to:    CGPoint(x: leftPad + checkSize + 4, y: ty + checkSize / 2))
                ctx.addLine(to: CGPoint(x: bounds.width - leftPad,  y: ty + checkSize / 2))
                ctx.strokePath()
                ctx.setStrokeColor(lineColor)
                ctx.setLineWidth(0.5)

                ty += rowHeightTL
            }

        case .habitTracker:
            // Task column on the left + 30 daily checkbox cells per
            // row. Row height = cell width so cells are square.
            let leftColW = bounds.width * 0.3
            let cellSize = (bounds.width - leftColW) / 30
            let rowsHT   = max(8, Int(bounds.height / cellSize))

            ctx.move(to:    CGPoint(x: leftColW, y: 0))
            ctx.addLine(to: CGPoint(x: leftColW, y: bounds.height))
            ctx.strokePath()

            ctx.setStrokeColor(UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.20).cgColor)
            ctx.setLineWidth(0.2)
            for row in 0..<rowsHT {
                let y = CGFloat(row) * cellSize
                ctx.move(to:    CGPoint(x: 0,            y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
                for col in 0...30 {
                    let x = leftColW + CGFloat(col) * cellSize
                    ctx.move(to:    CGPoint(x: x, y: y))
                    ctx.addLine(to: CGPoint(x: x, y: y + cellSize))
                }
            }
            ctx.strokePath()
            ctx.setStrokeColor(lineColor)
            ctx.setLineWidth(0.5)
        }
    }

    // MARK: - Media attachments

    /// Image bytes for export: in-row `imageData` first (canonical,
    /// CloudKit-synced — a notebook received via `.ceciliabook` or
    /// CloudKit may have no local file cache yet), disk fallback,
    /// crop applied to match the editor. Mirrors the 2026-07-16
    /// `PDFDerivedExport.attachImages` fix — the main export path
    /// had the identical disk-only + uncropped gaps.
    private func exportImage(for content: ImageContent) -> UIImage? {
        let bytes = content.imageData ?? (try? Data(contentsOf: content.fileURL))
        guard let bytes, let raw = UIImage(data: bytes) else { return nil }
        return ImageDataView.applyCrop(
            to: raw,
            x: content.cropOriginX, y: content.cropOriginY,
            w: content.cropWidth, h: content.cropHeight
        )
    }

    private func drawMediaAttachments(_ page: Page, ctx: CGContext, bounds: CGRect, notebook: Notebook) {
        // Step 4: read V6 `PageElement(kind: .image)` rows in place
        // of the retired `MediaAttachmentStore`. Geometry is the
        // same; rotation is already in radians on `PageElement`
        // (vs the legacy degrees), so the `* .pi / 180` factor is
        // dropped. `rotate(by:)` is counter-clockwise in PDF
        // context, so negate to match the on-screen direction.
        let elements = fetchImageElements(forPageId: page.id)
        for element in elements {
            guard let content = element.imageContent,
                  let image = exportImage(for: content) else { continue }

            let rect = CGRect(
                x:      element.normalizedX      * bounds.width,
                y:      element.normalizedY      * bounds.height,
                width:  element.normalizedWidth  * bounds.width,
                height: element.normalizedHeight * bounds.height
            )
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: -CGFloat(element.rotation))
            ctx.translateBy(x: -rect.width / 2, y: -rect.height / 2)
            image.draw(in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }
    }

    // MARK: - PencilKit strokes (rasterised)

    private func drawStrokes(_ page: Page, ctx: CGContext, bounds: CGRect, quality: ExportQuality) {
        // Step 8: read via the V6 stroke singleton instead of the
        // retired `Page.strokeData` field.
        guard let data    = StorageService.shared.strokeData(for: page),
              let drawing = try? PKDrawing(data: data)
        else { return }

        let scale = quality.scale
        let image = drawing.image(from: bounds, scale: scale)
        image.draw(in: bounds)
    }

    // MARK: - Text blocks (searchable PDF text)

    private func drawTextBlocks(_ page: Page, ctx: CGContext, bounds: CGRect) {
        let blocks = (page.textBlocks ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.zIndex < $1.zIndex }

        for block in blocks {
            guard let data = block.richTextData,
                  let attrStr = try? NSAttributedString(
                      data: data,
                      options: [.documentType: NSAttributedString.DocumentType.rtfd],
                      documentAttributes: nil
                  )
            else { continue }

            let blockW = CGFloat(block.width)  * bounds.width
            let blockH = CGFloat(block.height) * bounds.height
            // PDF Y-axis is bottom-left origin; flip: pdfY = pageH - normY*pageH - blockH
            let pdfX   = CGFloat(block.x) * bounds.width
            let pdfY   = bounds.height - CGFloat(block.y) * bounds.height - blockH
            let rect   = CGRect(x: pdfX, y: pdfY, width: blockW, height: blockH)

            ctx.saveGState()
            // Rotate around block centre
            if block.rotation != 0 {
                let cx = rect.midX, cy = rect.midY
                ctx.translateBy(x: cx, y: cy)
                ctx.rotate(by: -CGFloat(block.rotation))   // PDF rotation is inverted vs UIKit
                ctx.translateBy(x: -blockW/2, y: -blockH/2)
                attrStr.draw(with: CGRect(origin: .zero, size: rect.size),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             context: nil)
            } else {
                attrStr.draw(with: rect,
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             context: nil)
            }
            ctx.restoreGState()
        }
    }

    // MARK: - V6 PageElement renderers
    //
    // The original `drawTextBlocks` / `drawMediaAttachments` only
    // covered the legacy V5 surfaces. V6 added typed text via
    // `PageElement(.text)` + `TextContent`, sticky notes via
    // `PageElement(.stickyNote)` + `StickyNoteContent`, shapes
    // via `PageElement(.shape)` + `ShapeContent`, and highlights
    // via `PageElement(.highlight)`. The pre-fix export only saw
    // strokes + images + V5 text blocks; everything the user
    // added through the V6 surfaces silently dropped out of the
    // exported PDF. These helpers walk the missing kinds.

    private func fetchPageElements(forPageId pageId: UUID, kind: ElementKind) -> [PageElement] {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pageId && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.zIndex), SortDescriptor(\.createdAt)]
        )
        let all = (try? StorageService.shared.context.fetch(descriptor)) ?? []
        return all.filter { $0.kind == kind }
    }

    private func drawV6TextElements(_ page: Page, ctx: CGContext, bounds: CGRect) {
        let elements = fetchPageElements(forPageId: page.id, kind: .text)
        for element in elements {
            guard let content = element.textContent else { continue }
            let attrStr: NSAttributedString
            if let data = content.attributedTextData,
               let decoded = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.rtfd],
                   documentAttributes: nil
               ) {
                attrStr = decoded
            } else {
                let font: UIFont
                switch content.size {
                case .heading: font = .systemFont(ofSize: 22, weight: .semibold)
                case .small:   font = .systemFont(ofSize: 12, weight: .regular)
                case .body:    font = .systemFont(ofSize: 16, weight: .regular)
                }
                attrStr = NSAttributedString(
                    string: content.text,
                    attributes: [
                        .font: font,
                        .foregroundColor: UIColor.label
                    ]
                )
            }
            let rect = CGRect(
                x:      element.normalizedX      * bounds.width,
                y:      element.normalizedY      * bounds.height,
                width:  element.normalizedWidth  * bounds.width,
                height: element.normalizedHeight * bounds.height
            )
            ctx.saveGState()
            if element.rotation != 0 {
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: -CGFloat(element.rotation))
                ctx.translateBy(x: -rect.width / 2, y: -rect.height / 2)
                attrStr.draw(with: CGRect(origin: .zero, size: rect.size),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             context: nil)
            } else {
                attrStr.draw(with: rect,
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             context: nil)
            }
            ctx.restoreGState()
        }
    }

    private func drawV6StickyNotes(_ page: Page, ctx: CGContext, bounds: CGRect) {
        let elements = fetchPageElements(forPageId: page.id, kind: .stickyNote)
        for element in elements {
            guard let content = element.stickyNoteContent else { continue }
            let rect = CGRect(
                x:      element.normalizedX      * bounds.width,
                y:      element.normalizedY      * bounds.height,
                width:  element.normalizedWidth  * bounds.width,
                height: element.normalizedHeight * bounds.height
            )
            let cardColor = uiColor(forStickyVariant: content.colorVariant)
            ctx.saveGState()
            if element.rotation != 0 {
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: -CGFloat(element.rotation))
                ctx.translateBy(x: -rect.width / 2, y: -rect.height / 2)
            } else {
                ctx.translateBy(x: rect.minX, y: rect.minY)
            }
            let cardRect = CGRect(origin: .zero, size: rect.size)
            ctx.setFillColor(cardColor.cgColor)
            ctx.fill(cardRect)
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
            ]
            let inset = cardRect.insetBy(dx: 8, dy: 8)
            (content.text as NSString).draw(
                with: inset,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: bodyAttrs,
                context: nil
            )
            ctx.restoreGState()
        }
    }

    private func drawV6Shapes(_ page: Page, ctx: CGContext, bounds: CGRect) {
        let elements = fetchPageElements(forPageId: page.id, kind: .shape)
        for element in elements {
            guard let content = element.shapeContent else { continue }
            let rect = CGRect(
                x:      element.normalizedX      * bounds.width,
                y:      element.normalizedY      * bounds.height,
                width:  element.normalizedWidth  * bounds.width,
                height: element.normalizedHeight * bounds.height
            )
            ctx.saveGState()
            if element.rotation != 0 {
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: -CGFloat(element.rotation))
                ctx.translateBy(x: -rect.width / 2, y: -rect.height / 2)
            } else {
                ctx.translateBy(x: rect.minX, y: rect.minY)
            }
            let shapeRect = CGRect(origin: .zero, size: rect.size)
            let stroke = UIColor(hex: content.strokeColorHex)
            let fill = content.fillColorHex.map(UIColor.init(hex:))
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(CGFloat(content.strokeWidth))
            if let fill {
                ctx.setFillColor(fill.cgColor)
            }
            switch content.shapeKind {
            case .rectangle:
                if fill != nil { ctx.fill(shapeRect) }
                ctx.stroke(shapeRect)
            case .roundedRectangle:
                let path = CGPath(roundedRect: shapeRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
                ctx.addPath(path)
                if fill != nil { ctx.fillPath() }
                ctx.addPath(path)
                ctx.strokePath()
            case .ellipse:
                if fill != nil { ctx.fillEllipse(in: shapeRect) }
                ctx.strokeEllipse(in: shapeRect)
            case .triangle:
                ctx.move(to: CGPoint(x: shapeRect.midX, y: 0))
                ctx.addLine(to: CGPoint(x: 0, y: shapeRect.height))
                ctx.addLine(to: CGPoint(x: shapeRect.width, y: shapeRect.height))
                ctx.closePath()
                if fill != nil { ctx.fillPath() }
                ctx.move(to: CGPoint(x: shapeRect.midX, y: 0))
                ctx.addLine(to: CGPoint(x: 0, y: shapeRect.height))
                ctx.addLine(to: CGPoint(x: shapeRect.width, y: shapeRect.height))
                ctx.closePath()
                ctx.strokePath()
            case .line, .arrow:
                ctx.move(to: CGPoint(x: 0, y: shapeRect.height / 2))
                ctx.addLine(to: CGPoint(x: shapeRect.width, y: shapeRect.height / 2))
                ctx.strokePath()
            case .star, .heart, .callout:
                // Decorative shapes use parametric SwiftUI paths
                // on screen; the export draws a bounding ellipse
                // as a reasonable approximation rather than
                // re-implementing each parametric path here.
                if fill != nil { ctx.fillEllipse(in: shapeRect) }
                ctx.strokeEllipse(in: shapeRect)
            }
            ctx.restoreGState()
        }
    }

    private func drawV6Highlights(_ page: Page, ctx: CGContext, bounds: CGRect) {
        let elements = fetchPageElements(forPageId: page.id, kind: .highlight)
        for element in elements {
            guard let content = element.highlightContent else { continue }
            let rect = CGRect(
                x:      CGFloat(content.rectOriginX) * bounds.width,
                y:      CGFloat(content.rectOriginY) * bounds.height,
                width:  CGFloat(content.rectWidth)   * bounds.width,
                height: CGFloat(content.rectHeight)  * bounds.height
            )
            ctx.saveGState()
            switch content.style {
            case .highlight:
                let colour = uiColor(forHighlightVariant: content.colorVariant)
                ctx.setFillColor(colour.cgColor)
                ctx.fill(rect)
            case .underline:
                ctx.setStrokeColor(UIColor.label.cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                ctx.strokePath()
            case .strikethrough:
                ctx.setStrokeColor(UIColor.label.cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: rect.minX, y: rect.midY))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    /// Same yellow-pink-blue-green palette used by the PDF
    /// annotation pipeline, kept here so the rasterise path
    /// doesn't have to depend on the highlight subsystem.
    private func uiColor(forHighlightVariant key: String) -> UIColor {
        switch key {
        case "pink":  return UIColor(red: 1.00, green: 0.70, blue: 0.85, alpha: 0.4)
        case "blue":  return UIColor(red: 0.70, green: 0.85, blue: 1.00, alpha: 0.4)
        case "green": return UIColor(red: 0.75, green: 0.95, blue: 0.70, alpha: 0.4)
        default:      return UIColor(red: 1.00, green: 0.95, blue: 0.40, alpha: 0.4)
        }
    }

    // MARK: - Audio markers

    private func drawAudioMarkers(_ page: Page, ctx: CGContext, bounds: CGRect) {
        // Step 5: read V6 `PageElement(.audio)` rows. Geometry is
        // the strip's normalised rect (audio elements are 50pt
        // tall strips, not pins). Renders a small waveform icon at
        // the top-left of each strip rect + transcript footnote.
        let elements = StorageService.shared.fetchAudioElements(forPageId: page.id)
        guard !elements.isEmpty else { return }

        for element in elements {
            let stripX = CGFloat(element.normalizedX) * bounds.width
            let stripY = CGFloat(element.normalizedY) * bounds.height
            let pinSize: CGFloat = 16

            let config = UIImage.SymbolConfiguration(pointSize: pinSize, weight: .medium)
            if let mic = UIImage(systemName: "waveform", withConfiguration: config)?
                .withTintColor(UIColor(ThemeManager.shared.current.accent), renderingMode: .alwaysOriginal) {
                mic.draw(at: CGPoint(x: stripX, y: stripY))
            }

            let transcript = element.audioContent?.transcript ?? ""
            guard !transcript.isEmpty else { continue }

            let footnoteY = stripY + pinSize + 4
            let ruleRect  = CGRect(x: 0, y: footnoteY, width: bounds.width, height: 0.5)
            ctx.setFillColor(UIColor(ThemeManager.shared.current.foregroundSubtle).withAlphaComponent(0.3).cgColor)
            ctx.fill(ruleRect)

            let attrs: [NSAttributedString.Key: Any] = [
                .font:            UIFont.ceciliasNotesCaption,
                .foregroundColor: UIColor(ThemeManager.shared.current.foregroundMuted),
            ]
            let textRect = CGRect(x: 8, y: footnoteY + 4, width: bounds.width - 16, height: 60)
            (transcript as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }

    // MARK: - Page number

    private func drawPageNumber(_ label: String, ctx: CGContext, bounds: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.ceciliasNotesCaption,
            .foregroundColor: UIColor(ThemeManager.shared.current.foregroundMuted),
        ]
        let size   = (label as NSString).size(withAttributes: attrs)
        let x      = (bounds.width - size.width) / 2
        let y      = bounds.height - 16 - size.height
        (label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    // MARK: - Cover page

    private func drawCoverPage(ctx: CGContext, notebook: Notebook, bounds: CGRect) {
        // Background fill
        let bgColor = UIColor(hex: notebook.coverColorHex)
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(bounds)

        // Cover texture — white strokes at 8% opacity (same as CoverTextureCanvas)
        drawCoverTexture(ctx: ctx, bounds: bounds)

        let cx = bounds.midX

        // Notebook title — .ceciliasNotesDisplay (34pt light)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.ceciliasNotesDisplay,
            .foregroundColor: UIColor.white,
        ]
        let titleStr  = notebook.title as NSString
        let titleSize = titleStr.size(withAttributes: titleAttrs)
        titleStr.draw(
            at: CGPoint(x: cx - titleSize.width / 2, y: bounds.midY - titleSize.height / 2 - 20),
            withAttributes: titleAttrs
        )

        // Export date — .ceciliasNotesFootnote (13pt) text.tertiary
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.ceciliasNotesFootnote,
            .foregroundColor: UIColor.white.withAlphaComponent(0.55),
        ]
        let dateStr  = Self.coverDateString() as NSString
        let dateSize = dateStr.size(withAttributes: dateAttrs)
        dateStr.draw(
            at: CGPoint(x: cx - dateSize.width / 2, y: bounds.midY - dateSize.height / 2 + 14),
            withAttributes: dateAttrs
        )

        // "Cecilia's Notes" wordmark — bottom-right, .ceciliasNotesCaption (12pt)
        let markAttrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.ceciliasNotesCaption,
            .foregroundColor: UIColor.white.withAlphaComponent(0.40),
        ]
        let markStr  = "Cecilia's Notes" as NSString
        let markSize = markStr.size(withAttributes: markAttrs)
        markStr.draw(
            at: CGPoint(x: bounds.maxX - markSize.width - 16, y: bounds.maxY - markSize.height - 16),
            withAttributes: markAttrs
        )
    }

    private func drawCoverTexture(ctx: CGContext, bounds: CGRect) {
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(1)
        // Diagonal hatching matching CoverTextureCanvas
        let step: CGFloat = 24
        var x: CGFloat = -bounds.height
        while x < bounds.width + bounds.height {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x + bounds.height, y: bounds.height))
            x += step
        }
        ctx.strokePath()
    }

    private static func coverDateString() -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: Date())
    }
}

// MARK: - Helpers

private extension CGSize {
    var asCGRect: CGRect { CGRect(origin: .zero, size: self) }
}

// MARK: - ExportError

// MARK: - StrokeStampAnnotation

/// `PDFAnnotation` subclass used for the annotated-PDF export path.
/// Carries a rasterised PKDrawing image that's painted into the page
/// at the annotation's bounds — readable by any PDF reader because
/// the annotation's appearance is materialised at draw time, not
/// embedded as a PDF-specific feature.
private final class StrokeStampAnnotation: PDFAnnotation {
    private let strokeImage: UIImage

    nonisolated init(bounds: CGRect, image: UIImage) {
        self.strokeImage = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    nonisolated override init(bounds: CGRect, forType annotationType: PDFAnnotationSubtype, withProperties properties: [AnyHashable: Any]?) {
        fatalError("StrokeStampAnnotation requires init(bounds:image:)")
    }

    nonisolated required init?(coder: NSCoder) {
        fatalError("StrokeStampAnnotation does not support coder")
    }

    nonisolated override func draw(with box: PDFDisplayBox, in context: CGContext) {
        super.draw(with: box, in: context)
        UIGraphicsPushContext(context)
        // `bounds` is in PDF page coordinates; the stamp annotation
        // already places us at that origin so we draw at .zero.
        strokeImage.draw(in: CGRect(origin: .zero, size: self.bounds.size))
        UIGraphicsPopContext()
    }
}

enum ExportError: Error, LocalizedError {
    case noPages
    case writeFailed(Error)
    case pdfNotFound
    case pdfWriteFailed

    var errorDescription: String? {
        switch self {
        case .noPages:            return "No pages to export."
        case .writeFailed(let e): return "Export failed: \(e.localizedDescription)"
        case .pdfNotFound:        return "Couldn't find the source PDF for this notebook."
        case .pdfWriteFailed:     return "Couldn't write the annotated PDF."
        }
    }
}

