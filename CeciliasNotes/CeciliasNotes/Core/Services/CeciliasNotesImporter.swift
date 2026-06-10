import Foundation
import SwiftData

/// Ingests `.inkbook` files written by external agents into the
/// app's SwiftData store. Idempotent: re-importing a file with the
/// same notebook UUID updates the existing record in place rather
/// than creating a duplicate. Pages are replaced wholesale on
/// update — the schema is a snapshot, not a CRDT, so an agent that
/// regenerates a notebook gets a clean overwrite.
///
/// All persistence work runs on the main actor because the SwiftData
/// `ModelContext` reachable through `StorageService.shared` is
/// `@MainActor`-isolated. File parsing (the heavy bit) happens off
/// the main actor inside `importFile(at:)`.
@MainActor
final class CeciliasNotesImporter {

    static let shared = CeciliasNotesImporter()

    private init() {}

    /// Public entry point used by `CeciliasNotesFileWatcher` and any
    /// manual "Import" command. Reads/parses off-main, then hops back
    /// to persist. Logs and swallows errors — a single malformed
    /// file must never crash the importer loop.
    func importFile(at url: URL) {
        Task.detached(priority: .utility) {
            do {
                let file = try CeciliasNotesParser.parse(url: url)
                let pageRichText = file.pages
                    .sorted { $0.index < $1.index }
                    .map { CeciliasNotesParser.renderBlocks($0.blocks) }

                await MainActor.run { [pageRichText] in
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

        let notebook: Notebook
        if let existing {
            notebook = existing
            try resetPages(of: notebook, context: context)
        } else {
            notebook = Notebook(
                title: file.title,
                subjectId: try ensureSubject(named: file.subject, context: context),
                coverColorHex: "",
                coverTexture: .none,
                pageSize: CeciliasNotesFile.pageSize(from: file.page_size),
                defaultTemplate: CeciliasNotesFile.pageTemplate(from: file.page_template)
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
        notebook.defaultTemplate = CeciliasNotesFile.pageTemplate(from: file.page_template)
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

        // Agent attribution
        if let agent = file.agent {
            notebook.isAgentWritten      = true
            notebook.agentName           = agent.written_by
            notebook.agentModel          = agent.model
        } else {
            notebook.isAgentWritten = false
            notebook.agentName      = nil
            notebook.agentModel     = nil
        }
        notebook.sourceInkbookFilename = sourceFilename
        notebook.updatedAt = Date()

        // Rebuild pages
        let sortedPages = file.pages.sorted { $0.index < $1.index }
        notebook.pages = []
        for (idx, pageNode) in sortedPages.enumerated() {
            let page = Page(
                notebookId: notebook.id,
                pageNumber: idx + 1,
                pageSize: notebook.pageSize,
                backgroundTemplate: notebook.defaultTemplate
            )
            if let pageId = UUID(uuidString: pageNode.id) { page.id = pageId }
            page.notebook = notebook
            context.insert(page)
            notebook.pages = (notebook.pages ?? []) + [page]

            // Single full-width TextBlock per page carrying the
            // rendered attributed string for every block on that
            // page. Coordinates are normalised 0..1; we give the
            // block a margin so it doesn't bleed into the page edge.
            let rich = pageRichText.indices.contains(idx)
                ? pageRichText[idx]
                : NSAttributedString()
            if rich.length > 0 {
                let block = TextBlock(
                    pageId: page.id,
                    x: 0.06, y: 0.06, width: 0.88, height: 0.88
                )
                block.page         = page
                block.content      = rich.string
                block.richTextData = try? NSKeyedArchiver.archivedData(
                    withRootObject: rich,
                    requiringSecureCoding: false
                )
                context.insert(block)
                page.textBlocks = (page.textBlocks ?? []) + [block]
            }
        }
        notebook.totalPageCount = sortedPages.count

        try context.save()

        // Mirror the imported notebook to the MCP-readable directory so that
        // list_notebooks / read_notebook / search_notes tools see it
        // immediately without waiting for a user-triggered export.
        CeciliasNotesExporter.shared.export(notebook)
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
    /// Returns the subject id, or nil if name is empty.
    private func ensureSubject(named raw: String, context: ModelContext) throws -> UUID? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

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

    /// Wipes existing pages + text blocks before a re-import. SwiftData
    /// cascade rules drop the text blocks via `Page.textBlocks`, but we
    /// soft-delete-then-hard-delete to clear them out of the context
    /// graph cleanly before inserting replacements.
    private func resetPages(of notebook: Notebook, context: ModelContext) throws {
        for page in notebook.pages ?? [] {
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
        print("[CeciliasNotesImporter] \(message)")
        #endif
    }
    private static func logAsync(_ message: String) async {
        await MainActor.run { log(message) }
    }
}
