import Foundation
import SwiftData

/// Surfaces every soft-deleted record (`deletedAt != nil`) across
/// `Subject` / `Folder` / `Notebook` / `Page` / `PageElement` and
/// supplies restore + permanent-delete operations for the Trash UI.
///
/// Cascade rules:
///   • **Restore** walks UP the parent chain — restoring a Page
///     whose Notebook is also soft-deleted restores the Notebook
///     (and, transitively, its Folder and Subject) so the user
///     can actually find the restored record afterward.
///   • **Permanent delete** walks DOWN — purging a Notebook
///     removes its on-disk media files via the existing
///     `StorageService.purgeNotebookFiles` flow, then SwiftData
///     cascade-removes pages + text blocks. Element rows that
///     reference files (image/audio) are file-purged explicitly
///     because they're keyed by `pageId`/`notebookId` UUIDs, not
///     a SwiftData relationship.
@MainActor
final class TrashService {

    static let shared = TrashService()

    private let storage: StorageService
    private var context: ModelContext { storage.context }

    init(storage: StorageService? = nil) {
        self.storage = storage ?? .shared
    }

    // MARK: - Fetch

    /// Every soft-deleted record across all entity types, newest
    /// first. PageElements that exist purely because their parent
    /// page is soft-deleted are intentionally surfaced as their
    /// own rows — the user soft-deleted them individually, and
    /// hiding them under a deleted page would lose the granularity.
    func fetchAll() -> [TrashItem] {
        var items: [TrashItem] = []

        for subject in fetchDeletedSubjects() {
            items.append(TrashItem(
                id: subject.id,
                kind: .subject(subject),
                displayName: subject.name.isEmpty ? "Untitled subject" : subject.name,
                deletedAt: subject.deletedAt ?? .distantPast,
                context: "Subject"
            ))
        }

        for folder in fetchDeletedFolders() {
            let subjectName = subjectName(for: folder.parentSubjectId)
            items.append(TrashItem(
                id: folder.id,
                kind: .folder(folder),
                displayName: folder.name.isEmpty ? "Untitled folder" : folder.name,
                deletedAt: folder.deletedAt ?? .distantPast,
                context: subjectName.map { "Folder · \($0)" } ?? "Folder"
            ))
        }

        for notebook in fetchDeletedNotebooks() {
            let subjectName = notebook.subjectId.flatMap { self.subjectName(for: $0) }
            items.append(TrashItem(
                id: notebook.id,
                kind: .notebook(notebook),
                displayName: notebook.title.isEmpty ? "Untitled notebook" : notebook.title,
                deletedAt: notebook.deletedAt ?? .distantPast,
                context: subjectName.map { "Notebook · \($0)" } ?? "Notebook"
            ))
        }

        for page in fetchDeletedPages() {
            let parentTitle = notebookTitle(for: page.notebookId) ?? "Untitled notebook"
            items.append(TrashItem(
                id: page.id,
                kind: .page(page),
                displayName: "Page \(page.pageNumber)",
                deletedAt: page.deletedAt ?? .distantPast,
                context: "Page · \(parentTitle)"
            ))
        }

        for element in fetchDeletedElements() {
            let parentTitle = notebookTitle(for: element.notebookId) ?? "Untitled notebook"
            items.append(TrashItem(
                id: element.id,
                kind: .element(element),
                displayName: elementDisplayName(element),
                deletedAt: element.deletedAt ?? .distantPast,
                context: "Element · \(parentTitle)"
            ))
        }

        return items.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Total count of soft-deleted records across every entity type.
    /// Used for the sidebar count badge — fetches the rows rather
    /// than counting predicates because SwiftData's `fetchCount`
    /// fast-path doesn't currently support nil-comparison predicates
    /// on `Date?` columns cleanly.
    func itemCount() -> Int {
        fetchDeletedSubjects().count
            + fetchDeletedFolders().count
            + fetchDeletedNotebooks().count
            + fetchDeletedPages().count
            + fetchDeletedElements().count
    }

    // MARK: - Restore

    /// Restores the item by clearing `deletedAt`. Walks up the
    /// parent chain restoring any ancestor that is also soft-
    /// deleted so the restored record is reachable from the
    /// normal library surface afterward.
    func restore(_ item: TrashItem) throws {
        switch item.kind {
        case .subject(let subject):
            clearDeleted(on: subject)
        case .folder(let folder):
            clearDeleted(on: folder)
            if let parent = subjectById(folder.parentSubjectId), parent.deletedAt != nil {
                clearDeleted(on: parent)
            }
        case .notebook(let notebook):
            restoreNotebookChain(notebook)
        case .page(let page):
            page.isDeleted = false
            page.deletedAt = nil
            page.updatedAt = Date()
            if let notebook = notebookById(page.notebookId) {
                if notebook.deletedAt != nil {
                    restoreNotebookChain(notebook)
                }
                notebook.totalPageCount = (notebook.pages ?? []).filter { !$0.isDeleted }.count
                notebook.markModified()
            }
        case .element(let element):
            element.deletedAt = nil
            element.updatedAt = Date()
            if let page = pageById(element.pageId) {
                if page.deletedAt != nil {
                    page.isDeleted = false
                    page.deletedAt = nil
                    page.updatedAt = Date()
                }
                if let notebook = notebookById(page.notebookId), notebook.deletedAt != nil {
                    restoreNotebookChain(notebook)
                }
            }
        }
        try context.save()
        postRestoreRefetch(for: item)
    }

    /// The editor's per-page overlays cache their element fetches
    /// and refetch on change notifications — without this, an
    /// element restored while its notebook is mounted behind the
    /// Trash sheet stays invisible until the page remounts.
    private func postRestoreRefetch(for item: TrashItem) {
        guard case .element(let element) = item.kind else { return }
        let center = NotificationCenter.default
        switch element.kind {
        case .audio:
            center.post(name: .audioElementsChanged, object: nil)
        case .image:
            center.post(name: .mediaAttachmentsChanged, object: nil)
        case .shape:
            center.post(name: .shapeElementsChanged, object: nil)
        case .stickyNote:
            center.post(name: .stickyNotesChanged, object: nil)
        case .text:
            center.post(name: .textElementsChanged, object: nil)
        case .highlight:
            center.post(name: .highlightElementsChanged, object: nil)
        case .stroke:
            // Mounted canvases render their own in-memory drawing —
            // signal a reload for the restored strokes' page.
            center.post(
                name: .strokeContentRewritten,
                object: nil,
                userInfo: ["pageIds": [element.pageId]]
            )
        case .pdfPage:
            // PDF overlays refetch on page (re)mount; no dedicated
            // change notification exists. Restoring a pdfPage while
            // its page is mounted shows on next mount — acceptable.
            break
        }
    }

    private func clearDeleted(on subject: Subject) {
        subject.isDeleted = false
        subject.deletedAt = nil
        subject.updatedAt = Date()
    }

    private func clearDeleted(on folder: Folder) {
        folder.isDeleted = false
        folder.deletedAt = nil
        folder.updatedAt = Date()
    }

    private func restoreNotebookChain(_ notebook: Notebook) {
        notebook.isDeleted = false
        notebook.deletedAt = nil
        notebook.markModified()
        if let folderId = notebook.folderId, let folder = folderById(folderId), folder.deletedAt != nil {
            clearDeleted(on: folder)
        }
        if let subjectId = notebook.subjectId, let subject = subjectById(subjectId), subject.deletedAt != nil {
            clearDeleted(on: subject)
        }
        // Soft-delete deindexes the notebook from search/Spotlight —
        // restore must re-index or the notebook stays unsearchable
        // until some unrelated later save (2026-07-17 audit).
        storage.scheduleSpotlightReindex(for: notebook)
    }

    // MARK: - Permanent delete

    /// Permanently removes the item and its descendants from
    /// SwiftData, plus any associated media files on disk.
    /// Caller should already have confirmed with the user — this
    /// step is irreversible.
    func permanentlyDelete(_ item: TrashItem) throws {
        switch item.kind {
        case .subject(let subject):
            try permanentlyDelete(subject: subject)
        case .folder(let folder):
            try permanentlyDelete(folder: folder)
        case .notebook(let notebook):
            try permanentlyDelete(notebook: notebook)
        case .page(let page):
            try permanentlyDelete(page: page)
        case .element(let element):
            try permanentlyDelete(element: element)
        }
        try context.save()
    }

    /// Wipes every soft-deleted record across every entity type.
    /// Order matters: pages and elements first so file cleanup
    /// happens before SwiftData cascade-deletes the parent rows.
    func emptyTrash() throws {
        for element in fetchDeletedElements() {
            try permanentlyDelete(element: element)
        }
        for page in fetchDeletedPages() {
            try permanentlyDelete(page: page)
        }
        for notebook in fetchDeletedNotebooks() {
            try permanentlyDelete(notebook: notebook)
        }
        for folder in fetchDeletedFolders() {
            try permanentlyDelete(folder: folder)
        }
        for subject in fetchDeletedSubjects() {
            try permanentlyDelete(subject: subject)
        }
        try context.save()
    }

    // MARK: - Permanent delete helpers

    private func permanentlyDelete(subject: Subject) throws {
        // Hard-delete every notebook under the subject so file
        // cleanup runs. Subject.notebooks cascade rule would drop
        // the rows on its own, but the on-disk files would be
        // orphaned without an explicit purge.
        for notebook in subject.notebooks ?? [] {
            try permanentlyDelete(notebook: notebook)
        }
        // Folders under the subject have no file dependencies —
        // SwiftData cascade-removes them when the subject is deleted.
        context.delete(subject)
    }

    private func permanentlyDelete(folder: Folder) throws {
        // Folders own no files and no relationship-cascading
        // children of their own (notebooks reference folderId by
        // UUID, not by `@Relationship`). Drop the row.
        context.delete(folder)
    }

    private func permanentlyDelete(notebook: Notebook) throws {
        storage.purgeFiles(for: notebook)
        context.delete(notebook)
    }

    private func permanentlyDelete(page: Page) throws {
        storage.purgeFiles(forPageIds: [page.id])
        context.delete(page)
    }

    private func permanentlyDelete(element: PageElement) throws {
        let fm = FileManager.default
        switch element.kind {
        case .image:
            if let content = element.imageContent {
                try? fm.removeItem(at: content.fileURL)
            }
        case .audio:
            if let content = element.audioContent {
                try? fm.removeItem(at: content.fileURL)
            }
        default:
            break
        }
        context.delete(element)
    }

    // MARK: - Fetch helpers

    /// Each entity type carries an `isDeleted: Bool` flag that
    /// rides alongside `deletedAt: Date?` (set together in
    /// lockstep at every soft-delete callsite). Filtering on the
    /// bool plays nicer with SwiftData's `#Predicate` than a
    /// nil-comparison on the Date column.
    private func fetchDeletedSubjects() -> [Subject] {
        let d = FetchDescriptor<Subject>(predicate: #Predicate { $0.isDeleted == true })
        return (try? context.fetch(d)) ?? []
    }

    private func fetchDeletedFolders() -> [Folder] {
        let d = FetchDescriptor<Folder>(predicate: #Predicate { $0.isDeleted == true })
        return (try? context.fetch(d)) ?? []
    }

    private func fetchDeletedNotebooks() -> [Notebook] {
        let d = FetchDescriptor<Notebook>(predicate: #Predicate { $0.isDeleted == true })
        return (try? context.fetch(d)) ?? []
    }

    private func fetchDeletedPages() -> [Page] {
        let d = FetchDescriptor<Page>(predicate: #Predicate { $0.isDeleted == true })
        return (try? context.fetch(d)) ?? []
    }

    /// PageElements don't carry an `isDeleted` bool — only the
    /// timestamp. SwiftData's `#Predicate` does support nil-checks
    /// on optional Date columns; this query mirrors what the
    /// existing element soft-delete callsites set
    /// (`element.deletedAt = Date()`).
    private func fetchDeletedElements() -> [PageElement] {
        let d = FetchDescriptor<PageElement>(predicate: #Predicate { $0.deletedAt != nil })
        return (try? context.fetch(d)) ?? []
    }

    // MARK: - Lookups

    private func subjectById(_ id: UUID) -> Subject? {
        let d = FetchDescriptor<Subject>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(d))?.first
    }

    private func folderById(_ id: UUID) -> Folder? {
        let d = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(d))?.first
    }

    private func notebookById(_ id: UUID) -> Notebook? {
        let d = FetchDescriptor<Notebook>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(d))?.first
    }

    private func pageById(_ id: UUID) -> Page? {
        let d = FetchDescriptor<Page>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(d))?.first
    }

    private func subjectName(for id: UUID) -> String? {
        subjectById(id)?.name
    }

    private func notebookTitle(for id: UUID) -> String? {
        notebookById(id)?.title
    }

    private func elementDisplayName(_ element: PageElement) -> String {
        switch element.kind {
        case .image:      return "Image"
        case .audio:
            let secs = Int((element.audioContent?.durationSeconds ?? 0).rounded())
            return secs > 0 ? "Audio (\(secs)s)" : "Audio"
        case .stickyNote:
            let text = element.stickyNoteContent?.text ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Sticky Note" : String(trimmed.prefix(40))
        case .text:
            let trimmed = (element.textContent?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Text" : String(trimmed.prefix(40))
        case .pdfPage:    return "PDF Page"
        case .stroke:     return "Strokes"
        case .shape:      return "Shape"
        case .highlight:  return "Highlight"
        }
    }
}
