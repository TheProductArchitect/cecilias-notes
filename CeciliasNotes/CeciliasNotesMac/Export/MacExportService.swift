import PDFKit
import PencilKit
import SwiftData
import SwiftUI
import AppKit

enum MacExportFormat: String, CaseIterable {
    case pdf
    case images
    case markdown

    var label: String {
        switch self {
        case .pdf:       return "PDF"
        case .images:    return "Images (PNG)"
        case .markdown:  return "Markdown bundle"
        }
    }
}

@MainActor
enum MacExportService {
    static func export(
        notebook: Notebook,
        pages: [Page],
        format: MacExportFormat,
        storage: StorageService
    ) async throws -> URL {
        switch format {
        case .pdf:      return try await exportPDF(notebook: notebook, pages: pages, storage: storage)
        case .images:   return try await exportImages(notebook: notebook, pages: pages, storage: storage)
        case .markdown: return try exportMarkdown(notebook: notebook, pages: pages, storage: storage)
        }
    }

    private static func exportPDF(
        notebook: Notebook,
        pages: [Page],
        storage: StorageService
    ) async throws -> URL {
        let pdf = PDFDocument()
        for (index, page) in pages.enumerated() {
            let image = await renderPage(page, notebook: notebook, storage: storage, scale: 2)
            guard let image, let pdfPage = PDFPage(image: image) else { continue }
            pdf.insert(pdfPage, at: index)
        }
        guard pdf.pageCount > 0 else { throw MacExportError.noPages }
        let url = outputURL(notebook: notebook, ext: "pdf")
        pdf.write(to: url)
        return url
    }

    private static func exportImages(
        notebook: Notebook,
        pages: [Page],
        storage: StorageService
    ) async throws -> URL {
        let folder = outputURL(notebook: notebook, ext: "").deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, page) in pages.enumerated() {
            guard let image = await renderPage(page, notebook: notebook, storage: storage, scale: 2),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let file = folder.appendingPathComponent(String(format: "page-%03d.png", index + 1))
            try png.write(to: file)
        }
        return folder
    }

    private static func exportMarkdown(
        notebook: Notebook,
        pages: [Page],
        storage: StorageService
    ) throws -> URL {
        var body = "# \(notebook.title)\n\n"
        for page in pages.sorted(by: { $0.pageNumber < $1.pageNumber }) {
            body += "## Page \(page.pageNumber + 1)\n\n"
            let pid = page.id
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
            )
            let elements = (try? storage.context.fetch(descriptor)) ?? []
            for element in elements {
                switch element.kind {
                case .text:
                    if let text = element.textContent?.text, !text.isEmpty {
                        body += text + "\n\n"
                    }
                case .stickyNote:
                    if let text = element.stickyNoteContent?.text, !text.isEmpty {
                        body += "> \(text)\n\n"
                    }
                default:
                    break
                }
            }
            if let strokeData = storage.strokeData(for: page), !strokeData.isEmpty {
                body += "_[Handwritten content on this page — open on iPad to view strokes]_\n\n"
            }
        }
        let url = outputURL(notebook: notebook, ext: "md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func renderPage(
        _ page: Page,
        notebook: Notebook,
        storage: StorageService,
        scale: CGFloat
    ) async -> NSImage? {
        let base = page.pageSize.pointSize
        let pixelSize = CGSize(width: base.width * scale, height: base.height * scale)
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.zIndex)]
        )
        let elements = (try? storage.context.fetch(descriptor)) ?? []
        let pdfMap = Dictionary(uniqueKeysWithValues: elements.compactMap { el -> (UUID, PageElement)? in
            guard el.kind == .pdfPage, let id = el.pdfPageContent?.id else { return nil }
            return (id, el)
        })

        let image = NSImage(size: pixelSize)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: pixelSize).fill()

        // Strokes
        if let strokeData = storage.strokeData(for: page),
           let drawing = try? PKDrawing(data: strokeData) {
            let strokeImage = drawing.image(from: CGRect(origin: .zero, size: pixelSize), scale: 1)
            strokeImage.draw(in: NSRect(origin: .zero, size: pixelSize))
        }

        // Rasterise SwiftUI elements via ImageRenderer
        let content = MacExportPageSnapshot(
            page: page,
            elements: elements,
            pdfParents: pdfMap,
            pageSize: pixelSize
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        if let elementImage = renderer.nsImage {
            elementImage.draw(in: NSRect(origin: .zero, size: pixelSize))
        }

        image.unlockFocus()
        return image
    }

    private static func outputURL(notebook: Notebook, ext: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let sanitized = notebook.title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty ? "Notebook" : sanitized
        if ext.isEmpty {
            return downloads.appendingPathComponent("\(base)-export", isDirectory: true)
        }
        return downloads.appendingPathComponent("\(base).\(ext)")
    }
}

private struct MacExportPageSnapshot: View {
    let page: Page
    let elements: [PageElement]
    let pdfParents: [UUID: PageElement]
    let pageSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(elements.filter { $0.kind != .stroke && $0.kind != .highlight }) { element in
                MacElementView(element: element, pageSize: pageSize, pdfParents: pdfParents)
            }
            ForEach(elements.filter { $0.kind == .highlight }) { element in
                MacElementView(element: element, pageSize: pageSize, pdfParents: pdfParents)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
    }
}

enum MacExportError: LocalizedError {
    case noPages
    var errorDescription: String? {
        switch self {
        case .noPages: return "This notebook has no pages to export."
        }
    }
}
