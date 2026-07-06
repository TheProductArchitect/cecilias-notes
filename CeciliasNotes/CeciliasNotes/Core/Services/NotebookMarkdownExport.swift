import Foundation
import SwiftData

/// Builds a Markdown document from typed text, sticky notes, and audio
/// transcripts. Shared by iOS export sheet and Mac export service.
@MainActor
enum NotebookMarkdownExport {

    enum Error: Swift.Error, LocalizedError {
        case noPages

        var errorDescription: String? {
            switch self {
            case .noPages: return "This notebook has no pages to export."
            }
        }
    }

    static func build(
        notebook: Notebook,
        pages: [Page],
        storage: StorageService
    ) -> String {
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
                case .audio:
                    if let transcript = element.audioContent?.transcript, !transcript.isEmpty {
                        body += "**Recording transcript:**\n\n\(transcript)\n\n"
                    }
                default:
                    break
                }
            }
            if let strokeData = storage.strokeData(for: page), !strokeData.isEmpty {
                body += "_[Handwritten content on this page — open on iPad to view strokes]_\n\n"
            }
        }
        return body
    }

    static func write(
        notebook: Notebook,
        pages: [Page],
        storage: StorageService,
        to url: URL
    ) throws {
        guard !pages.isEmpty else { throw Error.noPages }
        let body = build(notebook: notebook, pages: pages, storage: storage)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
