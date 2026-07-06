import CoreSpotlight
import Foundation
import PencilKit

/// Full-text search across notebook titles, typed `TextBlock` content,
/// audio transcripts, and handwriting (via Vision OCR). Entirely
/// on-device — Vision runs locally, the index is a single JSON file
/// in the app's Documents directory, and Spotlight donations are
/// queued through `SpotlightService` (also local).
///
/// Architecture:
///   • The index is `[notebookId: NotebookIndexEntry]` in memory.
///     Each notebook entry carries title text + per-page entries
///     keyed by `pageId`. Per-page entries hold the trio
///     (textBlockText, transcriptText, handwritingText) plus a
///     `pageStrokeUpdatedAt` stamp so refresh-on-launch can detect
///     stale OCR.
///   • Title / TextBlock / transcript updates are *synchronous* and
///     cheap (no OCR). They land on every notebook refresh through
///     `rebuildSynchronousMetadata(for:)`.
///   • Handwriting OCR is the expensive path. It's coalesced behind
///     a 2-second debounce on `scheduleOCR(for:)` and runs on a
///     detached Task at utility priority.
///   • The whole index is persisted to `search_index.json` after
///     any mutation, debounced by 1.5s so a burst of stroke saves
///     coalesces to one write.
///   • Soft-deleted notebooks (`isDeleted == true` or `deletedAt`
///     non-nil) are dropped from the index and the Spotlight domain
///     on the next refresh pass.
@MainActor
final class SearchIndexService {

    static let shared = SearchIndexService()

    // MARK: Index types

    struct PageIndexEntry: Codable {
        let pageId:                 UUID
        let pageNumber:             Int
        var textBlockText:          String
        var transcriptText:         String
        var handwritingText:        String
        /// Concatenated transcripts of every active `LectureRecord`
        /// on this page (`LectureStore.allActiveRecords(for:)`).
        /// Indexed separately from `transcriptText` (which sources
        /// from `AudioAnnotation`) so search results can be tagged
        /// with the originating surface, but both render in the same
        /// "Transcripts" section of `SearchResultsView`. Optional
        /// for Codable backward compatibility — an index JSON
        /// written before this field existed will still decode.
        var lectureTranscriptText:  String?
        /// Notebook `Page.updatedAt` at the time handwriting OCR
        /// last ran. Compared against the current `Page.updatedAt`
        /// on refresh to decide whether to re-OCR.
        var ocrUpdatedAt:           Date?
    }

    struct NotebookIndexEntry: Codable {
        let notebookId:         UUID
        var title:              String
        var subjectName:        String?
        /// `pageId.uuidString → PageIndexEntry`. Pages reordered by
        /// the user only mutate `pageNumber`; the dictionary key
        /// stays pinned to the page identity.
        var pages:              [String: PageIndexEntry]
    }

    private var index: [UUID: NotebookIndexEntry] = [:]
    private var pendingOCR: [UUID: Task<Void, Never>] = [:]
    private var persistTask: Task<Void, Never>?

    /// Index JSON file. `Documents/search_index.json` — purges with
    /// app uninstall, included in user's iCloud backup, never leaves
    /// the device. `URL` is `Sendable`, so a plain `static let` is
    /// safe to access from any isolation context without an
    /// annotation; the compiler proves the type-level safety.
    nonisolated private static let indexURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("search_index.json")
    }()

    /// Hard cap on the persisted index. When exceeded we keep title /
    /// TextBlock / transcript entries (small) and drop the OCR text
    /// (much larger per page) so the searchable surface degrades
    /// gracefully rather than ballooning unbounded. `Int` is
    /// `Sendable` — no annotation needed.
    nonisolated private static let maxIndexBytes: Int = 10 * 1024 * 1024

    /// `true` once `loadAsync()` has finished its first read off disk.
    /// All read + mutation paths early-return until this flips so:
    ///   • a partial in-memory state can never overwrite on-disk JSON
    ///     before disk content has been merged in;
    ///   • cold-launch search queries return an empty result rather
    ///     than a fragment of the previous session's index.
    private(set) var isLoaded: Bool = false

    private init() {
        // No disk I/O in init — `loadAsync()` is called from the app's
        // first frame (RootView's `.library` `.task`). Reading 10MB
        // JSON synchronously here hitches launch.
    }

    // MARK: - Persistence

    /// Read the persisted index off the main actor and merge it into
    /// memory. Idempotent — subsequent calls no-op once `isLoaded` is
    /// true. Call from a `.task` modifier on the first view that
    /// needs the index ready (typically the library home).
    func loadAsync() async {
        guard !isLoaded else { return }
        let entries: [NotebookIndexEntry]? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: Self.indexURL),
                  let parsed = try? JSONDecoder().decode(
                      [NotebookIndexEntry].self, from: data
                  )
            else { return nil }
            return parsed
        }.value
        if let entries {
            index = Dictionary(uniqueKeysWithValues: entries.map { ($0.notebookId, $0) })
        }
        isLoaded = true
        // Tell any view that's gating on readiness (currently the
        // Ask sheet's "still indexing your notes…" message) it can
        // accept input now. SwiftUI doesn't auto-observe `isLoaded`
        // because `SearchIndexService` isn't `ObservableObject` —
        // a notification keeps the dependency direction one-way.
        NotificationCenter.default.post(name: .searchIndexLoaded, object: nil)
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            await self.writeToDisk()
        }
    }

    private func writeToDisk() async {
        // Snapshot the index off the main actor since the encode call
        // itself is cheap-ish but writing 5–10MB to disk is not.
        let entries = Array(index.values)
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            if data.count > Self.maxIndexBytes {
                // Re-encode without handwriting text — keep the rest.
                let trimmed = entries.map { entry -> NotebookIndexEntry in
                    var copy = entry
                    copy.pages = copy.pages.mapValues { p in
                        var page = p
                        page.handwritingText = ""
                        return page
                    }
                    return copy
                }
                if let smaller = try? JSONEncoder().encode(trimmed) {
                    try? smaller.write(to: Self.indexURL, options: .atomic)
                }
                return
            }
            try? data.write(to: Self.indexURL, options: .atomic)
        }.value
    }

    // MARK: - Refresh (called on cold launch + foreground)

    /// Walk every non-deleted notebook in storage and bring the
    /// synchronous portion of the index up to date (titles + text
    /// blocks + transcripts). Pages whose `updatedAt` is newer than
    /// `PageIndexEntry.ocrUpdatedAt` are queued for OCR via
    /// `scheduleOCR(for:)`.
    ///
    /// Soft-deleted notebooks are pruned from both the in-memory
    /// index and the Spotlight domain in the same pass.
    func refreshAll() {
        // Don't walk storage until the persisted index has been merged.
        // The next foreground (or any `loadAsync()`-completion-following
        // refresh trigger) will re-fire and succeed.
        guard isLoaded else { return }
        let storage = StorageService.shared
        let notebooks = storage.fetchAllNotebooks()

        // Drop entries whose notebook is no longer present (or soft-
        // deleted — fetchAllNotebooks already filters by isDeleted).
        let liveIds = Set(notebooks.map(\.id))
        let strandedIds = Set(index.keys).subtracting(liveIds)
        if !strandedIds.isEmpty {
            for id in strandedIds { index.removeValue(forKey: id) }
            Task { [strandedIds] in
                for id in strandedIds {
                    await SpotlightService.shared.removeNotebook(id: id)
                }
            }
        }

        for notebook in notebooks {
            rebuildSynchronousMetadata(for: notebook)

            // Queue OCR for any page whose strokes are newer than the
            // last OCR pass. Empty / never-OCR'd pages get queued too.
            let pages = storage.fetchPages(in: notebook).filter { !$0.isDeleted }
            for page in pages where shouldOCR(page: page, notebookId: notebook.id) {
                scheduleOCR(notebookId: notebook.id, pageId: page.id)
            }

            // Spotlight donation — keywords / contentDescription are
            // drawn from the freshly-updated index entry, so the
            // donation reflects what's actually searchable.
            donateToSpotlight(notebook)
        }

        schedulePersist()
    }

    /// Drop a notebook's entry from the in-memory index and the
    /// Spotlight domain immediately. Called from
    /// `StorageService.deleteNotebook` so a soft-deleted notebook
    /// stops appearing in search the moment it's removed, rather
    /// than waiting for the next `refreshAll()` sweep to notice it
    /// missing from `fetchAllNotebooks`.
    func removeNotebook(id: UUID) {
        guard index.removeValue(forKey: id) != nil else { return }
        schedulePersist()
        Task { await SpotlightService.shared.removeNotebook(id: id) }
    }

    // MARK: - Synchronous metadata (titles + text blocks + transcripts)

    /// Rebuilds the cheap parts of the index for one notebook —
    /// title, subject name, and per-page TextBlock / transcript
    /// content. Handwriting OCR is left untouched and queued
    /// separately. Idempotent.
    func rebuildSynchronousMetadata(for notebook: Notebook) {
        guard isLoaded else { return }
        let storage = StorageService.shared
        let pages = storage.fetchPages(in: notebook).filter { !$0.isDeleted }
        let subjectName = notebook.subjectId.flatMap { sid in
            storage.fetchSubjects().first(where: { $0.id == sid })?.name
        }

        var entry = index[notebook.id] ?? NotebookIndexEntry(
            notebookId:  notebook.id,
            title:       notebook.title,
            subjectName: subjectName,
            pages:       [:]
        )
        entry.title       = notebook.title
        entry.subjectName = subjectName

        var freshPages: [String: PageIndexEntry] = [:]
        for page in pages {
            // `deletedAt == nil` carries the real soft-delete state
            // (the stored `isDeleted` never reads true — NSManagedObject
            // name collision swallows the setter).
            let textBlockText = (page.textBlocks ?? [])
                .filter { !$0.isDeleted && $0.deletedAt == nil }
                .map(\.content)
                .joined(separator: "\n")
            // Step 5: audio transcripts come from V6
            // `PageElement(.audio)` rows — short notes and lectures
            // were consolidated into the unified AudioContent type.
            // FUTURE: OCR on imported images via VNRecognizeTextRequest —
            // run each image through the Vision pipeline as
            // HandwritingOCRService does, and merge the result here.
            // Skipped this pass — images are placed but their
            // contents aren't searchable yet.
            let audioElements = StorageService.shared
                .fetchAudioElements(forPageId: page.id)
            let transcriptText = audioElements
                .compactMap { $0.audioContent?.transcript }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            // No separate "lecture transcript" channel — same
            // AudioContent.transcript is the source of truth. The
            // page-entry field stays for backwards compatibility
            // with the cached index format.
            let lectureTranscriptText = ""

            var pageEntry = entry.pages[page.id.uuidString] ?? PageIndexEntry(
                pageId:                 page.id,
                pageNumber:             page.pageNumber,
                textBlockText:          "",
                transcriptText:         "",
                handwritingText:        "",
                lectureTranscriptText:  nil,
                ocrUpdatedAt:           nil
            )
            pageEntry = PageIndexEntry(
                pageId:                 page.id,
                pageNumber:             page.pageNumber,
                textBlockText:          textBlockText,
                transcriptText:         transcriptText,
                handwritingText:        pageEntry.handwritingText,
                lectureTranscriptText:  lectureTranscriptText.isEmpty ? nil : lectureTranscriptText,
                ocrUpdatedAt:           pageEntry.ocrUpdatedAt
            )
            freshPages[page.id.uuidString] = pageEntry
        }
        entry.pages = freshPages
        index[notebook.id] = entry
        schedulePersist()
    }

    // MARK: - Handwriting OCR (debounced + incremental)

    private func shouldOCR(page: Page, notebookId: UUID) -> Bool {
        // Step 8: stroke storage moved to V6 `PageElement(.stroke) +
        // StrokeContent`. Read via the storage helper; OCR is
        // worthwhile only when there's an actual stroke blob.
        guard let data = StorageService.shared.strokeData(for: page),
              !data.isEmpty else { return false }
        guard let entry = index[notebookId]?.pages[page.id.uuidString] else { return true }
        guard let lastOCR = entry.ocrUpdatedAt else { return true }
        return page.updatedAt > lastOCR
    }

    /// Public hook for the editor's stroke-save pipeline. Coalesces
    /// rapid saves into a single OCR pass per page after 2s of
    /// quiet. Cancels any previous pending OCR for the same page.
    func scheduleOCR(notebookId: UUID, pageId: UUID) {
        guard isLoaded else { return }
        pendingOCR[pageId]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.runOCR(notebookId: notebookId, pageId: pageId)
            // `clearPendingOCR` is a sync `@MainActor` method; the
            // enclosing Task already inherits MainActor isolation
            // from the class, so the await would be spurious.
            self?.clearPendingOCR(pageId: pageId)
        }
        pendingOCR[pageId] = task
    }

    private func clearPendingOCR(pageId: UUID) {
        pendingOCR[pageId] = nil
    }

    private func runOCR(notebookId: UUID, pageId: UUID) async {
        let storage = StorageService.shared
        // Re-fetch fresh — the page may have been deleted / its
        // notebook moved between scheduling and firing.
        guard let page = storage.fetchPage(id: pageId), !page.isDeleted else { return }
        // Step 8: read via the V6 stroke singleton.
        guard let strokeData = storage.strokeData(for: page),
              let drawing = try? PKDrawing(data: strokeData)
        else { return }

        let pageSize = page.pageSize.pointSize
        let output = await HandwritingOCRService.recognise(
            drawing:  drawing,
            pageSize: pageSize
        )

        // Mutate the index back on the main actor.
        guard var notebookEntry = index[notebookId] else { return }
        guard var pageEntry = notebookEntry.pages[pageId.uuidString] else { return }
        pageEntry.handwritingText = output.joined
        pageEntry.ocrUpdatedAt    = Date()
        notebookEntry.pages[pageId.uuidString] = pageEntry
        index[notebookId] = notebookEntry
        schedulePersist()

        // Refresh the Spotlight donation so newly-OCR'd words show
        // up in iOS search. The page's `notebook` back-reference
        // resolves directly — no library-wide fetch needed.
        if let nb = page.notebook {
            donateToSpotlight(nb)
        }
    }

    // MARK: - Search

    /// Searches every indexed surface for `query`. Returns ordered
    /// results: titles, then text blocks, then transcripts, then
    /// handwriting (OCR is lower confidence and gets visually
    /// labelled in the UI).
    /// All searchable text for a notebook combined into a single
    /// string — TextBlocks + transcripts + OCR text from every page
    /// in `pageNumber` order. Used by `IntelligenceService` to feed
    /// summarisation / title suggestion / tag suggestion / Ask My
    /// Notes prompts. Returns an empty string for unknown
    /// notebooks; the AI methods short-circuit on insufficient text.
    func combinedText(for notebookId: UUID) -> String {
        guard isLoaded else { return "" }
        guard let entry = index[notebookId] else { return "" }
        let pages = entry.pages.values.sorted { $0.pageNumber < $1.pageNumber }
        let segments = pages.flatMap { page -> [String] in
            [
                page.textBlockText,
                page.transcriptText,
                page.handwritingText,
                page.lectureTranscriptText ?? ""
            ]
            .filter { !$0.isEmpty }
        }
        return ([entry.title] + segments).joined(separator: "\n\n")
    }

    /// Per-page text snippet for a single notebook, used by the
    /// Ask-My-Notes retrieval step to assemble its prompt context.
    /// Each tuple carries the page number and the combined
    /// TextBlock / transcript / OCR text for that page — preserves
    /// the "which page did this come from" mapping that's needed
    /// for the citations.
    func perPageText(
        for notebookId: UUID
    ) -> [(pageNumber: Int, pageId: UUID, text: String)] {
        guard isLoaded else { return [] }
        guard let entry = index[notebookId] else { return [] }
        return entry.pages.values
            .sorted { $0.pageNumber < $1.pageNumber }
            .map { p in
                let txt = [
                    p.textBlockText,
                    p.transcriptText,
                    p.handwritingText,
                    p.lectureTranscriptText ?? ""
                ]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                return (p.pageNumber, p.pageId, txt)
            }
    }

    // MARK: - Semantic search (Phase 4)

    private static let embeddingBackfillKey = "intelligence.embeddingBackfill.v1"

    /// One-shot pass that generates an embedding for every indexed
    /// notebook missing one. Gated on the `canRun` AI guard. Sets a
    /// UserDefaults flag on completion so the heavy walk doesn't
    /// re-run on every launch.
    ///
    /// FIXME — depends on the embedding API in `IntelligenceService`,
    /// which is stubbed pending the verified Foundation Models
    /// embedding entry point. Until that wires up this method runs
    /// but writes no vectors and the backfill flag never sets,
    /// leaving semantic search degraded to keyword-only.
    func backfillEmbeddingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.embeddingBackfillKey) else { return }
        guard IntelligenceService.shared.canRun else { return }
        let snapshot = Array(index.values)
        Task { @MainActor in
            var wrote = false
            for entry in snapshot {
                if IntelligenceCache.embedding(for: entry.notebookId) != nil { continue }
                let text = self.combinedText(for: entry.notebookId)
                guard !text.isEmpty,
                      let vec = await IntelligenceService.shared.embed(text: text)
                else { continue }
                IntelligenceCache.setEmbedding(vec, for: entry.notebookId)
                wrote = true
            }
            if wrote { defaults.set(true, forKey: Self.embeddingBackfillKey) }
        }
    }

    /// Cosine similarity for two equal-length float vectors. Returns
    /// 0 when shapes don't match — semantic ranking degrades
    /// gracefully when only some notebooks have embeddings.
    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot   += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    /// Async semantic search — embeds the query, ranks notebooks by
    /// cosine similarity against cached vectors. Returns one
    /// SearchResult per top match with a `~`-prefixed snippet.
    func semanticSearch(query: String, limit: Int = 5) async -> [SearchResult] {
        guard isLoaded else { return [] }
        guard IntelligenceService.shared.canRun else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let qVec = await IntelligenceService.shared.embed(text: trimmed)
        else { return [] }

        let scored: [(entry: NotebookIndexEntry, score: Float)] =
            index.values.compactMap { entry in
                guard let nbVec = IntelligenceCache.embedding(for: entry.notebookId)
                else { return nil }
                let s = Self.cosineSimilarity(qVec, nbVec)
                return s > 0.1 ? (entry, s) : nil
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }

        return scored.map { (entry, _) -> SearchResult in
            let preview = entry.pages.values
                .sorted { $0.pageNumber < $1.pageNumber }
                .first
            let txt = preview.map { p in
                p.textBlockText.isEmpty
                    ? (p.handwritingText.isEmpty ? p.transcriptText : p.handwritingText)
                    : p.textBlockText
            } ?? entry.title
            return SearchResult(
                notebookId: entry.notebookId,
                pageId:     preview?.pageId,
                pageNumber: preview?.pageNumber,
                context:    "~ " + String(txt.prefix(200)),
                type:       .textBlock
            )
        }
    }

    /// Run keyword search (synchronous) merged with semantic search
    /// (async) for any query of more than 3 words. Keyword matches
    /// rank first; semantic-only matches are appended after with
    /// their `~` snippet prefix.
    func combinedSearch(query: String) async -> [SearchResult] {
        guard isLoaded else { return [] }
        let keyword = search(query: query)
        let wordCount = query
            .split(whereSeparator: { $0.isWhitespace })
            .count
        guard wordCount > 3 else { return keyword }
        let semantic = await semanticSearch(query: query, limit: 5)
        let seen = Set(keyword.map(\.notebookId))
        return keyword + semantic.filter { !seen.contains($0.notebookId) }
    }

    /// Keyword + semantic search filtered to a single notebook.
    func search(inNotebook notebookId: UUID, query: String) async -> [SearchResult] {
        let results = await combinedSearch(query: query)
        return results.filter { $0.notebookId == notebookId }
    }

    func search(query: String) -> [SearchResult] {
        guard isLoaded else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()

        var titles:        [SearchResult] = []
        var textBlocks:    [SearchResult] = []
        var transcripts:   [SearchResult] = []
        var handwriting:   [SearchResult] = []

        for entry in index.values {
            if entry.title.lowercased().contains(needle) {
                titles.append(SearchResult(
                    notebookId: entry.notebookId,
                    pageId:     nil,
                    pageNumber: nil,
                    context:    entry.title,
                    type:       .notebookTitle
                ))
            }

            for page in entry.pages.values {
                if let snippet = Self.snippet(in: page.textBlockText, around: needle) {
                    textBlocks.append(SearchResult(
                        notebookId: entry.notebookId,
                        pageId:     page.pageId,
                        pageNumber: page.pageNumber,
                        context:    snippet,
                        type:       .textBlock
                    ))
                }
                if let snippet = Self.snippet(in: page.transcriptText, around: needle) {
                    transcripts.append(SearchResult(
                        notebookId: entry.notebookId,
                        pageId:     page.pageId,
                        pageNumber: page.pageNumber,
                        context:    snippet,
                        type:       .transcription
                    ))
                }
                if let lectureText = page.lectureTranscriptText,
                   let snippet = Self.snippet(in: lectureText, around: needle) {
                    transcripts.append(SearchResult(
                        notebookId: entry.notebookId,
                        pageId:     page.pageId,
                        pageNumber: page.pageNumber,
                        context:    snippet,
                        type:       .lectureTranscript
                    ))
                }
                if let snippet = Self.snippet(in: page.handwritingText, around: needle) {
                    handwriting.append(SearchResult(
                        notebookId: entry.notebookId,
                        pageId:     page.pageId,
                        pageNumber: page.pageNumber,
                        context:    snippet,
                        type:       .handwriting
                    ))
                }
            }
        }

        return titles + textBlocks + transcripts + handwriting
    }

    /// ±40-char window around the first case-insensitive occurrence
    /// of `needle` in `haystack`. Returns nil if no match. Preserves
    /// the matched word's original casing so the UI can find and
    /// bold it.
    private static func snippet(in haystack: String, around needle: String) -> String? {
        guard !haystack.isEmpty, !needle.isEmpty else { return nil }
        let lower = haystack.lowercased()
        guard let r = lower.range(of: needle) else { return nil }
        let window = 40
        let startOffset = max(0,
            haystack.distance(from: haystack.startIndex, to: r.lowerBound) - window)
        let endOffset   = min(haystack.count,
            haystack.distance(from: haystack.startIndex, to: r.upperBound) + window)
        let start = haystack.index(haystack.startIndex, offsetBy: startOffset)
        let end   = haystack.index(haystack.startIndex, offsetBy: endOffset)
        var snippet = String(haystack[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
        if startOffset > 0      { snippet = "… " + snippet }
        if endOffset < haystack.count { snippet = snippet + " …" }
        return snippet
    }

    // MARK: - Spotlight donation

    /// Donates the notebook to iOS Spotlight with title +
    /// description + keyword tokens drawn from the OCR + TextBlock
    /// text. Lookups in the OS-wide search bar match those tokens
    /// and deep-link back into the notebook via
    /// `CeciliasNotesApp.onContinueUserActivity`.
    private func donateToSpotlight(_ notebook: Notebook) {
        let entry = index[notebook.id]
        let combined = entry?.pages.values
            .map {
                [
                    $0.textBlockText,
                    $0.transcriptText,
                    $0.handwritingText,
                    $0.lectureTranscriptText ?? ""
                ].joined(separator: " ")
            }
            .joined(separator: " ") ?? ""
        let trimmed = combined
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let description = String(trimmed.prefix(200))
        let keywords = Self.tokens(from: combined, take: 60)
        Task { [keywords] in
            await SpotlightService.shared.scheduleIndex(
                id:            notebook.id,
                title:         notebook.title,
                subjectName:   entry?.subjectName,
                pageCount:     notebook.totalPageCount,
                thumbnailData: notebook.thumbnailData,
                createdAt:     notebook.createdAt,
                updatedAt:     notebook.updatedAt,
                tags:          notebook.tags + [description].filter { !$0.isEmpty } + keywords
            )
        }
    }

    /// Lowercase tokens of length ≥ 3, deduplicated, up to `take`.
    /// Spotlight matches against keywords as whole tokens, so the
    /// token list doubles as "extra searchable surface" for
    /// handwriting-only words that wouldn't appear in title /
    /// description.
    private static func tokens(from text: String, take: Int) -> [String] {
        let allowed = CharacterSet.alphanumerics
        let lowered = text.lowercased()
        let split = lowered.unicodeScalars
            .split { !allowed.contains($0) }
            .map(String.init)
            .filter { $0.count >= 3 }
        var seen = Set<String>()
        var out: [String] = []
        for tok in split {
            if seen.insert(tok).inserted { out.append(tok) }
            if out.count >= take { break }
        }
        return out
    }
}

// MARK: - Change notification

extension Notification.Name {
    /// Posted once after `SearchIndexService.loadAsync` finishes
    /// merging the persisted index into memory. Views that gate
    /// behaviour on `isLoaded` (e.g. Ask My Notes' "still
    /// indexing…" placeholder) observe this to flip out of the
    /// not-ready state without polling.
    static let searchIndexLoaded = Notification.Name("searchIndexLoaded")
}
