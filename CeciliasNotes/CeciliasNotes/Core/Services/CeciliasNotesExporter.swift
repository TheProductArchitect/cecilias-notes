import Foundation
import SwiftData

/// Maintains a mirror of every live notebook as a `.inkbook` JSON file in the
/// app's iCloud container at `Documents/MCP/notebooks/<uuid>.inkbook`.
///
/// This directory is the read-side contract for `cecilias-notes-mcp` on macOS:
/// the MCP tools `list_notebooks`, `read_notebook`, and `search_notes` read
/// from it; `create_notebook` / `append_to_notebook` still write `.inkbook`
/// files to `Documents/Inbox/` as before.
///
/// **Content fidelity.** The app stores notebook content in SwiftData, not in
/// the original `.inkbook` block tree. The exporter reconstructs a best-effort
/// block list from two sources per page:
///   1. `TextBlock.content` — plain-text of agent-imported pages (old model).
///   2. `PageElement(.text).textContent.text` — user-typed / dictated text
///      (V6 model). Handwriting strokes are not serialisable to block form and
///      are omitted.
///
/// **When it runs.** Called by `CeciliasNotesImporter` after every import, and
/// by `StorageService` after `createNotebook`, `updateNotebook`, and
/// `deleteNotebook`. All file I/O is dispatched to a detached utility task so
/// the main actor is never blocked.
@MainActor
final class CeciliasNotesExporter {

    static let shared = CeciliasNotesExporter()
    private init() {}

    private static let containerIdentifier = "iCloud.app.ceciliasnotes"
    // ISO8601DateFormatter is documented thread-safe (unlike
    // DateFormatter); the export builds read it off-main.
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    // MARK: - Public API

    /// Build the mirror file for `notebook` and write it to the MCP
    /// notebooks directory. The BUILD is the heavy half (per-page
    /// stroke fetches, block extraction, text blobs), not just the
    /// write — so the whole pipeline runs on a detached task with
    /// its own background `ModelContext`. Building on the main
    /// actor stalled it for seconds on large libraries; combined
    /// with `scheduleExportAll` at backgrounding time that ate the
    /// ~5 s watchdog budget → 0x8badf00d terminations (ANRs).
    func export(_ notebook: Notebook) {
        Self.exportInBackground(
            notebookIds: [notebook.id],
            container: StorageService.shared.container
        )
    }

    /// Fetch → build → write for the given notebooks, sequentially,
    /// entirely off the main actor. A fresh `ModelContext` on the
    /// detached task reads the same store safely; row IDs cross the
    /// isolation boundary, model objects never do.
    nonisolated private static func exportInBackground(
        notebookIds: [UUID],
        container: ModelContainer
    ) {
        Task.detached(priority: .utility) {
            let context = ModelContext(container)
            for notebookId in notebookIds {
                let descriptor = FetchDescriptor<Notebook>(
                    predicate: #Predicate { $0.id == notebookId && $0.isDeleted == false }
                )
                guard let notebook = (try? context.fetch(descriptor))?.first else { continue }
                let file = buildFile(for: notebook, context: context)
                await writeFile(file, notebookId: notebookId)
            }
        }
    }

    /// Delete the mirror file for `notebookId`. Call after soft-deleting a
    /// notebook so MCP tools stop seeing it in list/search results.
    nonisolated func removeExport(for notebookId: UUID) {
        Task.detached(priority: .utility) {
            await Self.deleteExportFile(for: notebookId)
        }
    }

    /// Re-export every live notebook. Intended for the first run after
    /// enabling iCloud sync, or from a "Refresh MCP" Settings button.
    /// Only the ID list is read on the main actor; every build runs
    /// sequentially on one background context.
    func exportAll() {
        let ids = StorageService.shared.fetchAllNotebooks().map(\.id)
        Self.exportInBackground(
            notebookIds: ids,
            container: StorageService.shared.container
        )
    }

    /// Full mirror refresh. Runs at launch, on backgrounding, and at
    /// termination — all watchdog-sensitive moments, which is why the
    /// builds themselves live on a background context now.
    func scheduleExportAll() {
        exportAll()
    }

    /// Serialize `notebook` to `.inkbook` bytes in memory — used by
    /// the multipeer "send to device" flow, which ships the same
    /// schema the MCP mirror uses so the receiver's importer needs
    /// no new code path. Stays synchronous on the main actor: it's
    /// a one-off user action on a single notebook, and the caller
    /// needs the bytes inline.
    func inkbookData(for notebook: Notebook) -> Data? {
        let file = Self.buildFile(for: notebook, context: StorageService.shared.context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(file)
    }

    // MARK: - File-system helpers (nonisolated)

    private static func mcpNotebooksURL() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: containerIdentifier)?
            .appendingPathComponent("Documents")
            .appendingPathComponent("MCP")
            .appendingPathComponent("notebooks")
    }

    /// Canonical mirror filename for `notebookId`. Always uppercase
    /// — Swift's `UUID().uuidString` emits uppercase, so writers
    /// SHOULD normalise on uppercase. Readers MUST be
    /// case-insensitive (`existingExportURL(for:)` below) so a
    /// lowercase variant left over from an older MCP version still
    /// resolves to the right file on disk instead of triggering a
    /// stale duplicate write.
    private static func exportURL(for notebookId: UUID) -> URL? {
        mcpNotebooksURL()?.appendingPathComponent("\(notebookId.uuidString).inkbook")
    }

    /// Look for an existing mirror file regardless of UUID casing.
    /// Returns the canonical (uppercase) URL when the file already
    /// exists at that path; otherwise, scans the mirror directory
    /// for a case-insensitive UUID match (covers files written by
    /// older lowercase-emitting MCP versions). Returns nil when no
    /// match exists.
    private static func existingExportURL(for notebookId: UUID) -> URL? {
        guard let canonical = exportURL(for: notebookId) else { return nil }
        if FileManager.default.fileExists(atPath: canonical.path) { return canonical }
        guard let dir = mcpNotebooksURL(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
              )
        else { return nil }
        let targetStem = notebookId.uuidString.lowercased()
        for entry in entries {
            let stem = entry.deletingPathExtension().lastPathComponent.lowercased()
            if stem == targetStem { return entry }
        }
        return nil
    }

    private static func writeFile(_ file: CeciliasNotesFile, notebookId: UUID) async {
        guard let dir = mcpNotebooksURL() else { return }
        // Resolve to an existing (potentially lowercase) URL when
        // present so we overwrite the same file an older MCP wrote
        // rather than spawning a casing-variant duplicate.
        let fileURL = existingExportURL(for: notebookId)
            ?? exportURL(for: notebookId)
        guard let fileURL else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordError) { url in
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func deleteExportFile(for notebookId: UUID) async {
        // Use the case-insensitive lookup so a lowercase variant
        // left over from an older MCP gets deleted too.
        guard let fileURL = existingExportURL(for: notebookId) else { return }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordError) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Test-only entry point to the file builder. Production code
    /// uses `export(_:)` which writes the result to disk; tests
    /// need the in-memory `CeciliasNotesFile` for structural
    /// assertions without round-tripping through the filesystem.
    func testOnlyBuildFile(for notebook: Notebook) -> CeciliasNotesFile {
        Self.buildFile(for: notebook, context: StorageService.shared.context)
    }

    // MARK: - CeciliasNotesFile construction (background context)

    /// `nonisolated static` + explicit context so it can run on the
    /// background export context — model objects passed in MUST
    /// belong to `context`.
    nonisolated private static func buildFile(
        for notebook: Notebook,
        context: ModelContext
    ) -> CeciliasNotesFile {
        let subjectName = notebook.subject?.name
            ?? resolveSubjectName(id: notebook.subjectId, context: context)
            ?? ""

        let pages = (notebook.pages ?? [])
            .sorted { $0.pageNumber < $1.pageNumber }
            .enumerated()
            .map { idx, page -> CeciliasNotesFile.PageNode in
                let hasInk = pageHasInk(page, context: context)
                return CeciliasNotesFile.PageNode(
                    id: page.id.uuidString,
                    index: idx,
                    created_at: Self.iso.string(from: page.createdAt),
                    blocks: extractBlocks(from: page, context: context),
                    // Emit `has_ink` only when there are strokes —
                    // the optional field is omitted on encode when
                    // nil, keeping the schema additive (older
                    // readers see no extra key on text-only pages).
                    has_ink: hasInk ? true : nil
                )
            }

        // Agent block emitted verbatim from persisted columns —
        // `tool` and `tool_version` are NOT synthesised here.
        // Hard-coding them stomped on the original metadata
        // ("1.0.1" → "1"); they now round-trip exactly.
        let agent: CeciliasNotesFile.Agent? = notebook.isAgentWritten
            ? CeciliasNotesFile.Agent(
                written_by: notebook.agentName ?? "agent",
                model: notebook.agentModel,
                tool: notebook.agentTool ?? "cecilias-notes-mcp",
                tool_version: notebook.agentToolVersion ?? "1"
              )
            : nil

        let tone = CoverToneStore.tone(for: notebook.id)
        let origin = originBlock(for: notebook)

        return CeciliasNotesFile(
            schema: "https://ceciliasnotes.app/schemas/inkbook/v1.json",
            version: "1",
            id: notebook.id.uuidString,
            title: notebook.title,
            subject: subjectName,
            created_at: Self.iso.string(from: notebook.createdAt),
            updated_at: Self.iso.string(from: notebook.updatedAt),
            cover_tone: CeciliasNotesFile.schemaString(for: tone),
            page_template: CeciliasNotesFile.schemaString(for: notebook.defaultTemplate),
            page_size: CeciliasNotesFile.schemaString(for: notebook.pageSize),
            agent: agent,
            pages: pages.isEmpty ? [placeholderPage()] : pages,
            origin: origin,
            // The app's exporter never participates in the MCP's
            // append concurrency loop — it writes the canonical
            // snapshot that *becomes* the next `base_updated_at`
            // for any MCP read. Both concurrency fields are
            // intentionally left nil here so the mirror file is
            // treated as a fresh authoritative state, not as a
            // read-modify-write product.
            mcp_action: nil,
            base_updated_at: nil
        )
    }

    nonisolated private static func originBlock(for notebook: Notebook) -> CeciliasNotesFile.Origin? {
        guard notebook.createdOnDevice != nil
            || notebook.createdOnPlatform != nil
            || notebook.lastModifiedOnDevice != nil
            || notebook.lastModifiedOnPlatform != nil
        else { return nil }
        return CeciliasNotesFile.Origin(
            created_on_device: notebook.createdOnDevice,
            created_on_platform: notebook.createdOnPlatform,
            last_modified_on_device: notebook.lastModifiedOnDevice,
            last_modified_on_platform: notebook.lastModifiedOnPlatform
        )
    }

    nonisolated private static func extractBlocks(from page: Page, context: ModelContext) -> [CeciliasNotesFile.Block] {
        // Preferred path: the page was ingested from an `.inkbook`
        // file and the importer stashed the original block array
        // verbatim. Emit those bytes back as-is so heading levels,
        // list styles, callout kinds, code languages, etc. survive
        // the round-trip. The previous flatten-everything-into-
        // paragraphs behaviour permanently destroyed structure on
        // every mirror write.
        if let stashed = CeciliasNotesImporter.decodeBlocks(page.inkbookBlocksJSON) {
            return stashed
        }

        // Fallback for user-created pages and edited pages whose
        // structured source is gone — best-effort reconstruction
        // from the live SwiftData model.
        var blocks: [CeciliasNotesFile.Block] = []

        // 1. Old TextBlock model — used by agent-imported notebooks.
        let textBlocks = (page.textBlocks ?? [])
        for block in textBlocks {
            let t = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { blocks.append(.paragraph(content: t)) }
        }

        // 2. V6 PageElement(.text) model — user-typed / dictated content.
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.zIndex)]
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        for element in elements where element.kind == .text {
            if let t = element.textContent?.text.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                blocks.append(.paragraph(content: t))
            }
        }

        return blocks
    }

    /// True iff the page has a non-empty stroke singleton — i.e.
    /// the user has drawn ink on it. Surfaced as the `has_ink` flag
    /// on the mirror's `PageNode` so agents can tell handwritten
    /// pages apart from "this page literally has zero content."
    nonisolated private static func pageHasInk(_ page: Page, context: ModelContext) -> Bool {
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil }
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        for element in elements where element.kind == .stroke {
            if let stroke = element.strokeContent, !stroke.strokeData.isEmpty {
                return true
            }
        }
        return false
    }

    nonisolated private static func resolveSubjectName(id: UUID?, context: ModelContext) -> String? {
        guard let id else { return nil }
        let descriptor = FetchDescriptor<Subject>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first?.name
    }

    nonisolated private static func placeholderPage() -> CeciliasNotesFile.PageNode {
        CeciliasNotesFile.PageNode(
            id: UUID().uuidString,
            index: 0,
            created_at: Self.iso.string(from: Date()),
            blocks: []
        )
    }
}
