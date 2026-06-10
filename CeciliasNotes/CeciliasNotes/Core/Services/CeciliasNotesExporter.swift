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
    private static let iso = ISO8601DateFormatter()

    // MARK: - Public API

    /// Build the mirror file for `notebook` and write it to the MCP
    /// notebooks directory. Call from main actor context only.
    func export(_ notebook: Notebook) {
        let file = buildFile(for: notebook)
        let notebookId = notebook.id
        Task.detached(priority: .utility) {
            await Self.writeFile(file, notebookId: notebookId)
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
    func exportAll() {
        let notebooks = StorageService.shared.fetchAllNotebooks()
        for nb in notebooks { export(nb) }
    }

    // MARK: - File-system helpers (nonisolated)

    private static func mcpNotebooksURL() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: containerIdentifier)?
            .appendingPathComponent("Documents")
            .appendingPathComponent("MCP")
            .appendingPathComponent("notebooks")
    }

    private static func exportURL(for notebookId: UUID) -> URL? {
        mcpNotebooksURL()?.appendingPathComponent("\(notebookId.uuidString).inkbook")
    }

    private static func writeFile(_ file: CeciliasNotesFile, notebookId: UUID) async {
        guard let dir     = mcpNotebooksURL(),
              let fileURL = exportURL(for: notebookId)
        else { return }

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
        guard let fileURL = exportURL(for: notebookId) else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordError) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - CeciliasNotesFile construction (main actor)

    private func buildFile(for notebook: Notebook) -> CeciliasNotesFile {
        let context = StorageService.shared.context

        let subjectName = notebook.subject?.name
            ?? resolveSubjectName(id: notebook.subjectId, context: context)
            ?? ""

        let pages = (notebook.pages ?? [])
            .sorted { $0.pageNumber < $1.pageNumber }
            .enumerated()
            .map { idx, page in
                CeciliasNotesFile.PageNode(
                    id: page.id.uuidString,
                    index: idx,
                    created_at: Self.iso.string(from: page.createdAt),
                    blocks: extractBlocks(from: page, context: context)
                )
            }

        let agent: CeciliasNotesFile.Agent? = notebook.isAgentWritten
            ? CeciliasNotesFile.Agent(
                written_by: notebook.agentName ?? "agent",
                model: notebook.agentModel,
                tool: "cecilias-notes-mcp",
                tool_version: "1"
              )
            : nil

        let tone = CoverToneStore.tone(for: notebook.id)

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
            pages: pages.isEmpty ? [placeholderPage()] : pages
        )
    }

    private func extractBlocks(from page: Page, context: ModelContext) -> [CeciliasNotesFile.Block] {
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

    private func resolveSubjectName(id: UUID?, context: ModelContext) -> String? {
        guard let id else { return nil }
        let descriptor = FetchDescriptor<Subject>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first?.name
    }

    private func placeholderPage() -> CeciliasNotesFile.PageNode {
        CeciliasNotesFile.PageNode(
            id: UUID().uuidString,
            index: 0,
            created_at: Self.iso.string(from: Date()),
            blocks: []
        )
    }
}
