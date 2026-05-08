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
        var base    = "\(safeTitle)_\(dateStr)"
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
            kCGPDFContextAuthor as String: "Ink",
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

        switch template {
        case .blank:
            break

        case .lined(let spacing):
            var y = spacing
            while y < bounds.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
                y += spacing
            }
            ctx.strokePath()

        case .grid(let spacing):
            var y = spacing
            while y < bounds.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: bounds.width, y: y)); y += spacing }
            var x = spacing
            while x < bounds.width  { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: bounds.height)); x += spacing }
            ctx.strokePath()

        case .dotGrid(let spacing, let dotSize):
            ctx.setFillColor(UIColor.inkTextTertiary.withAlphaComponent(0.30).cgColor)
            let r = max(0.5, dotSize)
            var y = spacing
            while y < bounds.height {
                var x = spacing
                while x < bounds.width {
                    ctx.fillEllipse(in: CGRect(x: x - r/2, y: y - r/2, width: r, height: r))
                    x += spacing
                }
                y += spacing
            }

        case .cornell:
            let marginX = bounds.width  * 0.20
            let titleY  = bounds.height * 0.15
            ctx.move(to: CGPoint(x: marginX, y: 0)); ctx.addLine(to: CGPoint(x: marginX, y: bounds.height))
            ctx.move(to: CGPoint(x: 0, y: titleY)); ctx.addLine(to: CGPoint(x: bounds.width, y: titleY))
            ctx.strokePath()

        case .music:
            let staffSpacing: CGFloat = 8
            let groupSpacing: CGFloat = 30
            var y: CGFloat = 20
            while y + staffSpacing * 4 < bounds.height {
                for line in 0..<5 {
                    let ly = y + CGFloat(line) * staffSpacing
                    ctx.move(to: CGPoint(x: 16, y: ly)); ctx.addLine(to: CGPoint(x: bounds.width - 16, y: ly))
                }
                ctx.strokePath()
                y += staffSpacing * 4 + groupSpacing
            }
        }
    }

    // MARK: - Media attachments

    private func drawMediaAttachments(_ page: Page, ctx: CGContext, bounds: CGRect, notebook: Notebook) {
        let attachments = page.mediaAttachments
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
        let blocks = page.textBlocks
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
        let annotations = page.audioAnnotations.filter { !$0.isDeleted }
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

        // "Ink" wordmark — bottom-right, .inkCaption (12pt)
        let markAttrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.inkCaption,
            .foregroundColor: UIColor.white.withAlphaComponent(0.40),
        ]
        let markStr  = "Ink" as NSString
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

enum ExportError: Error, LocalizedError {
    case noPages
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noPages:           return "No pages to export."
        case .writeFailed(let e): return "Export failed: \(e.localizedDescription)"
        }
    }
}

