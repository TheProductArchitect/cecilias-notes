import Combine
import Foundation
import PencilKit
import SwiftData
import UIKit

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
    // The SwiftData store always lives in `inkDirectoryURL` (local Application
    // Support — never synced; performance + integrity reasons). Only file
    // assets (`media/`, `audio/`, `exports/`) follow `notebooksDirectoryURL`,
    // which is dynamic: iCloud ubiquity container when sync is enabled and
    // available, local Application Support otherwise.
    //
    // Toggling iCloud doesn't migrate the SQLite store; it only relocates the
    // Notebooks asset directory. CloudSyncManager.enable()/disable() perform
    // the move and flip the persisted flag.

    nonisolated static var inkDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ink")
    }

    /// Local-only path. Used as the source/destination during enable/disable
    /// migration and as the fallback when iCloud isn't available.
    nonisolated static var localNotebooksDirectoryURL: URL {
        inkDirectoryURL.appendingPathComponent("Notebooks")
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
    private let context: ModelContext

    /// Designated init — callers pass a container for testability.
    init(container: ModelContainer) {
        self.container = container
        self.context   = container.mainContext
        try? FileManager.default.createDirectory(
            at: Self.notebooksDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    /// Convenience init used by the singleton and InkApp. Container failure is
    /// genuinely terminal (no DB → no app), so we surface a precondition with a
    /// clear message rather than a bare `try!`.
    private convenience init() {
        do {
            let c = try ModelContainer.inkContainer()
            self.init(container: c)
        } catch {
            // Safe: SwiftData container init only fails when the on-disk SQLite
            // file is corrupt or Application Support is unwritable — unrecoverable
            // at startup. A descriptive crash is more useful than a zombie app.
            preconditionFailure( // Safe: terminal startup failure
                "Failed to open the Ink SwiftData container: \(error). "
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
            throw InkStorageError.fileWriteFailed(error)
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
        guard name.count <= 50 else { throw InkStorageError.fileSizeLimitExceeded }
        guard InkColorPresets.subjectColors.contains(colorHex) else {
            throw InkStorageError.fileWriteFailed(
                NSError(domain: "Ink", code: 1,
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
        let descriptor = FetchDescriptor<Subject>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func updateSubject(_ subject: Subject, name: String?, colorHex: String?) throws {
        if let name {
            guard name.count <= 50 else { throw InkStorageError.fileSizeLimitExceeded }
            subject.name = name
        }
        if let colorHex {
            guard InkColorPresets.subjectColors.contains(colorHex) else {
                throw InkStorageError.fileWriteFailed(
                    NSError(domain: "Ink", code: 1,
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
}

// MARK: - Folders

extension StorageService {

    /// Creates a folder under `subject`, optionally nested inside `parentFolderId`.
    /// Soft-deleted folders aren't fetched, so reusing a name across deletes is fine.
    func createFolder(name: String, in subject: Subject, parentFolderId: UUID? = nil) throws -> Folder {
        guard name.count <= 50 else { throw InkStorageError.fileSizeLimitExceeded }
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
            throw InkStorageError.fileSizeLimitExceeded
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
        guard title.count <= 80 else { throw InkStorageError.fileSizeLimitExceeded }

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
    /// (see the comment in `InkSchemas.swift`). The tracker survives
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
    /// migration risk.
    func markNotebookOpened(_ notebook: Notebook) {
        RecentNotebooksTracker.markOpened(notebook.id)
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
            guard title.count <= 80 else { throw InkStorageError.fileSizeLimitExceeded }
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

            for attachment in (page.mediaAttachments ?? []) where !attachment.isDeleted {
                let newAtt = MediaAttachment(
                    pageId: newPage.id,
                    notebookId: copy.id,
                    type: attachment.type,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType,
                    fileSizeBytes: attachment.fileSizeBytes,
                    originalWidth: attachment.originalWidth,
                    originalHeight: attachment.originalHeight,
                    x: attachment.x, y: attachment.y,
                    width: attachment.width, height: attachment.height
                )
                newAtt.rotation = attachment.rotation
                newAtt.zIndex   = attachment.zIndex
                newAtt.caption  = attachment.caption
                newAtt.page     = newPage
                context.insert(newAtt)
                newPage.mediaAttachments = (newPage.mediaAttachments ?? []) + [newAtt]

                try await copyFile(from: mediaURL(for: attachment), to: mediaURL(for: newAtt))
                try await copyFile(from: thumbnailURL(for: attachment), to: thumbnailURL(for: newAtt))
            }

            for annotation in (page.audioAnnotations ?? []) where !annotation.isDeleted {
                let newAnn = AudioAnnotation(
                    pageId: newPage.id,
                    notebookId: copy.id,
                    fileName: annotation.fileName,
                    durationSeconds: annotation.durationSeconds,
                    fileSizeBytes: annotation.fileSizeBytes,
                    pageX: annotation.pageX,
                    pageY: annotation.pageY
                )
                newAnn.transcription         = annotation.transcription
                newAnn.transcriptionSegments = annotation.transcriptionSegments
                newAnn.recordedAt            = annotation.recordedAt
                newAnn.page                  = newPage
                context.insert(newAnn)
                newPage.audioAnnotations = (newPage.audioAnnotations ?? []) + [newAnn]

                try await copyFile(from: audioURL(for: annotation), to: audioURL(for: newAnn))
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
            throw InkStorageError.fileWriteFailed(error)
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
            throw InkStorageError.notebookNotFound
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
            throw InkStorageError.notebookNotFound
        }
        let pages = fetchPages(in: notebook)
        guard targetPageNumber >= 1 && targetPageNumber <= pages.count else {
            throw InkStorageError.pageNumberInvalid
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
}

// MARK: - Media Attachments

extension StorageService {

    func addImage(
        to page: Page,
        imageData: Data,
        mimeType: String,
        at normalizedRect: CGRect
    ) async throws -> MediaAttachment {
        guard let image = UIImage(data: imageData) else {
            throw InkStorageError.fileWriteFailed(
                NSError(domain: "Ink", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot decode image data"])
            )
        }

        let attachment = MediaAttachment(
            pageId: page.id,
            notebookId: page.notebookId,
            type: .image,
            fileName: "\(UUID().uuidString).jpg",
            mimeType: mimeType,
            fileSizeBytes: Int64(imageData.count),
            originalWidth: Int(image.size.width),
            originalHeight: Int(image.size.height),
            x: normalizedRect.origin.x,
            y: normalizedRect.origin.y,
            width: normalizedRect.width,
            height: normalizedRect.height
        )

        let zMax = ((page.mediaAttachments ?? []).map(\.zIndex).max() ?? -1) + 1
        attachment.zIndex = zMax
        attachment.page   = page

        context.insert(attachment)
        page.mediaAttachments = (page.mediaAttachments ?? []) + [attachment]
        page.updatedAt = Date()

        // Write files on background task
        let mediaDestURL  = mediaURL(for: attachment)
        let thumbDestURL  = thumbnailURL(for: attachment)
        let notebookId    = page.notebookId

        Task.detached(priority: .utility) { [weak self] in
            guard self != nil else { return }
            let fm = FileManager.default
            let dir = StorageService.notebooksDirectoryURL
                .appendingPathComponent(notebookId.uuidString)
                .appendingPathComponent("media")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // Full resolution. NSFileCoordinator-wrapped when iCloud is enabled.
            if let jpeg = image.jpegData(compressionQuality: 0.90) {
                try? Self.writeFile(jpeg, to: mediaDestURL)
            }
            // Thumbnail — max 400×400pt, JPEG 75%.
            // thumbnailFitting is @MainActor-isolated (UIKit drawing).
            let thumbJpeg: Data? = await MainActor.run {
                image.thumbnailFitting(maxDimension: 400)?
                    .jpegData(compressionQuality: 0.75)
            }
            if let thumbJpeg {
                try? Self.writeFile(thumbJpeg, to: thumbDestURL)
            }
        }

        try context.save()
        return attachment
    }

    func updateAttachment(
        _ attachment: MediaAttachment,
        rect: CGRect?,
        rotation: Double?,
        caption: String?,
        opacity: Double? = nil
    ) throws {
        if let rect {
            attachment.x      = rect.origin.x
            attachment.y      = rect.origin.y
            attachment.width  = rect.width
            attachment.height = rect.height
        }
        if let rotation { attachment.rotation = rotation }
        if let caption  { attachment.caption  = caption  }
        if let opacity  { attachment.opacity  = max(0.2, min(1.0, opacity)) }
        attachment.updatedAt = Date()
        try context.save()
    }

    func updateAttachmentZIndex(_ attachment: MediaAttachment, zIndex: Int) throws {
        attachment.zIndex    = zIndex
        attachment.updatedAt = Date()
        try context.save()
    }

    /// Replaces the file data for a cropped image and updates dimensions.
    func replaceAttachmentImage(
        _ attachment: MediaAttachment,
        jpegData: Data,
        originalWidth: Int,
        originalHeight: Int
    ) throws {
        let destURL   = mediaURL(for: attachment)
        let thumbURL  = thumbnailURL(for: attachment)
        let notebookId = attachment.notebookId

        try Self.writeFile(jpegData, to: destURL)
        attachment.fileSizeBytes  = Int64(jpegData.count)
        attachment.originalWidth  = originalWidth
        attachment.originalHeight = originalHeight
        attachment.updatedAt = Date()
        try context.save()

        // Regenerate thumbnail off-thread (UIImage rendering hops to MainActor).
        Task.detached(priority: .utility) {
            guard let image = UIImage(data: jpegData) else { return }
            let thumbJpeg: Data? = await MainActor.run {
                image.thumbnailFitting(maxDimension: 400)?
                    .jpegData(compressionQuality: 0.75)
            }
            guard let thumbJpeg else { return }
            try? Self.writeFile(thumbJpeg, to: thumbURL)
        }
        _ = notebookId
    }

    /// Insert a pre-processed image (files already written to disk).
    func addPreprocessedImage(
        to page: Page,
        id: UUID,
        fileName: String,
        fileSizeBytes: Int64,
        originalWidth: Int,
        originalHeight: Int,
        at normalizedRect: CGRect
    ) throws -> MediaAttachment {
        let attachment = MediaAttachment(
            pageId: page.id,
            notebookId: page.notebookId,
            type: .image,
            fileName: fileName,
            mimeType: "image/jpeg",
            fileSizeBytes: fileSizeBytes,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            x: normalizedRect.origin.x,
            y: normalizedRect.origin.y,
            width: normalizedRect.width,
            height: normalizedRect.height
        )
        attachment.id     = id
        attachment.zIndex = ((page.mediaAttachments ?? []).map(\.zIndex).max() ?? -1) + 1
        attachment.page   = page
        context.insert(attachment)
        page.mediaAttachments = (page.mediaAttachments ?? []) + [attachment]
        page.updatedAt = Date()
        try context.save()
        return attachment
    }

    func deleteAttachment(_ attachment: MediaAttachment) throws {
        attachment.isDeleted = true
        attachment.deletedAt = Date()
        attachment.updatedAt = Date()
        try context.save()
        // Physical file removal deferred until "Empty Trash" or 30-day purge.
    }

    func restoreAttachment(_ attachment: MediaAttachment) throws {
        attachment.isDeleted = false
        attachment.deletedAt = nil
        attachment.updatedAt = Date()
        try context.save()
    }

    func mediaURL(for attachment: MediaAttachment) -> URL {
        mediaDir(attachment.notebookId)
            .appendingPathComponent(attachment.id.uuidString + ".jpg")
    }

    func thumbnailURL(for attachment: MediaAttachment) -> URL {
        mediaDir(attachment.notebookId)
            .appendingPathComponent(attachment.id.uuidString + "_thumb.jpg")
    }
}

// MARK: - Audio Annotations

extension StorageService {

    func addAudioAnnotation(
        to page: Page,
        fileName: String,
        duration: Double,
        at point: CGPoint
    ) throws -> AudioAnnotation {
        let annotation = AudioAnnotation(
            pageId: page.id,
            notebookId: page.notebookId,
            fileName: fileName,
            durationSeconds: duration,
            pageX: Double(point.x),
            pageY: Double(point.y)
        )
        annotation.page = page
        context.insert(annotation)
        page.audioAnnotations = (page.audioAnnotations ?? []) + [annotation]
        page.updatedAt = Date()
        try context.save()
        return annotation
    }

    func updateTranscription(
        _ annotation: AudioAnnotation,
        text: String,
        segments: [TranscriptionSegment]
    ) throws {
        annotation.transcription         = text
        annotation.transcriptionSegments = try? JSONEncoder().encode(segments)
        annotation.isTranscribed         = true
        annotation.updatedAt             = Date()
        try context.save()
    }

    func deleteAudioAnnotation(_ annotation: AudioAnnotation) throws {
        annotation.isDeleted = true
        annotation.deletedAt = Date()
        annotation.updatedAt = Date()
        try context.save()
    }

    func audioURL(for annotation: AudioAnnotation) -> URL {
        audioDir(annotation.notebookId)
            .appendingPathComponent(annotation.id.uuidString + ".m4a")
    }

    /// Called by `AudioFilePicker` after the file is already copied to the audio directory.
    func insertAudioFile(
        to page: Page,
        annotationId: UUID,
        fileName: String,
        duration: Double,
        fileSizeBytes: Int64,
        at point: CGPoint
    ) throws -> AudioAnnotation {
        let annotation = AudioAnnotation(
            id:              annotationId,
            pageId:          page.id,
            notebookId:      page.notebookId,
            fileName:        fileName,
            durationSeconds: duration,
            fileSizeBytes:   fileSizeBytes,
            pageX:           Double(point.x),
            pageY:           Double(point.y)
        )
        annotation.page = page
        context.insert(annotation)
        page.audioAnnotations = (page.audioAnnotations ?? []) + [annotation]
        page.updatedAt = Date()
        try context.save()
        return annotation
    }

    /// Writes pre-computed amplitude data (archived [Float]) for static waveform rendering.
    func updateAmplitudeData(_ annotation: AudioAnnotation, amplitudeData: Data?) throws {
        annotation.amplitudeData = amplitudeData
        annotation.updatedAt     = Date()
        try context.save()
    }

    func fetchAudioAnnotation(id: UUID) -> AudioAnnotation? {
        var descriptor = FetchDescriptor<AudioAnnotation>(
            predicate: #Predicate { $0.id == id && $0.isDeleted == false }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Moves a pin to a new normalised position.
    func moveAudioAnnotation(_ annotation: AudioAnnotation, to point: CGPoint) throws {
        annotation.pageX     = Double(point.x)
        annotation.pageY     = Double(point.y)
        annotation.updatedAt = Date()
        try context.save()
    }

}

// MARK: - Audio directory (public for AudioFilePicker)

extension StorageService {
    /// Returns the audio directory URL for a given notebook.
    func audioDirURL(notebookId: UUID) -> URL {
        Self.notebooksDirectoryURL
            .appendingPathComponent(notebookId.uuidString)
            .appendingPathComponent("audio")
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

        // Audio transcriptions
        let annotations = (try? context.fetch(
            FetchDescriptor<AudioAnnotation>(predicate: #Predicate { $0.isDeleted == false })
        )) ?? []
        for ann in annotations {
            guard let text = ann.transcription, text.lowercased().contains(q),
                  let nbId = pageToNotebook[ann.pageId] else { continue }
            results.append(SearchResult(
                notebookId: nbId,
                pageId: ann.pageId,
                context: String(text.prefix(120)),
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

        let dbURL   = Self.inkDirectoryURL.appendingPathComponent("ink.sqlite")
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
                throw InkStorageError.fileWriteFailed(error)
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
                throw InkStorageError.fileWriteFailed(error)
            }
        }
        // Soft-delete all AudioAnnotation records
        let descriptor = FetchDescriptor<AudioAnnotation>(
            predicate: #Predicate { $0.isDeleted == false }
        )
        let annotations = (try? context.fetch(descriptor)) ?? []
        let now = Date()
        for ann in annotations {
            ann.isDeleted = true
            ann.deletedAt = now
            ann.updatedAt = now
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
        // Image attachments — the store also removes the on-disk
        // image files under `Documents/media/<notebookId>/` so the
        // reaper-purge sweep doesn't leave orphaned pixels behind.
        MediaAttachmentStore.forget(pageIds: pageIds)
        // Belt-and-braces: drop the per-notebook media directory
        // wholesale in case any files lingered (e.g. records that
        // failed to persist). Safe to remove a non-existent path.
        try? FileManager.default.removeItem(
            at: MediaAttachmentStore.mediaDirectory(for: notebook.id)
        )
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

    /// Re-write the App Group widget snapshot from the latest notebook list.
    /// Debounced through `WidgetDataWriter`.
    func scheduleWidgetSnapshot() {
        let summaries: [NotebookSummary] = fetchNotebooks(subjectId: nil)
            .sorted { $0.updatedAt > $1.updatedAt }
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
        let palette  = InkColorPresets.subjectColors

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
