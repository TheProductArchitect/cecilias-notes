import PDFKit
import PencilKit
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
    var pageRange:             PageRange       = .all
    var quality:               ExportQuality   = .standard
    var includeTranscriptions: Bool            = false
    var includePageNumbers:    Bool            = true
    var includeCoverPage:      Bool            = true
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

        // PDF-backed notebooks export through the annotated-PDF path:
        // copy each source PDF page verbatim and add a stamp
        // annotation containing the user's strokes, so Preview / Adobe
        // Reader / Chrome all display the strokes as PDF annotations
        // rather than a re-rasterised page.
        if notebook.isPDFBacked, let sourceURL = notebook.sourcePDFURL {
            return try await exportAnnotatedPDF(
                notebook:   notebook,
                pages:      exportPages,
                sourceURL:  sourceURL,
                options:    options,
                progress:   progress,
                start:      start
            )
        }

        let outputURL  = try makeOutputURL(for: notebook)
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
                drawStrokes(page, ctx: cgCtx, bounds: bounds, quality: options.quality)
                drawTextBlocks(page, ctx: cgCtx, bounds: bounds)

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
    private func exportAnnotatedPDF(
        notebook:  Notebook,
        pages:     [Page],
        sourceURL: URL,
        options:   ExportOptions,
        progress:  @escaping @Sendable (Double) -> Void,
        start:     Date
    ) async throws -> ExportResult {
        guard let sourceDoc = PDFDocument(url: sourceURL) else {
            throw ExportError.pdfNotFound
        }

        let outputDoc = PDFDocument()
        let total     = pages.count

        for (idx, page) in pages.enumerated() {
            if let pdfIndex = page.pdfPageIndex,
               pdfIndex < sourceDoc.pageCount,
               let sourcePage = sourceDoc.page(at: pdfIndex),
               let pageCopy = sourcePage.copy() as? PDFPage {

                let bounds = pageCopy.bounds(for: .mediaBox)
                // Images render below strokes on the canvas, so
                // they get attached *first* in the PDF — the stamp
                // annotations layer in z-order they're added.
                attachMediaImagesAnnotation(
                    pageId:     page.id,
                    pageBounds: bounds,
                    to:         pageCopy
                )
                if let drawingData = page.strokeData,
                   let drawing = try? PKDrawing(data: drawingData),
                   drawing.bounds.width > 0, drawing.bounds.height > 0 {
                    attachStrokesAnnotation(
                        from: drawing,
                        pageBounds: bounds,
                        to: pageCopy
                    )
                }
                attachStickyNotes(
                    pageId:     page.id,
                    pageBounds: bounds,
                    to:         pageCopy
                )
                // Highlight / underline / strikethrough text
                // annotations. The PDF on disk may already carry
                // these (the editor's debounced write-back may have
                // fired), but adding the same record twice is
                // skipped via the `.contents` id check inside
                // `attachTextAnnotations`.
                attachTextAnnotations(
                    pageId: page.id,
                    to:     pageCopy
                )
                outputDoc.insert(pageCopy, at: idx)
            } else {
                // Non-PDF page (e.g. blank page added after import) —
                // render via the standard fresh-page pipeline and
                // splice it into the output document.
                if let freshPage = makeFreshPDFPage(for: page, notebook: notebook, options: options) {
                    attachStickyNotes(
                        pageId:     page.id,
                        pageBounds: freshPage.bounds(for: .mediaBox),
                        to:         freshPage
                    )
                    // Same idempotent attach. Non-PDF pages carry
                    // text annotations only if a fresh page was
                    // somehow marked PDF-backed; usually empty.
                    attachTextAnnotations(
                        pageId: page.id,
                        to:     freshPage
                    )
                    outputDoc.insert(freshPage, at: idx)
                }
            }
            progress(Double(idx + 1) / Double(total))
        }

        let outputURL = try makeOutputURL(for: notebook)
        guard outputDoc.write(to: outputURL) else {
            throw ExportError.pdfWriteFailed
        }

        let attrs    = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let duration = Date().timeIntervalSince(start)

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

    /// Add a `PDFAnnotation.freeText` for each sticky note attached
    /// to the page. PDF freeText annotations show as an in-document
    /// text box at the annotation's bounds in any PDF reader —
    /// Preview, Adobe Reader, Chrome. The 24×24pt marker the editor
    /// uses on-screen becomes a sized text box in the PDF; readers
    /// that surface annotations in a sidebar (Preview, Adobe) will
    /// also list the note's body verbatim.
    private func attachStickyNotes(
        pageId: UUID,
        pageBounds: CGRect,
        to pdfPage: PDFPage
    ) {
        let notes = StickyNoteStore.notes(for: pageId)
        guard !notes.isEmpty else { return }

        let noteWidth: CGFloat  = 140
        let noteHeight: CGFloat = 80

        for note in notes {
            // PDF coordinate space has the origin at the bottom-left.
            // The marker's normalised y is top-anchored, so we flip
            // it to bottom-anchored and offset so the freeText box
            // grows downward-right from the marker tip.
            let x = CGFloat(note.normalizedX) * pageBounds.width
            let yTop = CGFloat(note.normalizedY) * pageBounds.height
            let y = pageBounds.height - yTop - noteHeight
            let bounds = CGRect(
                x: max(0, min(pageBounds.width  - noteWidth,  x)),
                y: max(0, min(pageBounds.height - noteHeight, y)),
                width:  noteWidth,
                height: noteHeight
            )

            let annotation = PDFAnnotation(
                bounds:     bounds,
                forType:    .freeText,
                withProperties: nil
            )
            annotation.contents = note.body
            annotation.font     = UIFont(name: "Helvetica", size: 11)
                ?? .systemFont(ofSize: 11)
            annotation.fontColor       = .black
            annotation.color           = UIColor(
                red: 0.99, green: 0.92, blue: 0.55, alpha: 1.0
            )  // matches the marker fill
            annotation.contents = note.body
            pdfPage.addAnnotation(annotation)
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
        let records = MediaAttachmentStore.records(for: pageId)
        guard !records.isEmpty else { return }

        let scale: CGFloat = 2.0
        let pixelSize = CGSize(
            width:  pageBounds.width  * scale,
            height: pageBounds.height * scale
        )
        UIGraphicsBeginImageContextWithOptions(pixelSize, false, scale)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.scaleBy(x: scale, y: scale)

        for record in records {
            let url = MediaAttachmentStore.absoluteURL(for: record)
            guard let image = UIImage(contentsOfFile: url.path) else { continue }
            let rect = CGRect(
                x:      record.normalizedX      * pageBounds.width,
                y:      record.normalizedY      * pageBounds.height,
                width:  record.normalizedWidth  * pageBounds.width,
                height: record.normalizedHeight * pageBounds.height
            )
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: -CGFloat(record.rotationDegrees) * .pi / 180)
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

    /// Add proper `PDFAnnotation` objects (highlight / underline /
    /// strikethrough) for every active record in
    /// `PDFTextAnnotationStore` for this page. The editor's
    /// debounced writer may have already stamped these into the
    /// source PDF, in which case `pageCopy.copy()` carries them
    /// forward; the `.contents` id check below skips duplicates so
    /// export is idempotent regardless of writer timing.
    ///
    /// Geometry is delegated to `PDFAnnotationWriter.makeAnnotation`
    /// so the editor + export paths share one transform.
    private func attachTextAnnotations(
        pageId: UUID,
        to pdfPage: PDFPage
    ) {
        let records = PDFTextAnnotationStore.records(for: pageId)
        guard !records.isEmpty else { return }

        for record in records {
            let key = record.id.uuidString
            let alreadyPresent = pdfPage.annotations.contains { ann in
                (ann.value(forAnnotationKey: .contents) as? String) == key
            }
            guard !alreadyPresent else { continue }
            guard let annotation = PDFAnnotationWriter.makeAnnotation(
                for: record,
                on: pdfPage
            ) else { continue }
            pdfPage.addAnnotation(annotation)
        }
    }

    /// Build a one-page PDFDocument from the standard fresh-page
    /// rendering pipeline, then extract its sole page. Used for
    /// non-PDF pages spliced into a PDF-backed notebook's export
    /// (e.g. a blank page the user added after import).
    private func makeFreshPDFPage(
        for page: Page,
        notebook: Notebook,
        options: ExportOptions
    ) -> PDFPage? {
        let bounds   = page.pageSize.pointSize.asCGRect
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: makePDFInfo(notebook: notebook))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let cgCtx = ctx.cgContext
            drawTemplate(page.backgroundTemplate, ctx: cgCtx, bounds: bounds)
            drawMediaAttachments(page, ctx: cgCtx, bounds: bounds, notebook: notebook)
            drawStrokes(page, ctx: cgCtx, bounds: bounds, quality: options.quality)
            drawTextBlocks(page, ctx: cgCtx, bounds: bounds)
        }
        return PDFDocument(data: data)?.page(at: 0)
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
            drawStrokes(page, ctx: cgCtx, bounds: bounds, quality: options.quality)
            drawTextBlocks(page, ctx: cgCtx, bounds: bounds)
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

    static var globalExportsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ink")
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

        let lineColor = UIColor.inkTextTertiary.withAlphaComponent(0.25).cgColor
        ctx.setStrokeColor(lineColor)
        ctx.setLineWidth(0.5)

        // 1mm ≈ 2.83pt at 96dpi — matches the SwiftUI `TemplatePatternView`'s
        // full-page geometry so the PDF and the editor canvas line up.
        let mm: (CGFloat) -> CGFloat = { $0 * 2.83 }

        let drawHLines: (CGFloat) -> Void = { spacing in
            var y = spacing
            while y < bounds.height {
                ctx.move(to:    CGPoint(x: 16,                y: y))
                ctx.addLine(to: CGPoint(x: bounds.width - 16, y: y))
                y += spacing
            }
            ctx.strokePath()
        }
        let drawSquareGrid: (CGFloat) -> Void = { spacing in
            var y = spacing
            while y < bounds.height {
                ctx.move(to:    CGPoint(x: 0,            y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
                y += spacing
            }
            var x = spacing
            while x < bounds.width {
                ctx.move(to:    CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
                x += spacing
            }
            ctx.strokePath()
        }
        let drawDotGrid: (CGFloat) -> Void = { spacing in
            ctx.setFillColor(UIColor.inkTextTertiary.withAlphaComponent(0.30).cgColor)
            let r: CGFloat = 1.5
            var y = spacing
            while y < bounds.height {
                var x = spacing
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
            ctx.setStrokeColor(UIColor.inkTextTertiary.withAlphaComponent(0.10).cgColor)
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
            ctx.setFillColor(UIColor.inkTextTertiary.withAlphaComponent(0.30).cgColor)
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
            ctx.setStrokeColor(UIColor.inkTextTertiary.withAlphaComponent(0.40).cgColor)
            ctx.strokeEllipse(in: circleRect)

            ctx.setStrokeColor(UIColor.inkTextTertiary.withAlphaComponent(0.20).cgColor)
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
            ctx.setStrokeColor(UIColor.inkTextTertiary.withAlphaComponent(0.20).cgColor)
            ctx.setLineWidth(0.3)
            for i in 0...cols {
                let x = timeColW + CGFloat(i) * colWidth
                ctx.move(to:    CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            }
            ctx.strokePath()

            // Hourly row dividers (lighter still).
            ctx.setStrokeColor(UIColor.inkTextTertiary.withAlphaComponent(0.15).cgColor)
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

            ctx.setStrokeColor(UIColor.inkTextTertiary.withAlphaComponent(0.20).cgColor)
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

                ctx.setStrokeColor(UIColor.inkTextTertiary.withAlphaComponent(0.20).cgColor)
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

            ctx.setStrokeColor(UIColor.inkTextTertiary.withAlphaComponent(0.20).cgColor)
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

    private func drawMediaAttachments(_ page: Page, ctx: CGContext, bounds: CGRect, notebook: Notebook) {
        // Legacy SwiftData-backed attachments (the @Model is kept
        // for CloudKit-compatibility but is not the runtime source
        // of truth any more). Walked first so the side-channel
        // attachments end up on top in z-order — matches "newest
        // wins" since new attachments only go through the
        // side-channel path.
        let attachments = (page.mediaAttachments ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.zIndex < $1.zIndex }

        for att in attachments {
            let fileURL = StorageService.notebooksDirectoryURL
                .appendingPathComponent(notebook.id.uuidString)
                .appendingPathComponent("media")
                .appendingPathComponent(att.fileName)
            guard let image = UIImage(contentsOfFile: fileURL.path) else { continue }

            let rect = CGRect(
                x:      att.x * bounds.width,
                y:      att.y * bounds.height,
                width:  att.width  * bounds.width,
                height: att.height * bounds.height
            )
            let cx = rect.midX, cy = rect.midY

            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: CGFloat(att.rotation))
            ctx.translateBy(x: -rect.width / 2, y: -rect.height / 2)
            ctx.setAlpha(att.opacity)
            image.draw(in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }

        // Side-channel image attachments — the runtime source of
        // truth. Drawn after the legacy path so they layer on top.
        // Geometry is normalised against `bounds`; rotation is
        // applied around the rect's centre, same as the legacy
        // path above.
        let records = MediaAttachmentStore.records(for: page.id)
        for record in records {
            let url = MediaAttachmentStore.absoluteURL(for: record)
            guard let image = UIImage(contentsOfFile: url.path) else { continue }

            let rect = CGRect(
                x:      record.normalizedX      * bounds.width,
                y:      record.normalizedY      * bounds.height,
                width:  record.normalizedWidth  * bounds.width,
                height: record.normalizedHeight * bounds.height
            )
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            // Convert 90° steps to radians. `rotate(by:)` is
            // counter-clockwise in PDF context, so negate to match
            // the on-screen rotation direction.
            ctx.rotate(by: -CGFloat(record.rotationDegrees) * .pi / 180)
            ctx.translateBy(x: -rect.width / 2, y: -rect.height / 2)
            image.draw(in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }
    }

    // MARK: - PencilKit strokes (rasterised)

    private func drawStrokes(_ page: Page, ctx: CGContext, bounds: CGRect, quality: ExportQuality) {
        guard let data    = page.strokeData,
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

    // MARK: - Audio markers

    private func drawAudioMarkers(_ page: Page, ctx: CGContext, bounds: CGRect) {
        let annotations = (page.audioAnnotations ?? []).filter { !$0.isDeleted }
        guard !annotations.isEmpty else { return }

        for ann in annotations {
            let pinX = CGFloat(ann.pageX) * bounds.width
            let pinY = CGFloat(ann.pageY) * bounds.height
            let pinSize: CGFloat = 16

            // Microphone symbol (filled circle + mic icon rendered as UIImage)
            let config = UIImage.SymbolConfiguration(pointSize: pinSize, weight: .medium)
            if let mic = UIImage(systemName: "waveform", withConfiguration: config)?
                .withTintColor(.inkAccentPrimary, renderingMode: .alwaysOriginal) {
                mic.draw(at: CGPoint(x: pinX - pinSize / 2, y: pinY - pinSize / 2))
            }

            // Transcription footnote
            guard let transcript = ann.transcription, !transcript.isEmpty else { continue }

            let footnoteY = pinY + pinSize + 4
            let ruleRect  = CGRect(x: 0, y: footnoteY, width: bounds.width, height: 0.5)
            ctx.setFillColor(UIColor.inkTextTertiary.withAlphaComponent(0.3).cgColor)
            ctx.fill(ruleRect)

            let attrs: [NSAttributedString.Key: Any] = [
                .font:            UIFont.inkCaption,
                .foregroundColor: UIColor.inkTextSecondary,
            ]
            let textRect = CGRect(x: 8, y: footnoteY + 4, width: bounds.width - 16, height: 60)
            (transcript as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }

    // MARK: - Page number

    private func drawPageNumber(_ label: String, ctx: CGContext, bounds: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.inkCaption,
            .foregroundColor: UIColor.inkTextSecondary,
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

        // Notebook title — .inkDisplay (34pt light)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.inkDisplay,
            .foregroundColor: UIColor.white,
        ]
        let titleStr  = notebook.title as NSString
        let titleSize = titleStr.size(withAttributes: titleAttrs)
        titleStr.draw(
            at: CGPoint(x: cx - titleSize.width / 2, y: bounds.midY - titleSize.height / 2 - 20),
            withAttributes: titleAttrs
        )

        // Export date — .inkFootnote (13pt) text.tertiary
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.inkFootnote,
            .foregroundColor: UIColor.white.withAlphaComponent(0.55),
        ]
        let dateStr  = Self.coverDateString() as NSString
        let dateSize = dateStr.size(withAttributes: dateAttrs)
        dateStr.draw(
            at: CGPoint(x: cx - dateSize.width / 2, y: bounds.midY - dateSize.height / 2 + 14),
            withAttributes: dateAttrs
        )

        // "Cecilia's Notes" wordmark — bottom-right, .inkCaption (12pt)
        let markAttrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.inkCaption,
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

    init(bounds: CGRect, image: UIImage) {
        self.strokeImage = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("StrokeStampAnnotation does not support coder")
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
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

