import PDFKit
import SwiftData
import SwiftUI
import AppKit

enum MacExportFormat: String, CaseIterable, Equatable {
    case pdf
    case images
    case markdown

    var label: String {
        switch self {
        case .pdf:       return "PDF"
        case .images:    return "Images (PNG)"
        case .markdown:  return "Markdown"
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
    ) async throws -> MacExportResult {
        let url: URL
        switch format {
        case .pdf:
            url = try await exportPDF(notebook: notebook, pages: pages, storage: storage)
        case .images:
            url = try await exportImages(notebook: notebook, pages: pages, storage: storage)
        case .markdown:
            url = try exportMarkdown(notebook: notebook, pages: pages, storage: storage)
        }

        let size = Self.fileSize(at: url)
        let result = MacExportResult(
            url: url,
            format: format,
            pageCount: pages.count,
            fileSizeBytes: size,
            notebookId: notebook.id,
            notebookTitle: notebook.title,
            exportedAt: Date()
        )
        await ExportManifest.shared.append(result.exportRecord)
        return result
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
        let url = try uniqueOutputURL(notebook: notebook, extension: "pdf", isDirectory: false)
        pdf.write(to: url)
        return url
    }

    private static func exportImages(
        notebook: Notebook,
        pages: [Page],
        storage: StorageService
    ) async throws -> URL {
        let folder = try uniqueOutputURL(notebook: notebook, extension: "png", isDirectory: true)
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
        let url = try uniqueOutputURL(notebook: notebook, extension: "md", isDirectory: false)
        try NotebookMarkdownExport.write(
            notebook: notebook,
            pages: pages,
            storage: storage,
            to: url
        )
        return url
    }

    static func renderPage(
        _ page: Page,
        notebook: Notebook,
        storage: StorageService,
        scale: CGFloat
    ) async -> NSImage? {
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil },
            sortBy: [
                SortDescriptor(\.normalizedY),
                SortDescriptor(\.normalizedX),
                SortDescriptor(\.zIndex),
            ]
        )
        let elements = (try? storage.context.fetch(descriptor)) ?? []
        let base = page.pageSize.pointSize
        let displaySize = CGSize(width: base.width * scale, height: base.height * scale)
        let theme = ThemeManager.shared.current

        let content = MacDocExportPageView(
            page: page,
            notebook: notebook,
            elements: elements,
            displaySize: displaySize
        )
        .environment(\.theme, theme)
        .environmentObject(storage)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.nsImage
    }

    private static func uniqueOutputURL(
        notebook: Notebook,
        extension ext: String,
        isDirectory: Bool
    ) throws -> URL {
        let exportsDir = StorageService.globalExportsDirectory
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let safeTitle = notebook.title
            .components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60)
        let baseName = safeTitle.isEmpty ? "Notebook" : String(safeTitle)
        let dateStr = String(ISO8601DateFormatter().string(from: Date()).prefix(10))

        if isDirectory {
            var folder = exportsDir.appendingPathComponent("\(baseName)_\(dateStr)-pages", isDirectory: true)
            var suffix = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = exportsDir.appendingPathComponent("\(baseName)_\(dateStr)-pages-\(suffix)", isDirectory: true)
                suffix += 1
            }
            return folder
        }

        var url = exportsDir.appendingPathComponent("\(baseName)_\(dateStr).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = exportsDir.appendingPathComponent("\(baseName)_\(dateStr)_\(suffix).\(ext)")
            suffix += 1
        }
        return url
    }

    static func fileSize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory == true {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            return contents.reduce(Int64(0)) { partial, item in
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return partial + size
            }
        }
        return Int64(values.fileSize ?? 0)
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
