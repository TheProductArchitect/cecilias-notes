import Combine
import Foundation
import PencilKit
import SwiftData
import UIKit
import WidgetKit

// MARK: - StorageService

@MainActor
final class StorageService: ObservableObject {

    // MARK: Singleton
    //
    // `StorageService` is `@MainActor`-isolated, which makes the
    // class implicitly `Sendable`. A plain `static let` on a
    // `Sendable` type is safe to access from any isolation context
    // without an annotation — the compiler proves the type-level
    // safety, so `nonisolated(unsafe)` is redundant. The init is
    // wrapped in `MainActor.assumeIsolated` because the
    // `StorageService()` initialiser itself is MainActor-isolated.
    // The `nonisolated` methods invoked through the singleton
    // (`hasSourcePDF`, `sourcePDFURL`) continue to be reachable
    // from off-main contexts because they're explicitly opted out
    // of MainActor isolation on the methods themselves.
    static let shared: StorageService = MainActor.assumeIsolated { StorageService() }

    // MARK: Directory URLs
    //
    // The SwiftData store always lives in `ceciliasNotesDirectoryURL` (local Application
    // Support — never synced; performance + integrity reasons). Only file
    // assets (`media/`, `audio/`, `exports/`) follow `notebooksDirectoryURL`,
    // which is dynamic: iCloud ubiquity container when sync is enabled and
    // available, local Application Support otherwise.
    //
    // Toggling iCloud doesn't migrate the SQLite store; it only relocates the
    // Notebooks asset directory. CloudSyncManager.enable()/disable() perform
    // the move and flip the persisted flag.

    nonisolated static var ceciliasNotesDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ink")
    }

    /// Local-only path. Used as the source/destination during enable/disable
    /// migration and as the fallback when iCloud isn't available.
    nonisolated static var localNotebooksDirectoryURL: URL {
        ceciliasNotesDirectoryURL.appendingPathComponent("Notebooks")
    }

    /// Resolves the notebooks asset root. Returns the iCloud ubiquity
    /// `Documents/Notebooks` when sync is enabled AND ubiquity is reachable;
    /// otherwise the local Application Support path.
    ///
    /// Persisted-flag key is `ink.icloud.sync.enabled` (owned by CloudSyncManager).
    nonisolated static var notebooksDirectoryURL: URL {
        let enabled = UserDefaults.standard.bool(forKey: "ink.icloud.sync.enabled")
        if enabled,
           let icloudRoot = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/Notebooks") {
            return icloudRoot
        }
        return localNotebooksDirectoryURL
    }

    // MARK: Core

    /// Exposed `internal` so the SwiftUI app root can inject the same
    /// container into the environment via `.modelContainer(_:)` —
    /// required for SwiftData `@Query` views (e.g. the sidebar's
    /// per-subject count) to reactively track store changes without
    /// going through the manual `LibraryViewModel.refresh()` cycle.
    let container: ModelContainer
    // Internal so adjacent file-scoped types in `Core/Services/`
    // (`LectureStore`, future `AudioStore` / `ImageStore`) can reach
    // the shared context without re-creating one or routing every
    // call through a wrapping method. The container is private; the
    // context is read-only for callers (they only use it for
    // `fetch` / `insert` / `delete` / `save`).
    let context: ModelContext

    /// Designated init — callers pass a container for testability.
    init(container: ModelContainer) {
        self.container = container
        self.context   = container.mainContext
        try? FileManager.default.createDirectory(
            at: Self.notebooksDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    /// Convenience init used by the singleton and CeciliasNotesApp. Container failure is
    /// genuinely terminal (no DB → no app), so we surface a precondition with a
    /// clear message rather than a bare `try!`.
    private convenience init() {
        do {
            let c = try ModelContainer.ceciliasNotesContainer()
            self.init(container: c)
        } catch {
            // Safe: SwiftData container init only fails when the on-disk SQLite
            // file is corrupt or Application Support is unwritable — unrecoverable
            // at startup. A descriptive crash is more useful than a zombie app.
            preconditionFailure( // Safe: terminal startup failure
                "Failed to open the CeciliasNotes SwiftData container: \(error). "
              + "This is unrecoverable; the app cannot start without on-disk storage."
            )
        }
    }

    // MARK: - One-time backfill

    /// Defensive recompute of `Notebook.totalPageCount` for every
    /// non-deleted notebook. The mutation sites
    /// (`createPage`/`deletePage`/`duplicateNotebook` etc.) keep the
    /// denormalised count accurate going forward, but pre-existing
    /// notebooks created before all those sites were wired could
    /// hold a stale value. Runs once per device, gated by a
    /// UserDefaults flag — subsequent launches skip the work.
    private static let pageCountBackfillKey = "cache.pageCount.backfillCompleted.v1"

    func runOneTimePageCountBackfillIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.pageCountBackfillKey) else { return }

        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isDeleted == false }
        )
        guard let notebooks = try? context.fetch(descriptor) else {
            return  // try again next launch
        }

        var dirty = false
        for notebook in notebooks {
            let live = (notebook.pages ?? []).filter { !$0.isDeleted }.count
            if notebook.totalPageCount != live {
                notebook.totalPageCount = live
                dirty = true
            }
        }
        if dirty { try? context.save() }

        defaults.set(true, forKey: Self.pageCountBackfillKey)
    }
}

// MARK: - File helpers

private extension StorageService {
    func notebookDir(_ notebookId: UUID) -> URL {
        Self.notebooksDirectoryURL.appendingPathComponent(notebookId.uuidString)
    }
    func mediaDir(_ notebookId: UUID) -> URL {
        notebookDir(notebookId).appendingPathComponent("media")
    }
    func audioDir(_ notebookId: UUID) -> URL {
        notebookDir(notebookId).appendingPathComponent("audio")
    }
    func exportsDir(_ notebookId: UUID) -> URL {
        notebookDir(notebookId).appendingPathComponent("exports")
    }

    func ensureDir(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw CeciliasNotesStorageError.fileWriteFailed(error)
        }
    }

    func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .flatMap { Int64($0) } ?? 0
            total += size
        }
        return total
    }
}

// MARK: - PDF backing (module-internal access)

extension StorageService {

    /// Path where an imported source PDF lives for a PDF-backed
    /// notebook. Fixed filename so the renderer / exporter can find
    /// it from a notebook id alone — there's at most one source PDF
    /// per notebook. `nonisolated` so the `Notebook` model's
    /// computed accessors (also nonisolated) can call this without
    /// hopping to the main actor.
    nonisolated func sourcePDFURL(_ notebookId: UUID) -> URL {
        Self.notebooksDirectoryURL
            .appendingPathComponent(notebookId.uuidString)
            .appendingPathComponent("source.pdf")
    }

    nonisolated func hasSourcePDF(_ notebookId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: sourcePDFURL(notebookId).path)
    }
}

// MARK: - Subjects

extension StorageService {

    func createSubject(name: String, colorHex: String) throws -> Subject {
        guard name.count <= 50 else { throw CeciliasNotesStorageError.fileSizeLimitExceeded }
        guard CeciliasNotesColorPresets.subjectColors.contains(colorHex) else {
            throw CeciliasNotesStorageError.fileWriteFailed(
                NSError(domain: "CeciliasNotes", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid subject colour hex: \(colorHex)"])
            )
        }
        let nextOrder = (fetchSubjects().map(\.sortOrder).max() ?? -1) + 1
        let subject = Subject(name: name, colorHex: colorHex, sortOrder: nextOrder)
        context.insert(subject)
        try context.save()
        return subject
    }

    func fetchSubjects() -> [Subject] {
        // Pinned subjects float to the top (isPinned == true sorts
        // ahead via `.reverse`). Among equal pin-state rows we order
        // by `sortOrder` ascending, with `createdAt` as a stable
        // tiebreaker so subjects with the additive-default `sortOrder
        // == 0` (everything pre-reorder) stay in creation order
        // rather than thrashing under SwiftData's unstable secondary
        // sort.
        let descriptor = FetchDescriptor<Subject>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.createdAt),
            ]
        )
        let results = (try? context.fetch(descriptor)) ?? []
        // Sort pinned subjects to the top in-memory; Bool isn't
        // usable with SortDescriptor on some SwiftData versions.
        return results.sorted { $0.isPinned && !$1.isPinned }
    }

    func updateSubject(_ subject: Subject, name: String?, colorHex: String?) throws {
        if let name {
            guard name.count <= 50 else { throw CeciliasNotesStorageError.fileSizeLimitExceeded }
            subject.name = name
        }
        if let colorHex {
            guard CeciliasNotesColorPresets.subjectColors.contains(colorHex) else {
                throw CeciliasNotesStorageError.fileWriteFailed(
                    NSError(domain: "CeciliasNotes", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid colour hex"])
                )
            }
            subject.colorHex = colorHex
        }
        subject.updatedAt = Date()
        try context.save()
    }

    /// Soft-deletes the subject and moves its notebooks to Uncategorised (subjectId = nil).
    func deleteSubject(_ subject: Subject) throws {
        for notebook in (subject.notebooks ?? []) where !notebook.isDeleted {
            notebook.subjectId = nil
            notebook.updatedAt = Date()
        }
        subject.isDeleted = true
        subject.deletedAt = Date()
        subject.updatedAt = Date()
        try context.save()
    }

    func reorderSubjects(_ subjects: [Subject]) throws {
        for (index, subject) in subjects.enumerated() {
            subject.sortOrder = index
            subject.updatedAt = Date()
        }
        try context.save()
    }

    /// Toggle a subject's pinned state. Pinned subjects float to the
    /// top of the sidebar; ordering inside each group still follows
    /// `sortOrder`. No-op when the requested value already matches.
    func setSubjectPinned(_ subject: Subject, isPinned: Bool) throws {
        guard subject.isPinned != isPinned else { return }
        subject.isPinned  = isPinned
        subject.updatedAt = Date()
        try context.save()
    }
}

// MARK: - Notebook manual ordering

extension StorageService {

    /// Assigns sequential `sortOrder` values 0..<N to `notebooks` in
    /// the order supplied. Used by the library's manual-sort mode to
    /// persist a drag-reorder in a single save. Existing values are
    /// overwritten — call sites pass the *desired* final ordering.
    func reorderNotebooks(_ notebooks: [Notebook]) throws {
        let now = Date()
        for (index, notebook) in notebooks.enumerated() where notebook.sortOrder != index {
            notebook.sortOrder = index
            notebook.updatedAt = now
        }
        try context.save()
    }
}

// MARK: - Folders

extension StorageService {

    /// Creates a folder under `subject`, optionally nested inside `parentFolderId`.
    /// Soft-deleted folders aren't fetched, so reusing a name across deletes is fine.
    func createFolder(name: String, in subject: Subject, parentFolderId: UUID? = nil) throws -> Folder {
        guard name.count <= 50 else { throw CeciliasNotesStorageError.fileSizeLimitExceeded }
        let nextOrder = (fetchFolders(in: subject.id).map(\.sortOrder).max() ?? -1) + 1
        let folder = Folder(
            name: name,
            parentSubjectId: subject.id,
            parentFolderId: parentFolderId,
            sortOrder: nextOrder
        )
        // CloudKit syncs the relationship reference, not the raw
        // `parentSubjectId` UUID — set both so cross-device fetches
        // can resolve the folder's parent. Same pattern at every
        // child-creation site below.
        folder.subject = subject
        context.insert(folder)
        subject.folders = (subject.folders ?? []) + [folder]
        try context.save()
        return folder
    }

    /// All non-deleted folders inside `subjectId`. Sorted by sortOrder, then name.
    func fetchFolders(in subjectId: UUID) -> [Folder] {
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { $0.parentSubjectId == subjectId && $0.isDeleted == false },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// All non-deleted folders across the app — used by Library when no
    /// subject filter is active ("All Notes" view).
    func fetchAllFolders() -> [Folder] {
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func updateFolder(_ folder: Folder, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 50 else {
            throw CeciliasNotesStorageError.fileSizeLimitExceeded
        }
        folder.name      = trimmed
        folder.updatedAt = Date()
        try context.save()
    }

    /// Soft-deletes a folder and moves any notebooks inside it back to the
    /// folder's parent (subject root, or the parent folder for nested folders).
    /// Notebooks are never deleted along with the folder.
    /// Soft-delete a folder, **promoting** its direct children one level up:
    ///   • Child folders' `parentFolderId` becomes this folder's parent.
    ///   • Child notebooks' `folderId` becomes this folder's parent.
    /// Children remain visible at the parent location. Use this for the
    /// "Move and Delete Folder" path of the delete prompt.
    func deleteFolder(_ folder: Folder) throws {
        let notebooks = fetchNotebooks(inFolder: folder.id)
        for nb in notebooks {
            nb.folderId  = folder.parentFolderId
            nb.updatedAt = Date()
        }
        let childFolders = fetchSubfolders(of: folder.id)
        for child in childFolders {
            child.parentFolderId = folder.parentFolderId
            child.updatedAt      = Date()
        }
        folder.isDeleted = true
        folder.deletedAt = Date()
        folder.updatedAt = Date()
        try context.save()
    }

    /// Soft-delete a folder **and everything inside it, recursively**. Use
    /// this for the "Delete Folder and All Contents" path. Notebooks and
    /// nested folders are soft-deleted; SwiftData relationships and the
    /// 30-day reaper handle final purge.
    func deleteFolderAndContents(_ folder: Folder) throws {
        // Notebooks at every level under this folder.
        for nb in fetchNotebooksRecursive(inFolder: folder.id) {
            nb.isDeleted = true
            nb.deletedAt = Date()
            nb.updatedAt = Date()
        }
        // Subfolders at every depth.
        for sub in fetchSubfoldersRecursive(of: folder.id) {
            sub.isDeleted = true
            sub.deletedAt = Date()
            sub.updatedAt = Date()
        }
        folder.isDeleted = true
        folder.deletedAt = Date()
        folder.updatedAt = Date()
        try context.save()
    }

    /// Direct child folders of `parentId` (one level only).
    func fetchSubfolders(of parentId: UUID) -> [Folder] {
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { $0.parentFolderId == parentId && $0.isDeleted == false },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// All folders at any depth under `parentId`. Used by recursive delete.
    private func fetchSubfoldersRecursive(of parentId: UUID) -> [Folder] {
        var result: [Folder] = []
        var queue = fetchSubfolders(of: parentId)
        while let next = queue.first {
            queue.removeFirst()
            result.append(next)
            queue.append(contentsOf: fetchSubfolders(of: next.id))
        }
        return result
    }

    /// All notebooks at any depth under `folderId`.
    private func fetchNotebooksRecursive(inFolder folderId: UUID) -> [Notebook] {
        var result: [Notebook] = fetchNotebooks(inFolder: folderId)
        for sub in fetchSubfoldersRecursive(of: folderId) {
            result.append(contentsOf: fetchNotebooks(inFolder: sub.id))
        }
        return result
    }

    /// Move a folder into / out of another folder (within the same subject).
    /// Pass `nil` to demote the folder to the subject root. Caller is
    /// responsible for cycle detection (don't move a folder into itself or
    /// into one of its descendants).
    func moveFolder(_ folder: Folder, toFolder parentFolderId: UUID?) throws {
        folder.parentFolderId = parentFolderId
        folder.updatedAt      = Date()
        try context.save()
    }

    /// Move a notebook into / out of a folder. Pass `nil` for "directly under
    /// the subject (no folder)". Caller is responsible for ensuring the
    /// folder is in the same subject as the notebook.
    func moveNotebook(_ notebook: Notebook, toFolder folderId: UUID?) throws {
        notebook.folderId  = folderId
        notebook.updatedAt = Date()
        try context.save()
    }

    /// Notebooks directly inside `folderId` (excludes nested folders' contents).
    func fetchNotebooks(inFolder folderId: UUID) -> [Notebook] {
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate {
                $0.folderId == folderId && $0.isDeleted == false
            },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Notebooks directly under `subjectId` that are NOT inside any folder.
    func fetchNotebooksWithoutFolder(subjectId: UUID?) -> [Notebook] {
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate {
                $0.subjectId == subjectId
                    && $0.folderId == nil
                    && $0.isDeleted == false
            },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}

// MARK: - Notebooks

extension StorageService {

    func createNotebook(
        title: String,
        subjectId: UUID?,
        coverColorHex: String,
        coverTexture: CoverTexture,
        pageSize: PageSize,
        template: PageTemplate
    ) throws -> Notebook {
        guard title.count <= 80 else { throw CeciliasNotesStorageError.fileSizeLimitExceeded }

        let notebook = Notebook(
            title: title,
            subjectId: subjectId,
            coverColorHex: coverColorHex,
            coverTexture: coverTexture,
            pageSize: pageSize,
            defaultTemplate: template
        )
        let nextOrder = (fetchNotebooks(subjectId: subjectId).map(\.sortOrder).max() ?? -1) + 1
        notebook.sortOrder = nextOrder
        context.insert(notebook)

        // Link to subject relationship and pick a cover tone from the
        // subject's rotation. Computed *before* we insert into the
        // relationship so `existingNotebooks` doesn't already include
        // this row.
        if let subjectId {
            let pred = #Predicate<Subject> { $0.id == subjectId && $0.isDeleted == false }
            if let subject = (try? context.fetch(FetchDescriptor(predicate: pred)))?.first {
                let assigned = CoverToneAssigner.tone(in: subject)
                CoverToneStore.setTone(assigned, for: notebook.id)
                // Set BOTH sides of the relationship explicitly.
                // `subject.notebooks.append(...)` would normally pick
                // up the inverse via SwiftData, but writing
                // `notebook.subject` explicitly is the canonical form
                // and ensures CloudKit syncs a resolvable record
                // reference even if the inverse population is delayed.
                notebook.subject = subject
                subject.notebooks = (subject.notebooks ?? []) + [notebook]
            }
        } else {
            let existing = fetchNotebooksWithoutFolder(subjectId: nil)
            let assigned = CoverToneAssigner.toneForUncategorised(existingNotebooks: existing)
            CoverToneStore.setTone(assigned, for: notebook.id)
        }

        // Create first page
        let page = Page(
            notebookId: notebook.id,
            pageNumber: 1,
            pageSize: pageSize,
            backgroundTemplate: template
        )
        page.notebook = notebook
        context.insert(page)
        notebook.pages = (notebook.pages ?? []) + [page]
        notebook.totalPageCount = 1

        try context.save()
        try ensureDir(notebookDir(notebook.id))
        scheduleSpotlightReindex(for: notebook)
        scheduleWidgetSnapshot()
        return notebook
    }

    func fetchNotebooks(subjectId: UUID?) -> [Notebook] {
        let descriptor: FetchDescriptor<Notebook>
        if let subjectId {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.subjectId == subjectId && $0.isDeleted == false }
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.subjectId == nil && $0.isDeleted == false }
            )
        }
        let notebooks = (try? context.fetch(descriptor)) ?? []
        return notebooks.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.sortOrder < $1.sortOrder
        }
    }

    func fetchAllNotebooks() -> [Notebook] {
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchPinnedNotebooks() -> [Notebook] {
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isPinned == true && $0.isDeleted == false },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Notebooks the user has actually opened, ordered by most recent
    /// access. Backed by `RecentNotebooksTracker` (UserDefaults) so we
    /// don't need a SwiftData schema change — adding a column to
    /// `Notebook` collides with the staged-migration version checksum
    /// (see the comment in `CeciliasNotesSchemas.swift`). The tracker survives
    /// the app, but a deleted notebook drops out of the list because
    /// the SwiftData fetch ignores its id.
    func fetchRecentNotebooks(limit: Int) -> [Notebook] {
        let recentIds = RecentNotebooksTracker.recentIdsNewestFirst()
        guard !recentIds.isEmpty else { return [] }

        // Single fetch of all live notebooks, then re-sorted in
        // recent-access order. Cheaper than N predicate fetches and
        // identical for any sane library size.
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isDeleted == false }
        )
        let live = (try? context.fetch(descriptor)) ?? []
        let byId = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })

        var out: [Notebook] = []
        for id in recentIds {
            if let nb = byId[id] {
                out.append(nb)
                if out.count == limit { break }
            }
        }
        return out
    }

    /// Stamp a notebook as "just opened". Called when the editor opens
    /// a notebook so it surfaces in the Library "recently opened"
    /// section. Backed by UserDefaults — no SwiftData mutation, no
    /// migration risk. Re-writes the widget snapshot so the home /
    /// lock screen recents rail mirrors the user's just-opened
    /// notebook within the next 15-minute refresh window (or
    /// immediately via `reloadAllTimelines` inside
    /// `scheduleWidgetSnapshot`).
    func markNotebookOpened(_ notebook: Notebook) {
        RecentNotebooksTracker.markOpened(notebook.id)
        scheduleWidgetSnapshot()
    }

    func updateNotebook(
        _ notebook: Notebook,
        title: String?,
        coverColorHex: String?,
        isPinned: Bool?,
        tags: [String]?,
        coverTexture: CoverTexture? = nil,
        pageSize: PageSize? = nil,
        defaultTemplate: PageTemplate? = nil
    ) throws {
        if let title {
            guard title.count <= 80 else { throw CeciliasNotesStorageError.fileSizeLimitExceeded }
            notebook.title = title
        }
        if let colorHex = coverColorHex { notebook.coverColorHex = colorHex }
        if let coverTexture { notebook.coverTexture = coverTexture }
        if let pageSize { notebook.pageSize = pageSize }
        if let defaultTemplate { notebook.defaultTemplate = defaultTemplate }
        if let pinned = isPinned { notebook.isPinned = pinned }
        if let tags {
            // Defence-in-depth — the UI runs every tag through
            // `TagValidator`, but the storage layer also clamps so a
            // direct mutation can't push past spec limits.
            let clamped = tags
                .prefix(TagValidator.maxTagsPerNotebook)
                .map { String($0.prefix(TagValidator.maxTagLength)) }
            notebook.tags = Array(clamped)
        }
        notebook.updatedAt = Date()
        try context.save()
        scheduleSpotlightReindex(for: notebook)
        scheduleWidgetSnapshot()
    }

    func moveNotebook(_ notebook: Notebook, to subjectId: UUID?) throws {
        // Remove from old subject relationship
        if let oldSubjectId = notebook.subjectId {
            let pred = #Predicate<Subject> { $0.id == oldSubjectId }
            if let old = (try? context.fetch(FetchDescriptor(predicate: pred)))?.first {
                old.notebooks?.removeAll { $0.id == notebook.id }
            }
        }
        notebook.subjectId = subjectId
        notebook.subject   = nil
        // Folders are scoped to a single subject — clear the folderId so
        // we never carry a stale reference across subjects.
        notebook.folderId  = nil
        notebook.updatedAt = Date()

        // Add to new subject relationship
        if let subjectId {
            let pred = #Predicate<Subject> { $0.id == subjectId && $0.isDeleted == false }
            if let new = (try? context.fetch(FetchDescriptor(predicate: pred)))?.first {
                notebook.subject = new
                new.notebooks = (new.notebooks ?? []) + [notebook]
            }
        }
        try context.save()
    }

    func deleteNotebook(_ notebook: Notebook) throws {
        notebook.isDeleted = true
        notebook.deletedAt = Date()
        notebook.updatedAt = Date()
        try context.save()
        let id = notebook.id
        // Drop the in-memory search entry immediately; SpotlightService
        // is hit inside removeNotebook(id:) too, so this also clears
        // the OS-level Spotlight donation without a duplicate call.
        SearchIndexService.shared.removeNotebook(id: id)
        scheduleWidgetSnapshot()
    }

    func duplicateNotebook(_ notebook: Notebook) async throws -> Notebook {
        let copy = Notebook(
            title: notebook.title + " Copy",
            subjectId: notebook.subjectId,
            coverColorHex: notebook.coverColorHex,
            coverTexture: notebook.coverTexture,
            pageSize: notebook.pageSize,
            defaultTemplate: notebook.defaultTemplate
        )
        copy.tags = notebook.tags
        copy.isPinned = false
        context.insert(copy)

        if let subjectId = notebook.subjectId {
            let pred = #Predicate<Subject> { $0.id == subjectId && $0.isDeleted == false }
            if let subject = (try? context.fetch(FetchDescriptor(predicate: pred)))?.first {
                copy.subject = subject
                subject.notebooks = (subject.notebooks ?? []) + [copy]
            }
        }

        let pages = fetchPages(in: notebook)
        for page in pages {
            let newPage = Page(
                notebookId: copy.id,
                pageNumber: page.pageNumber,
                pageSize: page.pageSize,
                backgroundTemplate: page.backgroundTemplate
            )
            newPage.strokeData     = page.strokeData
            newPage.strokeDataSize = page.strokeDataSize
            newPage.notebook       = copy
            context.insert(newPage)
            copy.pages = (copy.pages ?? []) + [newPage]

            for block in (page.textBlocks ?? []) where !block.isDeleted {
                let newBlock = TextBlock(
                    pageId: newPage.id, x: block.x, y: block.y,
                    width: block.width, height: block.height
                )
                newBlock.content      = block.content
                newBlock.richTextData = block.richTextData
                newBlock.rotation     = block.rotation
                newBlock.zIndex       = block.zIndex
                newBlock.page         = newPage
                context.insert(newBlock)
                newPage.textBlocks = (newPage.textBlocks ?? []) + [newBlock]
            }

            // Image attachments are V6 `PageElement(kind: .image)`
            // rows (Step 4). Duplicating image elements on
            // page-copy is unwired — fetching by pageId, cloning
            // each element + ImageContent with fresh UUIDs, and
            // copying the underlying file bytes is a follow-up.
            // No callers rely on it today.
            // Audio records are denormalised by pageId — fetch them
            // for the source page, clone each one with new ids
            // pointing at the new page + notebook, and copy the audio
            // file via `MediaStorage.url(for: .audio, id:)`.
            let sourcePageId = page.id
            let sourceRecords: [AudioRecord] = (try? context.fetch(
                FetchDescriptor<AudioRecord>(
                    predicate: #Predicate {
                        $0.pageId == sourcePageId && $0.deletedAt == nil
                    }
                )
            )) ?? []
            for source in sourceRecords {
                let cloneId = UUID()
                let clone = AudioRecord(
                    id:              cloneId,
                    pageId:          newPage.id,
                    notebookId:      copy.id,
                    normalizedX:     source.normalizedX,
                    normalizedY:     source.normalizedY,
                    durationSeconds: source.durationSeconds,
                    amplitudes:      source.amplitudes,
                    transcript:      source.transcript,
                    createdAt:       source.createdAt,
                    updatedAt:       Date()
                )
                context.insert(clone)
                try await copyFile(
                    from: MediaStorage.url(for: .audio, id: source.id),
                    to:   MediaStorage.url(for: .audio, id: cloneId)
                )
            }
        }

        copy.totalPageCount = (copy.pages ?? []).count
        try context.save()
        try ensureDir(notebookDir(copy.id))
        scheduleSpotlightReindex(for: copy)
        scheduleWidgetSnapshot()
        return copy
    }

    func reorderNotebooks(_ notebooks: [Notebook], in subjectId: UUID?) throws {
        for (index, notebook) in notebooks.enumerated() {
            notebook.sortOrder = index
            notebook.updatedAt = Date()
        }
        try context.save()
    }

    func updateThumbnail(for notebook: Notebook, image: UIImage) throws {
        guard let data = image.jpegData(compressionQuality: 0.80) else { return }
        notebook.thumbnailData = data
        notebook.updatedAt     = Date()
        try context.save()
    }

    // MARK: - Private file copy helper

    private func copyFile(from src: URL, to dst: URL) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Coordinator-wrapped when destination is in the iCloud container.
            try Self.copyFile(at: src, to: dst)
        } catch {
            throw CeciliasNotesStorageError.fileWriteFailed(error)
        }
    }
}

// MARK: - Pages

extension StorageService {

    func createPage(
        in notebook: Notebook,
        after pageNumber: Int?,
        pageSize: PageSize? = nil,
        backgroundTemplate: PageTemplate? = nil
    ) throws -> Page {
        let existingPages = fetchPages(in: notebook)
        let insertAfter   = pageNumber ?? existingPages.map(\.pageNumber).max() ?? 0

        // Shift pages after insertion point
        for page in existingPages where page.pageNumber > insertAfter {
            page.pageNumber += 1
            page.updatedAt  = Date()
        }

        let newPage = Page(
            notebookId: notebook.id,
            pageNumber: insertAfter + 1,
            pageSize: pageSize ?? notebook.pageSize,
            backgroundTemplate: backgroundTemplate ?? notebook.defaultTemplate
        )
        newPage.notebook = notebook
        context.insert(newPage)
        notebook.pages = (notebook.pages ?? []) + [newPage]
        notebook.totalPageCount = (notebook.pages ?? []).filter { !$0.isDeleted }.count
        notebook.updatedAt      = Date()
        try context.save()
        return newPage
    }

    /// Fetch a single page by ID. Used by background services (e.g.
    /// `SearchIndexService`'s OCR pass) that need to re-resolve a
    /// page from disk after a debounce window.
    func fetchPage(id: UUID) -> Page? {
        var descriptor = FetchDescriptor<Page>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func fetchPages(in notebook: Notebook) -> [Page] {
        let id = notebook.id
        let descriptor = FetchDescriptor<Page>(
            predicate: #Predicate { $0.notebookId == id && $0.isDeleted == false },
            sortBy: [SortDescriptor(\.pageNumber)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func updatePageStrokes(_ page: Page, drawing: PKDrawing) throws {
        let data            = drawing.dataRepresentation()
        page.strokeData     = data
        page.strokeDataSize = data.count
        page.updatedAt      = Date()
        // Bump the parent notebook's updatedAt so the Library + widget reflect activity.
        if let nb = notebookById(page.notebookId) {
            nb.updatedAt = Date()
            scheduleSpotlightReindex(for: nb)
        }
        try context.save()
        scheduleWidgetSnapshot()
    }

    /// Soft-deletes the page and renumbers all subsequent pages in the notebook.
    func deletePage(_ page: Page) throws {
        let notebookId  = page.notebookId
        let deletedNum  = page.pageNumber

        page.isDeleted  = true
        page.deletedAt  = Date()
        page.updatedAt  = Date()

        // Renumber subsequent pages
        let pred        = #Predicate<Page> { $0.notebookId == notebookId && $0.isDeleted == false }
        let remaining   = ((try? context.fetch(FetchDescriptor(predicate: pred, sortBy: [SortDescriptor(\.pageNumber)]))) ?? [])
            .filter { $0.pageNumber > deletedNum }
        for p in remaining {
            p.pageNumber -= 1
            p.updatedAt   = Date()
        }

        // Update notebook count
        if let nb = notebookById(notebookId) {
            nb.totalPageCount = (nb.pages ?? []).filter { !$0.isDeleted }.count
            nb.updatedAt      = Date()
        }
        try context.save()
    }

    /// INTENTIONAL: `duplicatePage` is a lightweight copy — strokes
    /// and text blocks only. Media attachments and audio annotations
    /// belong to the notebook, not to an individual page copy, so
    /// they are not duplicated when a single page is duplicated.
    /// Notebook-level duplication (`duplicateNotebook`) does carry
    /// media + audio across.
    func duplicatePage(_ page: Page) throws -> Page {
        guard let notebook = notebookById(page.notebookId) else {
            throw CeciliasNotesStorageError.notebookNotFound
        }
        let insertAfter  = page.pageNumber
        let existingPages = fetchPages(in: notebook)

        for p in existingPages where p.pageNumber > insertAfter {
            p.pageNumber += 1
            p.updatedAt   = Date()
        }

        let newPage = Page(
            notebookId: notebook.id,
            pageNumber: insertAfter + 1,
            pageSize: page.pageSize,
            backgroundTemplate: page.backgroundTemplate
        )
        newPage.strokeData     = page.strokeData
        newPage.strokeDataSize = page.strokeDataSize
        newPage.notebook       = notebook
        context.insert(newPage)
        notebook.pages = (notebook.pages ?? []) + [newPage]

        for block in (page.textBlocks ?? []) where !block.isDeleted {
            let nb = TextBlock(
                pageId: newPage.id, x: block.x, y: block.y,
                width: block.width, height: block.height
            )
            nb.content      = block.content
            nb.richTextData = block.richTextData
            nb.rotation     = block.rotation
            nb.zIndex       = block.zIndex
            nb.page         = newPage
            context.insert(nb)
            newPage.textBlocks = (newPage.textBlocks ?? []) + [nb]
        }

        notebook.totalPageCount = (notebook.pages ?? []).filter { !$0.isDeleted }.count
        notebook.updatedAt      = Date()
        try context.save()
        return newPage
    }

    func movePage(_ page: Page, to targetPageNumber: Int) throws {
        guard let notebook = notebookById(page.notebookId) else {
            throw CeciliasNotesStorageError.notebookNotFound
        }
        let pages = fetchPages(in: notebook)
        guard targetPageNumber >= 1 && targetPageNumber <= pages.count else {
            throw CeciliasNotesStorageError.pageNumberInvalid
        }

        let currentNumber = page.pageNumber
        let target        = targetPageNumber

        if currentNumber == target { return }

        let movingForward = target > currentNumber
        for p in pages where p.id != page.id {
            if movingForward, p.pageNumber > currentNumber, p.pageNumber <= target {
                p.pageNumber -= 1
                p.updatedAt   = Date()
            } else if !movingForward, p.pageNumber < currentNumber, p.pageNumber >= target {
                p.pageNumber += 1
                p.updatedAt   = Date()
            }
        }
        page.pageNumber = target
        page.updatedAt  = Date()
        try context.save()
    }

    // MARK: Private

    private func notebookById(_ id: UUID) -> Notebook? {
        let pred = #Predicate<Notebook> { $0.id == id && $0.isDeleted == false }
        return (try? context.fetch(FetchDescriptor(predicate: pred)))?.first
    }
}

// MARK: - Text Blocks

extension StorageService {

    func createTextBlock(on page: Page, at normalizedRect: CGRect) throws -> TextBlock {
        let block = TextBlock(
            pageId: page.id,
            x: normalizedRect.origin.x,
            y: normalizedRect.origin.y,
            width: normalizedRect.width,
            height: normalizedRect.height
        )
        let maxZ = ((page.textBlocks ?? []).map(\.zIndex).max() ?? -1) + 1
        block.zIndex = maxZ
        block.page   = page
        context.insert(block)
        page.textBlocks = (page.textBlocks ?? []) + [block]
        page.updatedAt = Date()
        try context.save()
        return block
    }

    func updateTextBlock(
        _ block: TextBlock,
        richText: NSAttributedString,
        rect: CGRect?
    ) throws {
        block.content      = richText.string
        block.richTextData = try NSKeyedArchiver.archivedData(
            withRootObject: richText,
            requiringSecureCoding: false
        )
        if let rect {
            block.x      = rect.origin.x
            block.y      = rect.origin.y
            block.width  = rect.width
            block.height = rect.height
        }
        block.updatedAt = Date()
        try context.save()
    }

    func deleteTextBlock(_ block: TextBlock) throws {
        block.isDeleted = true
        block.deletedAt = Date()
        block.updatedAt = Date()
        try context.save()
    }

    /// Persist a recording transcript as a standalone `TextBlock` —
    /// used when Settings has "Save audio clips" off but
    /// "Generate transcripts" on, so there's no `AudioAnnotation` to
    /// hang the transcript on. Drops the block in the upper-left
    /// quadrant at a sensible default size; the user can move/resize
    /// after the fact like any other text block.
    @discardableResult
    func createTextBlock(on page: Page, content: String) throws -> TextBlock {
        let block = TextBlock(
            pageId: page.id,
            x:      0.06,
            y:      0.08,
            width:  0.45,
            height: 0.18
        )
        block.content     = content
        let maxZ          = ((page.textBlocks ?? []).map(\.zIndex).max() ?? -1) + 1
        block.zIndex      = maxZ
        block.page        = page
        context.insert(block)
        page.textBlocks = (page.textBlocks ?? []) + [block]
        page.updatedAt    = Date()
        try context.save()
        return block
    }

    /// Like `createTextBlock(on:content:)` but uses an explicit
    /// normalised rect — used by the lecture/audio block placement
    /// path so the caller can stack new cards beneath existing ones
    /// without re-implementing the SwiftData mutation.
    /// See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.C.
    @discardableResult
    func createTextBlock(
        on page: Page,
        content: String,
        normalizedRect: CGRect
    ) throws -> TextBlock {
        let block = TextBlock(
            pageId: page.id,
            x:      normalizedRect.origin.x,
            y:      normalizedRect.origin.y,
            width:  normalizedRect.width,
            height: normalizedRect.height
        )
        block.content = content
        let maxZ      = ((page.textBlocks ?? []).map(\.zIndex).max() ?? -1) + 1
        block.zIndex  = maxZ
        block.page    = page
        context.insert(block)
        page.textBlocks = (page.textBlocks ?? []) + [block]
        page.updatedAt = Date()
        try context.save()
        return block
    }
}

// MARK: - Audio Records
//
// Phase 5A+5C Step 3: `AudioAnnotation` reshaped into `AudioRecord`.
// No relationship to `Page` — records are denormalised by `pageId`
// and queried via `FetchDescriptor`. The audio file URL is derived
// directly from `record.id` (`MediaStorage.url(for: .audio, id:)`)
// so there's no `fileName` field on the record any more.

extension StorageService {

    /// Insert a fresh `AudioRecord` for a page. Called by
    /// `EditorViewModel.startRecording` when the user taps the
    /// quick-record button. The audio bytes don't exist yet — they
    /// land on disk under `MediaStorage.url(for: .audio, id: record.id)`
    /// once recording stops.
    @discardableResult
    func addAudioRecord(
        to page: Page,
        duration: Double,
        at point: CGPoint
    ) throws -> AudioRecord {
        let record = AudioRecord(
            pageId:          page.id,
            notebookId:      page.notebookId,
            normalizedX:     Double(point.x),
            normalizedY:     Double(point.y),
            durationSeconds: duration
        )
        context.insert(record)
        page.updatedAt = Date()
        try context.save()
        return record
    }

    /// Update the transcript text on a record. Called by
    /// `SpeechTranscriber` once on-device recognition completes.
    /// Word-level segments are no longer stored — the popover player
    /// that used them was deleted in Phase 4B.
    func updateTranscription(_ record: AudioRecord, text: String) throws {
        record.transcript = text
        record.updatedAt  = Date()
        try context.save()
    }

    /// Update the waveform amplitudes array on a record. Called by
    /// `SpeechTranscriber` once amplitude extraction completes.
    /// `[Float]` is stored natively by SwiftData — no JSON
    /// round-trip.
    func updateAmplitudes(_ record: AudioRecord, amplitudes: [Float]) throws {
        record.amplitudes = amplitudes
        record.updatedAt  = Date()
        try context.save()
    }

    func deleteAudioRecord(_ record: AudioRecord) throws {
        record.deletedAt = Date()
        record.updatedAt = Date()
        try context.save()
    }

    /// Returns the on-disk URL for a record's audio file. Pure
    /// passthrough to `MediaStorage`.
    func audioURL(for record: AudioRecord) -> URL {
        MediaStorage.url(for: .audio, id: record.id)
    }

    /// Called by `AudioFilePicker` after the file is already copied
    /// into `MediaStorage.url(for: .audio, id:)`.
    @discardableResult
    func insertAudioFile(
        to page: Page,
        recordId: UUID,
        duration: Double,
        at point: CGPoint
    ) throws -> AudioRecord {
        let record = AudioRecord(
            id:              recordId,
            pageId:          page.id,
            notebookId:      page.notebookId,
            normalizedX:     Double(point.x),
            normalizedY:     Double(point.y),
            durationSeconds: duration
        )
        context.insert(record)
        page.updatedAt = Date()
        try context.save()
        return record
    }

    func fetchAudioRecord(id: UUID) -> AudioRecord? {
        var descriptor = FetchDescriptor<AudioRecord>(
            predicate: #Predicate { $0.id == id && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Active records for a page, oldest-first.
    func fetchAudioRecords(forPageId pageId: UUID) -> [AudioRecord] {
        let descriptor = FetchDescriptor<AudioRecord>(
            predicate: #Predicate { $0.pageId == pageId && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Moves a record's anchor to a new normalised position.
    func moveAudioRecord(_ record: AudioRecord, to point: CGPoint) throws {
        record.normalizedX = Double(point.x)
        record.normalizedY = Double(point.y)
        record.updatedAt   = Date()
        try context.save()
    }
}


// MARK: - Search

extension StorageService {

    func search(query: String) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed.lowercased()
        var results: [SearchResult] = []

        // Build pageId → notebookId map
        let allPages = (try? context.fetch(
            FetchDescriptor<Page>(predicate: #Predicate { $0.isDeleted == false })
        )) ?? []
        let pageToNotebook: [UUID: UUID] = Dictionary(
            uniqueKeysWithValues: allPages.map { ($0.id, $0.notebookId) }
        )

        // Notebook titles
        for nb in fetchAllNotebooks() where nb.title.lowercased().contains(q) {
            results.append(SearchResult(
                notebookId: nb.id,
                pageId: nil,
                context: nb.title,
                type: .notebookTitle
            ))
        }

        // Text blocks
        let blocks = (try? context.fetch(
            FetchDescriptor<TextBlock>(predicate: #Predicate { $0.isDeleted == false })
        )) ?? []
        for block in blocks where block.content.lowercased().contains(q) {
            guard let nbId = pageToNotebook[block.pageId] else { continue }
            results.append(SearchResult(
                notebookId: nbId,
                pageId: block.pageId,
                context: String(block.content.prefix(120)),
                type: .textBlock
            ))
        }

        // Audio transcripts (Phase 5A+5C Step 3: AudioAnnotation
        // reshaped into AudioRecord; transcript is non-optional and
        // empty when unrecognised).
        let audioRecords = (try? context.fetch(
            FetchDescriptor<AudioRecord>(predicate: #Predicate { $0.deletedAt == nil })
        )) ?? []
        for rec in audioRecords {
            guard !rec.transcript.isEmpty,
                  rec.transcript.lowercased().contains(q),
                  let nbId = pageToNotebook[rec.pageId] else { continue }
            results.append(SearchResult(
                notebookId: nbId,
                pageId: rec.pageId,
                context: String(rec.transcript.prefix(120)),
                type: .transcription
            ))
        }

        return results
    }
}

// MARK: - Storage Info

extension StorageService {

    func localStorageUsed() async -> StorageInfo {
        let fm = FileManager.default

        let dbURL   = Self.ceciliasNotesDirectoryURL.appendingPathComponent("ink.sqlite")
        let dbBytes = (try? fm.attributesOfItem(atPath: dbURL.path)[.size] as? Int64) ?? 0

        var mediaBytes: Int64 = 0
        var audioBytes: Int64 = 0

        let notebookDirs = (try? fm.contentsOfDirectory(
            at: Self.notebooksDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for dir in notebookDirs {
            mediaBytes += directorySize(at: dir.appendingPathComponent("media"))
            audioBytes += directorySize(at: dir.appendingPathComponent("audio"))
        }

        return StorageInfo(
            totalBytes: dbBytes + mediaBytes + audioBytes,
            audioBytes: audioBytes,
            mediaBytes: mediaBytes,
            dbBytes: dbBytes
        )
    }

    func clearExportedPDFs() async throws {
        let fm   = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: Self.notebooksDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for dir in dirs {
            let exportsDir = dir.appendingPathComponent("exports")
            guard fm.fileExists(atPath: exportsDir.path) else { continue }
            do {
                try fm.removeItem(at: exportsDir)
                try fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)
            } catch {
                throw CeciliasNotesStorageError.fileWriteFailed(error)
            }
        }
    }

    func clearAudioRecordings() async throws {
        let fm   = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: Self.notebooksDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for dir in dirs {
            let aDir = dir.appendingPathComponent("audio")
            guard fm.fileExists(atPath: aDir.path) else { continue }
            do {
                try fm.removeItem(at: aDir)
                try fm.createDirectory(at: aDir, withIntermediateDirectories: true)
            } catch {
                throw CeciliasNotesStorageError.fileWriteFailed(error)
            }
        }
        // Soft-delete all AudioRecord rows (Phase 5A+5C Step 3 —
        // type renamed, `isDeleted` Bool replaced by `deletedAt`
        // nullable as the soft-delete signal).
        let descriptor = FetchDescriptor<AudioRecord>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        let records = (try? context.fetch(descriptor)) ?? []
        let now = Date()
        for rec in records {
            rec.deletedAt = now
            rec.updatedAt = now
        }
        try context.save()
    }

    func exportedPDFsSizeBytes() -> Int64 {
        directorySize(at: ExportService.globalExportsDirectory)
    }

    func audioSizeBytes() -> Int64 {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: Self.notebooksDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        return dirs.reduce(0) { $0 + directorySize(at: $1.appendingPathComponent("audio")) }
    }

    func notebookCount() -> Int {
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isDeleted == false }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    // MARK: Trash management

    /// Physically deletes all records soft-deleted more than 30 days ago.
    func purgeExpiredDeletedRecords() throws {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)

        // Subjects
        let deletedSubjects = (try? context.fetch(
            FetchDescriptor<Subject>(predicate: #Predicate { $0.isDeleted == true })
        )) ?? []
        for s in deletedSubjects where (s.deletedAt ?? .distantFuture) < cutoff {
            context.delete(s)
        }

        // Folders (added in V3 — same 30-day soft-delete pattern)
        let deletedFolders = (try? context.fetch(
            FetchDescriptor<Folder>(predicate: #Predicate { $0.isDeleted == true })
        )) ?? []
        for f in deletedFolders where (f.deletedAt ?? .distantFuture) < cutoff {
            context.delete(f)
        }

        // Notebooks
        let deletedNotebooks = (try? context.fetch(
            FetchDescriptor<Notebook>(predicate: #Predicate { $0.isDeleted == true })
        )) ?? []
        for nb in deletedNotebooks where (nb.deletedAt ?? .distantFuture) < cutoff {
            purgeNotebookFiles(nb)
            context.delete(nb)
        }

        // Pages, blocks, attachments, annotations handled by cascade delete
        try context.save()
    }

    func emptyTrash() throws {
        let allSubjects = (try? context.fetch(
            FetchDescriptor<Subject>(predicate: #Predicate { $0.isDeleted == true })
        )) ?? []
        allSubjects.forEach { context.delete($0) }

        let allFolders = (try? context.fetch(
            FetchDescriptor<Folder>(predicate: #Predicate { $0.isDeleted == true })
        )) ?? []
        allFolders.forEach { context.delete($0) }

        let allNotebooks = (try? context.fetch(
            FetchDescriptor<Notebook>(predicate: #Predicate { $0.isDeleted == true })
        )) ?? []
        for nb in allNotebooks {
            purgeNotebookFiles(nb)
            context.delete(nb)
        }
        try context.save()
    }

    private func purgeNotebookFiles(_ notebook: Notebook) {
        let dir = notebookDir(notebook.id)
        try? FileManager.default.removeItem(at: dir)
        // Side-channel stores live in UserDefaults — wipe entries for
        // every page in the purged notebook so the dictionaries don't
        // accumulate orphaned mappings over time.
        let pageIds = (notebook.pages ?? []).map(\.id)
        PDFBackingStore.forget(pageIds: pageIds)
        StickyNoteStore.forget(pageIds: pageIds)
        // PDF text annotations (highlight / underline / strikethrough)
        // ride the same side-channel pattern — wipe them so a
        // reaper-purged notebook doesn't leave orphaned annotation
        // records keyed to pages that no longer exist.
        PDFTextAnnotationStore.forget(pageIds: pageIds)
        // Image attachments — Step 4 retired `MediaAttachmentStore`.
        // V6 image elements are `PageElement(kind: .image)` rows
        // with backing files at `MediaStorage.url(for: .images, id:)`.
        // Fetch each element for the dead pages, remove the file
        // by `ImageContent.id` (which matches the filename UUID),
        // then drop the row.
        purgeImageElements(forPageIds: pageIds)
        // Lecture records live in UserDefaults; their audio files
        // sit under `notebookDir/audio/` and are already swept by
        // the `removeItem(at: dir)` above. `forget(pageIds:)` is
        // still called so the per-page dictionary doesn't retain
        // orphaned record metadata.
        LectureStore.forget(pageIds: pageIds)
        // AI caches — summary in UserDefaults, embedding in a
        // Documents/embeddings/<uuid>.bin file. Both live on-device
        // and the notebook being permanently removed means both
        // should disappear too.
        IntelligenceCache.clearSummaries(for: [notebook.id])
        IntelligenceCache.clearDismissedTags(for: [notebook.id])
        IntelligenceCache.clearEmbeddings(for: [notebook.id])
        // Per-notebook UserDefaults side-channels not already
        // wiped above. Cover tone, preferences, and recent-opened
        // tracker all live in `UserDefaults.standard`.
        CoverToneStore.forget(notebook.id)
        NotebookPreferencesStore.forget(notebook.id)
        RecentNotebooksTracker.forget(notebook.id)
        SearchIndexService.shared.removeNotebook(id: notebook.id)
    }

    /// Step 4: hard-delete every V6 image element for the given
    /// pages AND remove the underlying image files from disk.
    /// Called from `purgeNotebookFiles` on reaper purge. Files are
    /// removed before the rows are deleted so we can still resolve
    /// `ImageContent.fileURL`. SwiftData cascade-deletes
    /// `ImageContent` when the parent `PageElement` is removed.
    private func purgeImageElements(forPageIds pageIds: [UUID]) {
        guard !pageIds.isEmpty else { return }
        let pageIdSet = Set(pageIds)
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { pageIdSet.contains($0.pageId) }
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        let fm = FileManager.default
        for element in elements where element.kind == .image {
            if let content = element.imageContent {
                try? fm.removeItem(at: content.fileURL)
            }
            context.delete(element)
        }
        try? context.save()
    }
}

// MARK: - Spotlight + widget integration (Stage 10)

extension StorageService {

    /// Debounced re-index. Caller should pass the just-saved notebook.
    func scheduleSpotlightReindex(for notebook: Notebook) {
        let id            = notebook.id
        let title         = notebook.title
        let subjectName   = notebook.subjectId.flatMap { sid in
            fetchSubjects().first { $0.id == sid }?.name
        }
        let pageCount     = notebook.totalPageCount
        let thumbnailData = notebook.thumbnailData
        let createdAt     = notebook.createdAt
        let updatedAt     = notebook.updatedAt
        let tags          = notebook.tags

        Task {
            await SpotlightService.shared.scheduleIndex(
                id: id,
                title: title,
                subjectName: subjectName,
                pageCount: pageCount,
                thumbnailData: thumbnailData,
                createdAt: createdAt,
                updatedAt: updatedAt,
                tags: tags
            )
        }
    }

    /// Re-write the App Group widget snapshot from the latest
    /// notebook list. Sort order is most-recently-OPENED first
    /// (via `RecentNotebooksTracker`) so the medium widget's
    /// "recents" rail mirrors what the user actually expects —
    /// the previous `updatedAt`-ordered snapshot ignored opens
    /// that didn't write strokes. Falls back to `updatedAt` for
    /// notebooks the tracker doesn't know about yet, then trims
    /// to ten so the widget's three-row consumer always has
    /// headroom for filters / deletions.
    ///
    /// Triggers `WidgetCenter.shared.reloadAllTimelines()`
    /// immediately after the write is scheduled so the widget
    /// re-renders within seconds rather than waiting up to 15
    /// minutes for the natural timeline refresh.
    func scheduleWidgetSnapshot() {
        let recentIds = RecentNotebooksTracker.recentIdsNewestFirst()
        let byRecentRank: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: recentIds.enumerated().map { ($0.element, $0.offset) }
        )
        let summaries: [NotebookSummary] = fetchAllNotebooks()
            .sorted { lhs, rhs in
                switch (byRecentRank[lhs.id], byRecentRank[rhs.id]) {
                case let (l?, r?):  return l < r
                case (_?, nil):     return true
                case (nil, _?):     return false
                case (nil, nil):    return lhs.updatedAt > rhs.updatedAt
                }
            }
            .prefix(10)
            .map { nb in
                NotebookSummary(
                    id:            nb.id,
                    title:         nb.title,
                    coverColorHex: nb.coverColorHex,
                    coverTexture:  nb.coverTexture.rawValue,
                    pageCount:     nb.totalPageCount,
                    updatedAt:     nb.updatedAt
                )
            }
        Task { await WidgetDataWriter.shared.scheduleWrite(summaries) }
        // Tell WidgetKit to re-fetch + redraw. The actual JSON
        // write is debounced inside `WidgetDataWriter`; the
        // reload is cheap and idempotent, so calling it before
        // the write completes is fine — when the widget re-fetches
        // (~1s later) the new snapshot is already on disk.
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - UIImage thumbnail helper

private extension UIImage {
    func thumbnailFitting(maxDimension: CGFloat) -> UIImage? {
        let ratio  = min(maxDimension / size.width, maxDimension / size.height)
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - DEBUG synthetic data
//
// Lives in this file so it can reach the private `context`. Compiled
// out of release builds entirely; the Settings entry point is itself
// `#if DEBUG`-gated.

#if DEBUG
extension StorageService {

    /// Generate `count` synthetic notebooks distributed across at
    /// least 5 subjects. Each notebook gets 1–30 pages, a random
    /// `createdAt` in the last 30 days, and a random `updatedAt` in
    /// the last 7 days, so library sort/grouping has realistic input.
    /// Bypasses the per-call save / Spotlight reindex / widget
    /// snapshot scheduling that `createNotebook(...)` performs —
    /// those overheads aren't part of what the perf test exercises.
    func generateSyntheticNotebooks(count: Int) throws {
        let subjectNames = ["University", "Personal", "Work", "Ideas", "Travel"]
        var subjects = fetchSubjects()
        let palette  = CeciliasNotesColorPresets.subjectColors

        while subjects.count < 5 {
            let idx = subjects.count
            let s = Subject(
                name:      subjectNames[idx],
                colorHex:  palette[idx % palette.count],
                sortOrder: idx
            )
            context.insert(s)
            subjects.append(s)
        }

        let now = Date()
        let day = TimeInterval(86_400)
        var usedTitles = Set(fetchAllNotebooks().map(\.title))

        for i in 0..<count {
            let subject = subjects[i % subjects.count]
            let base    = NotebookNameGenerator.names.randomElement() ?? "Synthetic"
            var title = "\(base) \(i + 1)"
            while usedTitles.contains(title) { title += "·" }
            usedTitles.insert(title)

            let createdAt = now.addingTimeInterval(-Double.random(in: 0...30 * day))
            let updatedAt = now.addingTimeInterval(-Double.random(in: 0...7 * day))
            let coverHex  = palette.randomElement() ?? "#FFFFFF"

            let nb = Notebook(
                title:           title,
                subjectId:       subject.id,
                coverColorHex:   coverHex,
                coverTexture:    .none,
                pageSize:        .a4,
                defaultTemplate: .blank
            )
            nb.createdAt = createdAt
            nb.updatedAt = updatedAt
            nb.sortOrder = ((subject.notebooks ?? []).last?.sortOrder ?? -1) + 1
            nb.subject   = subject

            context.insert(nb)
            subject.notebooks = (subject.notebooks ?? []) + [nb]

            let pageCount = Int.random(in: 1...30)
            for p in 0..<pageCount {
                let page = Page(
                    notebookId:         nb.id,
                    pageNumber:         p + 1,
                    pageSize:           .a4,
                    backgroundTemplate: .blank
                )
                page.notebook = nb
                context.insert(page)
                nb.pages = (nb.pages ?? []) + [page]
            }
            nb.totalPageCount = pageCount

            let tone = CoverToneAssigner.tone(in: subject)
            CoverToneStore.setTone(tone, for: nb.id)

            // Batch save — keeps memory steady at 1000-notebook scale.
            if i % 100 == 99 {
                try context.save()
            }
        }
        try context.save()
    }

    /// Hard wipe of every notebook and subject in the store. Intended
    /// for clearing synthetic data between perf runs — destructive
    /// enough that the Settings entry is labelled accordingly.
    func wipeAllSyntheticData() throws {
        for nb in fetchAllNotebooks() {
            context.delete(nb)
        }
        for s in fetchSubjects() {
            context.delete(s)
        }
        try context.save()
    }
}
#endif
