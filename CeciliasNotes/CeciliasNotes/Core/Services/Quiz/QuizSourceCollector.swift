import Foundation
import SwiftData

/// One notebook's worth of source text for quiz generation.
struct QuizSourceDocument {
    let notebookID: UUID
    let notebookTitle: String
    let subjectName: String?
    /// Typed text-block content, newline-joined per element.
    let typedText: [String]
    /// Audio transcription text (only when the scope includes it).
    let transcriptions: [String]

    var allText: [String] { typedText + transcriptions }
    var isEmpty: Bool { allText.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

/// Resolves a `QuizScope` into the concrete notebooks and their typed /
/// transcribed text. Pure read path — one fetch per notebook, no
/// mutation. Used by every generation tier as the common front end.
@MainActor
enum QuizSourceCollector {

    /// Resolve the scope to the set of notebook IDs it covers.
    static func notebookIDs(for scope: QuizScope, context: ModelContext) -> [UUID] {
        switch scope.type {
        case .notebook, .custom:
            return scope.notebookIDs
        case .subject:
            guard let subjectID = scope.subjectID else { return [] }
            let descriptor = FetchDescriptor<Notebook>(
                predicate: #Predicate<Notebook> {
                    $0.subjectId == subjectID && $0.isDeleted == false
                }
            )
            return ((try? context.fetch(descriptor)) ?? []).map(\.id)
        }
    }

    /// Collect source text for every notebook in the scope. Notebooks
    /// that no longer exist are silently skipped (handles the
    /// "source notebook deleted" edge case).
    ///
    /// `since` — when set, only elements updated strictly after this
    /// date are included. Used by `QuizAutoUpdater` to generate
    /// questions from only the content added since the last pass.
    static func collect(
        scope: QuizScope,
        context: ModelContext,
        since: Date? = nil
    ) -> [QuizSourceDocument] {
        let ids = notebookIDs(for: scope, context: context)
        var docs: [QuizSourceDocument] = []
        docs.reserveCapacity(ids.count)

        for id in ids {
            guard let notebook = fetchNotebook(id: id, context: context) else { continue }

            var elements = fetchElements(notebookID: id, context: context)
            if let since {
                elements = elements.filter { $0.updatedAt > since }
            }

            var typed: [String] = elements
                .filter { $0.kind == .text }
                .compactMap { $0.textContent?.text }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // PDF-imported pages stash `PDFPage.string` on
            // `PDFPageContent.extractedText` at import time. Fold
            // those in so quiz generation can read digital PDFs
            // (the embedded text layer is free; image-only /
            // scanned PDFs have nil and drop through).
            let pdfText: [String] = elements
                .filter { $0.kind == .pdfPage }
                .compactMap { $0.pdfPageContent?.extractedText }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            typed.append(contentsOf: pdfText)

            var transcripts: [String] = []
            if scope.includeTranscriptions {
                transcripts = elements
                    .filter { $0.kind == .audio }
                    .compactMap { $0.audioContent?.transcript }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }

            docs.append(QuizSourceDocument(
                notebookID: id,
                notebookTitle: notebook.title,
                subjectName: scope.subjectName,
                typedText: typed,
                transcriptions: transcripts
            ))
        }
        return docs
    }

    /// Total non-empty text "pages" in scope — drives the builder's
    /// `~{N} pages of content found` preview. Counts each text element
    /// and each transcription as one unit (cheap approximation).
    static func contentUnitCount(scope: QuizScope, context: ModelContext) -> Int {
        collect(scope: scope, context: context)
            .reduce(0) { $0 + $1.allText.count }
    }

    // MARK: - Fetch helpers

    private static func fetchNotebook(id: UUID, context: ModelContext) -> Notebook? {
        var descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate<Notebook> { $0.id == id && $0.isDeleted == false }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func fetchElements(notebookID: UUID, context: ModelContext) -> [PageElement] {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.notebookId == notebookID && $0.deletedAt == nil
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
