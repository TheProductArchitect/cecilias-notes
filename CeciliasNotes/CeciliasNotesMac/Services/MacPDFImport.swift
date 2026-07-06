import AppKit
import PDFKit
import SwiftData

/// Mac-native PDF page import — one PDF page per notebook page.
@MainActor
enum MacPDFImport {

    @discardableResult
    static func importAsNotebook(
        from sourceURL: URL,
        subjectId: UUID?,
        storage: StorageService
    ) async -> UUID? {
        let result = await importFromURL(sourceURL, subjectId: subjectId, storage: storage, intoExisting: nil, afterPageNumber: nil)
        return result.notebookId
    }

    static func importFromDrop(
        url: URL,
        subjectId: UUID?,
        storage: StorageService
    ) async -> (notebookId: UUID?, pagesImported: Int) {
        await importFromURL(url, subjectId: subjectId, storage: storage, intoExisting: nil, afterPageNumber: nil)
    }

    private static func importFromURL(
        _ sourceURL: URL,
        subjectId: UUID?,
        storage: StorageService,
        intoExisting notebook: Notebook?,
        afterPageNumber: Int?
    ) async -> (notebookId: UUID?, pagesImported: Int) {
        guard let data = try? Data(contentsOf: sourceURL) else { return (nil, 0) }
        let title = notebook?.title ?? uniqueTitle(from: sourceURL, storage: storage)
        return await importDocument(
            data: data,
            title: title,
            subjectId: subjectId,
            storage: storage,
            intoExisting: notebook,
            afterPageNumber: afterPageNumber
        )
    }

    @discardableResult
    static func importIntoNotebook(
        from sourceURL: URL,
        notebook: Notebook,
        after page: Page?,
        storage: StorageService
    ) async -> Int {
        let result = await importFromURL(
            sourceURL,
            subjectId: nil,
            storage: storage,
            intoExisting: notebook,
            afterPageNumber: page?.pageNumber
        )
        return result.pagesImported
    }

    @discardableResult
    private static func importDocument(
        data: Data,
        title: String,
        subjectId: UUID?,
        storage: StorageService,
        intoExisting notebook: Notebook?,
        afterPageNumber: Int?
    ) async -> (notebookId: UUID?, pagesImported: Int) {
        let hash = MediaStorage.sha256Hex(of: data)
        let pdfDocumentId = MediaStorage.writePDF(from: data, hash: hash)
        guard let document = PDFDocument(url: MediaStorage.url(forPDF: pdfDocumentId)) else { return (nil, 0) }
        let indices = Array(0..<document.pageCount)
        guard !indices.isEmpty else { return (nil, 0) }

        let payloads: [Payload] = await Task.detached(priority: .userInitiated) {
            indices.compactMap { index -> Payload? in
                guard let page = document.page(at: index) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                let contentId = UUID()
                let previewName = renderPreview(for: page, bounds: bounds, contentId: contentId)
                return Payload(
                    pageIndex: index,
                    previewFilename: previewName,
                    originalSize: bounds.size,
                    extractedText: page.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }.value

        let context = storage.context
        let target: Notebook
        if let notebook {
            target = notebook
        } else {
            guard let created = try? storage.createNotebook(
                title: title,
                subjectId: subjectId,
                coverColorHex: "#FAFAF8",
                coverTexture: .none,
                pageSize: .a4,
                template: .blank
            ) else { return (nil, 0) }
            removeSeededBlankPage(from: created, context: context)
            target = created
        }

        var anchor = afterPageNumber ?? {
            let nums = storage.fetchPages(in: target).map(\.pageNumber)
            return nums.max() ?? 0
        }()

        let pageSize = target.pageSize.pointSize

        for payload in payloads {
            guard let newPage = try? storage.createPage(
                in: target,
                after: anchor,
                pageSize: target.pageSize,
                backgroundTemplate: target.defaultTemplate
            ) else { continue }
            anchor = newPage.pageNumber

            if let text = payload.extractedText, !text.isEmpty {
                insertEditableText(text, on: newPage, notebook: target, pageSize: pageSize, context: context)
            } else {
                insertPDFImageElement(
                    payload: payload,
                    pdfDocumentId: pdfDocumentId,
                    page: newPage,
                    notebook: target,
                    pageSize: pageSize,
                    context: context
                )
            }
        }

        target.updatedAt = Date()
        try? context.save()
        NotificationCenter.default.post(name: Notification.Name("pdfPageElementsChanged"), object: nil)
        NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        return (target.id, payloads.count)
    }

    /// When PDFKit can read a text layer, import as an editable text block.
    private static func insertEditableText(
        _ text: String,
        on page: Page,
        notebook: Notebook,
        pageSize: CGSize,
        context: ModelContext
    ) {
        let marginX = MacDocPageLayout.normalizedHorizontalMargin(pageWidth: pageSize.width)
        let contentWidth = MacDocPageLayout.normalizedContentWidth(pageWidth: pageSize.width)
        let topY = MacDocPageLayout.normalizedTopMargin(pageHeight: pageSize.height)
        let attrs = MacRichTextCodec.defaultTypingAttributes(size: .body)
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let columnWidth = max(40, pageSize.width - 2 * MacDocPageLayout.horizontalMargin)
        let measured = ceil(attributed.boundingRect(
            with: CGSize(width: columnWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
        let normH = min(0.92, max(0.08, Double((measured + 12) / pageSize.height)))

        guard let element = TextElementCommit.create(
            text: text,
            source: .typed,
            pageId: page.id,
            notebookId: notebook.id,
            normalizedRect: CGRect(x: marginX, y: topY, width: contentWidth, height: normH),
            context: context
        ) else { return }
        element.textContent?.attributedTextData = MacRichTextCodec.encode(attributed)
        element.updatedAt = Date()
    }

    /// Image-only / scanned PDFs — aspect-fit within page margins.
    private static func insertPDFImageElement(
        payload: Payload,
        pdfDocumentId: UUID,
        page: Page,
        notebook: Notebook,
        pageSize: CGSize,
        context: ModelContext
    ) {
        let fit = normalizedFitRect(pageSize: pageSize, contentSize: payload.originalSize)
        let element = PageElement(
            pageId: page.id,
            notebookId: notebook.id,
            kind: .pdfPage,
            normalizedX: fit.origin.x,
            normalizedY: fit.origin.y,
            normalizedWidth: fit.width,
            normalizedHeight: fit.height,
            zIndex: 0
        )
        element.pdfPageContent = PDFPageContent(
            id: UUID(),
            pdfDocumentId: pdfDocumentId,
            pageIndex: payload.pageIndex,
            originalPageWidth: Double(payload.originalSize.width),
            originalPageHeight: Double(payload.originalSize.height),
            previewImageFilename: payload.previewFilename,
            extractedText: nil
        )
        context.insert(element)
    }

    private struct Payload {
        let pageIndex: Int
        let previewFilename: String?
        let originalSize: CGSize
        let extractedText: String?
    }

    /// Aspect-fit PDF bounds inside horizontal + top margins.
    private static func normalizedFitRect(pageSize: CGSize, contentSize: CGSize) -> CGRect {
        let marginX = MacDocPageLayout.normalizedHorizontalMargin(pageWidth: pageSize.width)
        let topY = MacDocPageLayout.normalizedTopMargin(pageHeight: pageSize.height)
        let contentWidthNorm = MacDocPageLayout.normalizedContentWidth(pageWidth: pageSize.width)
        let contentWidthPts = pageSize.width * contentWidthNorm
        let maxHeightPts = pageSize.height * (1.0 - topY - 0.04)

        guard contentSize.width > 0, contentSize.height > 0 else {
            return CGRect(x: marginX, y: topY, width: contentWidthNorm, height: 0.85)
        }

        var widthPts = contentWidthPts
        var heightPts = widthPts * (contentSize.height / contentSize.width)
        if heightPts > maxHeightPts {
            heightPts = maxHeightPts
            widthPts = heightPts * (contentSize.width / contentSize.height)
        }

        let widthNorm = Double(widthPts / pageSize.width)
        let heightNorm = Double(heightPts / pageSize.height)
        let xNorm = Double((pageSize.width - widthPts) / 2 / pageSize.width)

        return CGRect(x: xNorm, y: topY, width: widthNorm, height: heightNorm)
    }

    nonisolated private static func renderPreview(for page: PDFPage, bounds: CGRect, contentId: UUID) -> String? {
        let scale: CGFloat = 1.5
        let thumbSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let thumbnail = page.thumbnail(of: thumbSize, for: .mediaBox)
        return MediaStorage.writePDFPreview(thumbnail, contentId: contentId)
    }

    private static func uniqueTitle(from url: URL, storage: StorageService) -> String {
        let base = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? "Imported PDF" : base
        let existing = Set(storage.fetchAllNotebooks().map(\.title))
        if !existing.contains(name) { return name }
        let copy = "\(name) Copy"
        if !existing.contains(copy) { return copy }
        var n = 2
        while existing.contains("\(name) Copy \(n)") { n += 1 }
        return "\(name) Copy \(n)"
    }

    private static func removeSeededBlankPage(from notebook: Notebook, context: ModelContext) {
        guard let pages = notebook.pages, pages.count == 1,
              let seed = pages.first,
              (seed.textBlocks ?? []).isEmpty else { return }
        context.delete(seed)
        notebook.pages = []
        notebook.totalPageCount = 0
        try? context.save()
    }
}
