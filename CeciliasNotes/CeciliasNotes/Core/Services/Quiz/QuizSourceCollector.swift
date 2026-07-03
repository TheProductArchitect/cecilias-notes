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

            // Legacy V5 `TextBlock` rows — text in pre-V6 notebooks
            // AND every MCP/AI-imported notebook (the importer
            // writes TextBlock until the V6 text migration lands,
            // see MCP_SPEC.md §8). Without this fold-in, an
            // agent-written notebook full of text reads as "no
            // text the model can read" to quiz generation.
            var legacyBlocks = fetchLegacyTextBlocks(notebookID: id, context: context)
            if let since {
                legacyBlocks = legacyBlocks.filter { $0.updatedAt > since }
            }
            let legacyText = legacyBlocks
                .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            typed.append(contentsOf: legacyText)

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

    /// Total characters of readable text in scope. Drives the
    /// builder's "enough context to quiz on" eligibility gate — a
    /// unit count > 0 only proves *some* text exists; a two-word
    /// text block can't seed a meaningful quiz.
    static func contentCharacterCount(scope: QuizScope, context: ModelContext) -> Int {
        collect(scope: scope, context: context)
            .reduce(0) { sum, doc in
                sum + doc.allText.reduce(0) { $0 + $1.count }
            }
    }

    // MARK: - Fetch helpers

    private static func fetchNotebook(id: UUID, context: ModelContext) -> Notebook? {
        var descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate<Notebook> { $0.id == id && $0.isDeleted == false }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func fetchLegacyTextBlocks(notebookID: UUID, context: ModelContext) -> [TextBlock] {
        // TextBlock carries no notebookId of its own — resolve via
        // the notebook's live pages, then each page's blocks.
        let pageDescriptor = FetchDescriptor<Page>(
            predicate: #Predicate<Page> {
                $0.notebookId == notebookID && $0.isDeleted == false
            }
        )
        let pages = (try? context.fetch(pageDescriptor)) ?? []
        // Soft-delete check goes through `deletedAt`, not the
        // `isDeleted` flag: TextBlock's stored `isDeleted` collides
        // with NSManagedObject's built-in `isDeleted` at runtime, so
        // property writes to it are silently dropped — reads always
        // return false. `deletedAt` is set in lockstep by the
        // soft-delete path and round-trips reliably.
        return pages.flatMap { page in
            (page.textBlocks ?? []).filter { !$0.isDeleted && $0.deletedAt == nil }
        }
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
