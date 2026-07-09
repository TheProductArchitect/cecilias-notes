import Foundation
import SwiftData

/// Ingests `.inkbook` files written by external agents into the
/// app's SwiftData store. Idempotent: re-importing a file with the
/// same notebook UUID updates the existing record in place rather
/// than creating a duplicate.
///
/// **Concurrency strategy (v1.1).** Incoming files declare an
/// `mcp_action`:
///
///   • `create` / nil / unknown → wholesale replace of pages
///     (back-compat with pre-v1.1 MCPs and any non-MCP writer)
///   • `replace` → wholesale replace, explicit
///   • `append` → optimistic concurrency check:
///       - notebook missing → create (MCP got out of sync; accept)
///       - notebook present and live `updatedAt` matches the
///         file's `base_updated_at` → safe wholesale replace (no
///         iPad edits since the MCP read)
///       - notebook present but `updatedAt` ≠ `base_updated_at` →
///         **conflict**: keep every page currently on the notebook
///         and append only incoming pages whose `id` is not
///         already present locally. The iPad's concurrent edits
///         survive.
///
/// All persistence work runs on the main actor because the SwiftData
/// `ModelContext` reachable through `StorageService.shared` is
/// `@MainActor`-isolated. File parsing (the heavy bit) happens off
/// the main actor inside `importFile(at:)`.
@MainActor
final class CeciliasNotesImporter {

    static let shared = CeciliasNotesImporter()

    private init() {}

    /// Tail of the import pipeline. Each `importFile` chains onto the
    /// previous call's task so files persist strictly in arrival
    /// order. Without this, two rapid pushes of the same notebook
    /// (multipeer + iCloud, or two quick MCP writes) race their
    /// detached parse tasks — a large stale file can finish parsing
    /// AFTER a newer small one and clobber it on persist.
    private var lastImportTask: Task<Void, Never>?

    /// Public entry point used by `CeciliasNotesFileWatcher` and any
    /// manual "Import" command. Reads/parses off-main, then hops back
    /// to persist. Logs and swallows errors — a single malformed
    /// file must never crash the importer loop.
    func importFile(at url: URL) {
        let previous = lastImportTask
        lastImportTask = Task.detached(priority: .utility) {
            // FIFO: wait for the prior import to fully persist first.
            await previous?.value
            do {
                let file = try CeciliasNotesParser.parse(url: url)
                // Archive each page's rendered string to `Data` here on
                // the detached task. `NSAttributedString` isn't Sendable
                // (NSObject-backed), so capturing it in the `MainActor`
                // hop fails under Swift 6 strict concurrency. `Data` is
                // trivially Sendable and unarchiving on the main actor
                // is cheap (~microseconds for a few KB of text).
                let pageRichTextData: [Data] = file.pages
                    .sorted { $0.index < $1.index }
                    .map { CeciliasNotesParser.renderBlocks($0.blocks) }
                    .map {
                        (try? NSKeyedArchiver.archivedData(
                            withRootObject: $0,
                            requiringSecureCoding: true
                        )) ?? Data()
                    }

                await MainActor.run {
                    let pageRichText: [NSAttributedString] = pageRichTextData.map { data in
                        guard !data.isEmpty,
                              let unarchived = try? NSKeyedUnarchiver
                                .unarchivedObject(ofClass: NSAttributedString.self, from: data)
                        else { return NSAttributedString() }
                        return unarchived
                    }
                    do {
                        try CeciliasNotesImporter.shared.persist(
                            file: file,
                            pageRichText: pageRichText,
                            sourceFilename: url.lastPathComponent
                        )
                    } catch {
                        Self.log("persist failed for \(url.lastPathComponent): \(error)")
                    }
                }
            } catch {
                await Self.logAsync("parse failed for \(url.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: Persistence (main actor)

    private func persist(
        file: CeciliasNotesFile,
        pageRichText: [NSAttributedString],
        sourceFilename: String
    ) throws {
        let context = StorageService.shared.context

        let notebookId = UUID(uuidString: file.id) ?? UUID()

        // Dedupe by id. Existing notebook → wipe its pages + text
        // blocks and rebuild; missing → insert fresh.
        let existing = try fetchNotebook(id: notebookId, context: context)

        // Decide the page-write strategy before touching the
        // notebook. Default (`nil` / `create` / `replace` / unknown)
        // is the historical wholesale-replace behaviour; `append`
        // adds the optimistic concurrency check.
        let strategy = pageWriteStrategy(for: file, existing: existing)

        let notebook: Notebook
        if let existing {
            notebook = existing
            if strategy == .replace {
                try resetPages(of: notebook, context: context)
            }
            // For `.append` we keep the existing pages and let the
            // page-build loop below skip duplicates by id.
        } else {
            // Agent-authored notebooks land on `.blank` (see the
            // mutate-path comment below); other importers honour the
            // requested template.
            let createTemplate: PageTemplate = file.agent != nil
                ? .blank
                : CeciliasNotesFile.pageTemplate(from: file.page_template)
            notebook = Notebook(
                title: file.title,
                subjectId: try ensureSubject(named: file.subject, context: context),
                coverColorHex: "",
                coverTexture: .none,
                pageSize: CeciliasNotesFile.pageSize(from: file.page_size),
                defaultTemplate: createTemplate
            )
            // Override the auto-assigned id with the schema-supplied one
            // so future re-imports dedupe correctly.
            notebook.id = notebookId
            context.insert(notebook)
        }

        // Mutate top-level metadata in lockstep on both create + update
        // paths so updates pick up renames / subject moves / tone
        // changes from the agent.
        notebook.title    = file.title
        notebook.pageSize = CeciliasNotesFile.pageSize(from: file.page_size)
        // Agent-authored notebooks always land on the blank template
        // regardless of the `page_template` field. Agents emit typed
        // text — never strokes — and typed text on a ruled / dot-grid
        // background never lines up with the rule spacing (typography
        // metrics aren't a multiple of the 7-10mm rule lines), which
        // makes every MCP-created page look broken. Blank gives the
        // text a clean ground without arguing with the design intent.
        // The field is preserved in the round-tripped mirror so the
        // agent's choice isn't silently mutated on the next read.
        let requestedTemplate = CeciliasNotesFile.pageTemplate(from: file.page_template)
        let isAgentAuthored = file.agent != nil
        notebook.defaultTemplate = isAgentAuthored ? .blank : requestedTemplate
        if let toneSubjectId = try? ensureSubject(named: file.subject, context: context) {
            notebook.subjectId = toneSubjectId
            if let s = try? context.fetch(
                FetchDescriptor<Subject>(predicate: #Predicate { $0.id == toneSubjectId })
            ).first {
                notebook.subject = s
            }
        }
        if let tone = CeciliasNotesFile.coverTone(from: file.cover_tone) {
            CoverToneStore.setTone(tone, for: notebook.id)
        }

        // Agent attribution — persist EVERY field verbatim so the
        // mirror's `agent` block round-trips exactly. The previous
        // setup dropped `tool` / `tool_version` on the floor and
        // the exporter hard-coded substitutes, which corrupted the
        // attribution metadata external agents rely on for version
        // gating ("tool_version '1.0.1' becomes '1'" bug).
        if let agent = file.agent {
            notebook.isAgentWritten   = true
            notebook.agentName        = agent.written_by
            notebook.agentModel       = agent.model
            notebook.agentTool        = agent.tool
            notebook.agentToolVersion = agent.tool_version
        } else {
            notebook.isAgentWritten   = false
            notebook.agentName        = nil
            notebook.agentModel       = nil
            notebook.agentTool        = nil
            notebook.agentToolVersion = nil
        }
        notebook.sourceInkbookFilename = sourceFilename
        let isNewNotebook = existing == nil
        NotebookOriginRecorder.applyImport(from: file, to: notebook, isNew: isNewNotebook)
        if let created = NotebookOriginRecorder.parseISO8601(file.created_at), isNewNotebook {
            notebook.createdAt = created
        }
        if let updated = NotebookOriginRecorder.parseISO8601(file.updated_at) {
            notebook.updatedAt = updated
        }

        // Rebuild pages — behaviour depends on `strategy`:
        //   • `.replace` — `notebook.pages` was wiped above; insert
        //     every incoming page fresh, numbered 1..N.
        //   • `.append`  — `notebook.pages` is intact; insert only
        //     incoming pages whose id is not already present and
        //     number them after the existing tail. This preserves
        //     iPad edits made between the MCP's read and write.
        let sortedPages = file.pages.sorted { $0.index < $1.index }
        let existingIds: Set<UUID> = Set((notebook.pages ?? []).map(\.id))
        let existingTail = (notebook.pages ?? []).map(\.pageNumber).max() ?? 0
        let basePageNumber = strategy == .append ? existingTail : 0
        if strategy == .replace { notebook.pages = [] }

        var nextPageNumber = basePageNumber + 1
        for (idx, pageNode) in sortedPages.enumerated() {
            let candidateId = UUID(uuidString: pageNode.id)
            // Append-strategy skip: already on the notebook.
            if strategy == .append,
               let cid = candidateId, existingIds.contains(cid) {
                continue
            }

            let page = Page(
                notebookId: notebook.id,
                pageNumber: nextPageNumber,
                pageSize: notebook.pageSize,
                backgroundTemplate: notebook.defaultTemplate
            )
            if let pageId = candidateId { page.id = pageId }
            page.notebook = notebook
            // Stash the source blocks verbatim so the mirror can
            // emit them later without going through the lossy
            // text-flattening path. Encoded with the same JSON
            // settings the exporter uses so the bytes are
            // byte-identical when emitted.
            if let blocksJSON = Self.encodeBlocks(pageNode.blocks) {
                page.inkbookBlocksJSON = blocksJSON
            }
            context.insert(page)
            notebook.pages = (notebook.pages ?? []) + [page]
            nextPageNumber += 1

            // Single full-width TextBlock per page carrying the
            // rendered attributed string for every block on that
            // page. Coordinates are normalised 0..1; we give the
            // block a margin so it doesn't bleed into the page edge.
            // `pageRichText` is indexed against `sortedPages` (the
            // incoming page list), so the index is `idx`, not the
            // running `nextPageNumber`.
            let rich = pageRichText.indices.contains(idx)
                ? pageRichText[idx]
                : NSAttributedString()
            if rich.length > 0 {
                // Page-margin layout — `width = 0.80` leaves 10% gutter
                // on each side, matching the editor's text-element
                // page margin (~32pt at standard page widths) and
                // keeping MCP-written paragraphs well inside the
                // visible page-template area. The previous 0.88
                // width caused content to ride right up against the
                // page edge — looked like overflow next to a ruled
                // template whose lines have a real inner margin.
                let block = TextBlock(
                    pageId: page.id,
                    x: 0.10, y: 0.06, width: 0.80, height: 0.88
                )
                block.page         = page
                block.content      = rich.string
                block.richTextData = try? NSKeyedArchiver.archivedData(
                    withRootObject: rich,
                    requiringSecureCoding: true
                )
                context.insert(block)
                page.textBlocks = (page.textBlocks ?? []) + [block]
            }
        }
        notebook.totalPageCount = (notebook.pages ?? []).count

        if strategy == .append, let prior = existing {
            let resolution: String
            switch file.parsedMCPAction {
            case .append:
                if let base = file.base_updated_at, !base.isEmpty,
                   Self.iso.string(from: prior.updatedAt) != base {
                    resolution = "merged — notebook changed since agent read"
                } else {
                    resolution = "merged — preserved local pages"
                }
            case nil:
                resolution = "merged — safe default for incoming file"
            default:
                resolution = "merged — preserved local pages"
            }
            SyncConflictLog.record(
                notebookTitle: file.title,
                sourceFilename: sourceFilename,
                resolution: resolution
            )
        }

        try context.save()

        // Mirror the imported notebook to the MCP-readable directory so that
        // list_notebooks / read_notebook / search_notes tools see it
        // immediately without waiting for a user-triggered export.
        CeciliasNotesExporter.shared.export(notebook)
    }

    // MARK: Concurrency strategy

    /// Page-write strategy for one incoming file.
    /// `.replace` — wipe existing pages, insert all incoming.
    /// `.append`  — keep existing pages, insert only new (by id).
    enum PageWriteStrategy: Equatable { case replace, append }

    /// Resolve `mcp_action` + `base_updated_at` into a concrete
    /// page-write strategy. The default for any existing-notebook
    /// update is **merge by page id**, not wholesale replace —
    /// wholesale-replace as the implicit default was clobbering
    /// iPad-side edits and ink whenever the MCP wrote with a stale
    /// view of the mirror. Exposed `internal` for unit tests; the
    /// production call lives in `persist(...)`.
    func pageWriteStrategy(
        for file: CeciliasNotesFile,
        existing: Notebook?
    ) -> PageWriteStrategy {
        // No existing notebook: nothing to preserve, always replace.
        guard let existing else { return .replace }

        switch file.parsedMCPAction {
        case .create:
            // Notebook somehow already exists despite the MCP
            // intending to create it — treat the MCP's view as
            // authoritative (it wins on the dedupe-by-id case).
            return .replace
        case .replace:
            // Explicit "overwrite no matter what" — honour it.
            return .replace
        case .append:
            // Honour the optimistic-concurrency check when the
            // writer supplied `base_updated_at`: equal bases →
            // safe replace; mismatched / missing → merge. Either
            // way the merge path preserves iPad state for any
            // page id the incoming file doesn't carry.
            if let base = file.base_updated_at, !base.isEmpty,
               Self.iso.string(from: existing.updatedAt) == base {
                return .replace
            }
            return .append
        case nil:
            // No declared action (older MCPs, hand-dropped files).
            // The old default was wholesale replace, which lost
            // iPad work whenever the writer's view was stale —
            // by the time the file hits the Inbox, the iPad has
            // almost always moved on. Default to id-merge so the
            // safe path is the one that wins by accident.
            return .append
        }
    }

    /// Same formatter the exporter uses (default options →
    /// second-precision, UTC). Kept in sync with
    /// `CeciliasNotesExporter.iso` so the round-trip is exact.
    private static let iso = ISO8601DateFormatter()

    /// Encode an inkbook block array as a JSON string for storage
    /// on `Page.inkbookBlocksJSON`. Returns nil on encode failure
    /// (block list stays untracked → exporter falls back to the
    /// text-extraction path for that page).
    private static func encodeBlocks(_ blocks: [CeciliasNotesFile.Block]) -> String? {
        guard !blocks.isEmpty else { return "[]" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(blocks) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Inverse of `encodeBlocks`. Used by the exporter to round-trip
    /// stored inkbook blocks back into the structured `Block` array.
    nonisolated static func decodeBlocks(_ json: String?) -> [CeciliasNotesFile.Block]? {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([CeciliasNotesFile.Block].self, from: data)
    }

    // MARK: Helpers

    private func fetchNotebook(id: UUID, context: ModelContext) throws -> Notebook? {
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    /// Looks up a Subject by case-insensitive name; creates one if
    /// missing. Picks a colour from the curated preset list using a
    /// stable hash of the name so re-imports get the same colour.
    ///
    /// Notebooks must always live in a subject — when the agent
    /// supplies an empty / whitespace-only name, fall back to a
    /// dedicated "MCP" subject so the notebook still has a home.
    /// The user can move it to a different subject from the library
    /// any time.
    private func ensureSubject(named raw: String, context: ModelContext) throws -> UUID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "MCP" : trimmed

        let lower = name.lowercased()
        let descriptor = FetchDescriptor<Subject>(
            predicate: #Predicate { $0.isDeleted == false }
        )
        let all = (try? context.fetch(descriptor)) ?? []
        if let match = all.first(where: { $0.name.lowercased() == lower }) {
            return match.id
        }

        let colors = CeciliasNotesColorPresets.subjectColors
        let idx = abs(name.hashValue) % max(1, colors.count)
        let color = colors[idx]

        let subject = Subject(name: name, colorHex: color, sortOrder: all.count)
        context.insert(subject)
        return subject.id
    }

    /// Wipes existing pages + V6 elements before a re-import.
    private func resetPages(of notebook: Notebook, context: ModelContext) throws {
        for page in notebook.pages ?? [] {
            let pageId = page.id
            let elementDescriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate { $0.pageId == pageId }
            )
            for element in (try? context.fetch(elementDescriptor)) ?? [] {
                context.delete(element)
            }
            for block in page.textBlocks ?? [] {
                context.delete(block)
            }
            context.delete(page)
        }
        notebook.pages = []
    }

    // MARK: Logging

    private static func log(_ message: String) {
        #if DEBUG
        dlog("[CeciliasNotesImporter] \(message)")
        #endif
    }
    private static func logAsync(_ message: String) async {
        await MainActor.run { log(message) }
    }
}
