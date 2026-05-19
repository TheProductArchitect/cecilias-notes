import Foundation
import SwiftData

/// Builds a `PageContext` from a `Page` + the parent `Notebook`. Runs
/// on the main actor because SwiftData fetches require it; the result
/// is `Sendable` so it can be handed off to any provider.
///
/// The builder is intentionally a free function (in an `enum`
/// namespace) rather than an injected service: there's no state, no
/// configuration, and no reason a caller would ever want a different
/// implementation. The trade-off versus a protocol is that tests
/// substitute by passing a pre-built `PageContext` directly into
/// `AIService` rather than mocking the builder.
///
/// Filtering matches `TextElementsOverlayView` and friends: soft-
/// deleted elements (`deletedAt != nil`) are excluded so a page
/// being authored doesn't include trash.
@MainActor
enum PageContextBuilder {

    /// Build a `PageContext` for the given page. `notebookTitle` is
    /// passed in rather than fetched from `page.notebookId` because
    /// the editor already has the parent `Notebook` in scope —
    /// avoids a second fetch on a hot path.
    static func build(
        page: Page,
        notebookTitle: String,
        context: ModelContext = StorageService.shared.context
    ) -> PageContext {
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.zIndex)]
        )
        let elements = (try? context.fetch(descriptor)) ?? []

        var typed:     [String] = []
        var dictated:  [String] = []
        var stickies:  [String] = []
        var highlights: [String] = []

        for element in elements {
            switch element.kind {
            case .text:
                guard let content = element.textContent else { continue }
                let body = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                switch content.source {
                case .dictated:           dictated.append(body)
                case .typed, .pasted, .ai: typed.append(body)
                }

            case .stickyNote:
                guard let content = element.stickyNoteContent else { continue }
                let body = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                stickies.append(body)

            case .highlight:
                guard let captured = element.highlightContent?.capturedText else { continue }
                let body = captured.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                highlights.append(body)

            // Skipped per PageContext documentation:
            //   • .stroke  — handwriting OCR is a follow-up feature
            //   • .image   — vision model required
            //   • .audio   — transcript may already be on the page
            //                as dictated TextContent; avoid double-
            //                counting
            //   • .pdfPage — large PDF text would dominate the prompt
            //   • .shape   — no text content
            case .stroke, .image, .audio, .pdfPage, .shape:
                continue
            }
        }

        return PageContext(
            pageId: page.id,
            notebookTitle: notebookTitle,
            pageNumber: page.pageNumber,
            typedText: typed,
            dictatedText: dictated,
            stickyNotes: stickies,
            highlights: highlights
        )
    }
}
