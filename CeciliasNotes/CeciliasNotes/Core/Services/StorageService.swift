import Combine
import Foundation
import PencilKit
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

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
            .appendingPathComponent("CeciliasNotes")
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
    /// Persisted-flag key is `ceciliasnotes.icloud.sync.enabled` (owned by CloudSyncManager).
    nonisolated static var notebooksDirectoryURL: URL {
        let enabled = UserDefaults.standard.bool(forKey: "ceciliasnotes.icloud.sync.enabled")
        if enabled,
           let icloudRoot = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/Notebooks") {
            return icloudRoot
        }
        return localNotebooksDirectoryURL
    }

    nonisolated static var globalExportsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CeciliasNotes")
            .appendingPathComponent("Exports")
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

    /// Timestamp of the launch-time purge + reconcile in `init()`.
    /// Foreground duplicate sweeps skip `reconcileSoftDeleteFlags`
    /// for 60s after this to avoid doubling the work on every
    /// `LibraryView.onAppear` / scene-active transition.
    nonisolated(unsafe) static var launchHygieneCompletedAt: Date?

    /// Convenience init used by the singleton and CeciliasNotesApp. Container failure is
    /// genuinely terminal (no DB → no app), so we surface a precondition with a
    /// clear message rather than a bare `try!`.
    private convenience init() {
        do {
            let c = try ModelContainer.ceciliasNotesContainer()
            self.init(container: c)
            // Duplicate purge must finish before `LibraryViewModel.init`
            // → `refresh()` — lists use `dedupedById` as belt-and-
            // suspenders, but Dictionary(uniqueKeysWithValues:) in
            // mutation paths still traps on duplicate keys.
            purgeDuplicateRows()
            Self.launchHygieneCompletedAt = Date()
            // Full-table soft-delete reconcile is deferred so a large
            // library cannot block the first interactive frame after
            // relaunch. Foreground sweeps skip reconcile for 60s
            // after `launchHygieneCompletedAt`.
            Task { @MainActor in
                reconcileSoftDeleteFlags()
            }
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
        if dirty {
            do {
                try context.save()
            } catch {
                #if DEBUG
                dlog("[Storage] pageCountBackfill SAVE FAILED: \(error)")
                #endif
            }
        }

        defaults.set(true, forKey: Self.pageCountBackfillKey)
    }

    // MARK: - Duplicate-row cleanup

    /// CloudKit echo + stale-local-replica bugs occasionally leave
    /// SwiftData with two (or more) rows sharing the same primary
    /// key. iOS 26 SwiftUI's `ForEach` now hard-crashes on this with
    /// `NativeDictionary.swift:792: Fatal error: Duplicate values
    /// for key`, so any view that iterates a duplicated table —
    /// the library grid, the editor's per-page element overlays,
    /// the page strip — refuses to mount.
    ///
    /// This sweep runs on every launch (cheap: one fetch + a Set
    /// per entity). For each duplicate group we keep the row with
    /// the latest `updatedAt` and hard-delete the others. The
    /// deletes cascade through the SwiftData relationships, so a
    /// duplicate Notebook row also drops its duplicate Page rows,
    /// duplicate Pages drop their PageElements, etc.
    func purgeDuplicateRows() {
        var purgedContainers = 0
        var purgedElements = 0
        purgedContainers += purgeDuplicates(
            type: Notebook.self,
            keyedBy: { $0.id },
            updatedAt: { $0.updatedAt },
            isTombstone: { $0.isDeleted || $0.deletedAt != nil }
        )
        purgedContainers += purgeDuplicates(
            type: Page.self,
            keyedBy: { $0.id },
            updatedAt: { $0.updatedAt },
            isTombstone: { $0.isDeleted || $0.deletedAt != nil }
        )
        purgedElements += purgeDuplicates(
            type: PageElement.self,
            keyedBy: { $0.id },
            updatedAt: { $0.updatedAt },
            isTombstone: { $0.deletedAt != nil }
        )
        purgedContainers += purgeDuplicates(
            type: Subject.self,
            keyedBy: { $0.id },
            updatedAt: { $0.updatedAt },
            isTombstone: { $0.isDeleted || $0.deletedAt != nil }
        )
        purgedContainers += purgeDuplicates(
            type: Folder.self,
            keyedBy: { $0.id },
            updatedAt: { $0.updatedAt },
            isTombstone: { $0.isDeleted || $0.deletedAt != nil }
        )
        guard purgedContainers + purgedElements > 0 else { return }
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[Storage] purgeDuplicateRows SAVE FAILED: \(error)")
            #endif
        }

        // The element overlays fetch manually (not @Query), so a
        // purge that deletes rows MUST tell them to re-fetch. Without
        // this, an overlay keeps rendering the deleted PageElement
        // instance it fetched moments earlier, and the next property
        // access on a deleted SwiftData model traps. The window this
        // closes is real on device: the debounced sweep fires ~2 s
        // after any save burst — e.g. right after a dictation stops
        // and its finalize/structure/summary saves land — which is
        // exactly when duplicate rows from CloudKit echoes exist.
        if purgedElements > 0 || purgedContainers > 0 {
            NotificationCenter.default.post(name: .textElementsChanged, object: nil)
            NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
            NotificationCenter.default.post(name: .shapeElementsChanged, object: nil)
            #if canImport(UIKit)
            // Declared in iOS-only overlay files; the Mac editor
            // redraws off .textElementsChanged alone.
            NotificationCenter.default.post(name: .stickyNotesChanged, object: nil)
            NotificationCenter.default.post(name: .pdfPageElementsChanged, object: nil)
            NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
            #endif
        }
    }

    /// Launch-time soft-delete reconciliation. CloudKit's per-property
    /// merge policy has been observed to revive `isDeleted = false`
    /// on a subject (or notebook) while leaving `deletedAt` still
    /// stamped from the local delete — a "ghost" state that lets the
    /// row reappear in the UI even though the user deleted it. The
    /// sweep below restores the invariant in both directions:
    ///
    ///   • `isDeleted == true` + `deletedAt == nil` → stamp deletedAt
    ///     so future filters that key on either field stay consistent.
    ///   • `deletedAt != nil` + `isDeleted == false` → flip isDeleted
    ///     back to true. The remote echo is wrong; the user already
    ///     said delete.
    ///
    /// Called immediately after `purgeDuplicateRows` so the dedupe
    /// pass runs against a consistent view of soft-delete state.
    /// Rows this session has already auto-fixed once. A row that
    /// shows up needing the SAME fix again means something is
    /// actively reverting it — re-fixing forever produced an
    /// infinite churn loop on device (each fix saves → the save
    /// posts NSPersistentStoreRemoteChange → the sweep reschedules
    /// → fix again, every 2 s for the whole session). One fix per
    /// row per launch converges; the repeat case logs loudly once
    /// so the true reverter can be found instead of masked.
    private var softDeleteReconciledOnce: Set<UUID> = []
    private var softDeleteRevertWarned: Set<UUID> = []

    func reconcileSoftDeleteFlags() {
        var dirty = false

        func fixOnce(_ id: UUID, _ apply: () -> Void, what: String) {
            if softDeleteReconciledOnce.contains(id) {
                if !softDeleteRevertWarned.contains(id) {
                    softDeleteRevertWarned.insert(id)
                    #if DEBUG
                    dlog("[Storage] reconcileSoftDelete \(what) id=\(id) REVERTED after an earlier fix this session — leaving it alone; find what is un-deleting this row")
                    #endif
                }
                return
            }
            softDeleteReconciledOnce.insert(id)
            apply()
            dirty = true
        }

        // Fetch ONLY the mismatched rows. This sweep used to fetch
        // every Subject and Notebook and filter in Swift — with a
        // large library that materialized whole tables on the main
        // actor 2 s after every save burst, a steady ANR tax. The
        // predicates below hit SQLite indices; in the healthy case
        // (no mismatches) all four fetches return empty and no row
        // is materialized at all.
        let staleSubjectStamp = FetchDescriptor<Subject>(
            predicate: #Predicate { $0.isDeleted == true && $0.deletedAt == nil }
        )
        for s in (try? context.fetch(staleSubjectStamp)) ?? [] {
            fixOnce(s.id, {
                s.deletedAt = Date()
                #if DEBUG
                dlog("[Storage] reconcileSoftDelete subject id=\(s.id) — stamped missing deletedAt")
                #endif
            }, what: "subject")
        }
        let revivedSubjects = FetchDescriptor<Subject>(
            predicate: #Predicate { $0.isDeleted == false && $0.deletedAt != nil }
        )
        for s in (try? context.fetch(revivedSubjects)) ?? [] {
            fixOnce(s.id, {
                s.isDeleted = true
                s.updatedAt = Date()
                #if DEBUG
                dlog("[Storage] reconcileSoftDelete subject id=\(s.id) — restored isDeleted (CloudKit echo)")
                #endif
            }, what: "subject")
        }
        let staleNotebookStamp = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isDeleted == true && $0.deletedAt == nil }
        )
        for n in (try? context.fetch(staleNotebookStamp)) ?? [] {
            fixOnce(n.id, { n.deletedAt = Date() }, what: "notebook")
        }
        let revivedNotebooks = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isDeleted == false && $0.deletedAt != nil }
        )
        for n in (try? context.fetch(revivedNotebooks)) ?? [] {
            fixOnce(n.id, {
                n.isDeleted = true
                n.updatedAt = Date()
                #if DEBUG
                dlog("[Storage] reconcileSoftDelete notebook id=\(n.id) — restored isDeleted (CloudKit echo)")
                #endif
            }, what: "notebook")
        }
        guard dirty else { return }
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[Storage] reconcileSoftDeleteFlags SAVE FAILED: \(error)")
            #endif
        }
    }

    /// Returns the number of stale rows deleted so the caller can
    /// decide whether views need a re-fetch nudge.
    @discardableResult
    private func purgeDuplicates<Model: PersistentModel>(
        type: Model.Type,
        keyedBy key: (Model) -> UUID,
        updatedAt: (Model) -> Date,
        isTombstone: ((Model) -> Bool)? = nil
    ) -> Int {
        let descriptor = FetchDescriptor<Model>()
        guard let rows = try? context.fetch(descriptor) else { return 0 }
        let grouped = Dictionary(grouping: rows, by: key)
        var purged = 0
        for (_, copies) in grouped where copies.count > 1 {
            // Prefer the tombstoned row when CloudKit echoes a fresher
            // non-deleted shadow — newest-wins alone resurrects deletes.
            // Among equals, keep the row with the latest `updatedAt`.
            let sorted = copies.sorted { a, b in
                let aTomb = isTombstone?(a) ?? false
                let bTomb = isTombstone?(b) ?? false
                if aTomb != bTomb { return aTomb && !bTomb }
                return updatedAt(a) > updatedAt(b)
            }
            for stale in sorted.dropFirst() {
                context.delete(stale)
                purged += 1
            }
            #if DEBUG
            dlog("[Storage] purged \(copies.count - 1) duplicate(s) of \(type) id=\(key(copies[0]))")
            #endif
        }
        return purged
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

    /// Soft-deletes the subject. When `moveNotebooksToUnfiled` is true,
    /// live notebooks are moved into the canonical Unfiled subject
    /// instead of being soft-deleted with the subject.
    func deleteSubject(_ subject: Subject, moveNotebooksToUnfiled: Bool = false) throws {
        if moveNotebooksToUnfiled {
            let unfiledId = try unfiledSubjectId()
            for notebook in (subject.notebooks ?? []) where !notebook.isDeleted {
                try moveNotebook(notebook, to: unfiledId)
            }
        } else {
            for notebook in (subject.notebooks ?? []) where !notebook.isDeleted {
                notebook.isDeleted = true
                notebook.deletedAt = Date()
                notebook.markModified()
            }
        }
        subject.isDeleted = true
        subject.deletedAt = Date()
        subject.updatedAt = Date()
        try context.save()
    }

    /// Finds or creates the canonical "Unfiled" subject used by quick
    /// capture and subject-delete reassignment.
    func unfiledSubjectId() throws -> UUID {
        let descriptor = FetchDescriptor<Subject>(
            predicate: #Predicate { $0.isDeleted == false }
        )
        let subjects = try context.fetch(descriptor)
        if let unfiled = subjects.first(where: { $0.name.lowercased() == "unfiled" }) {
            return unfiled.id
        }
        let subject = Subject(
            name: "Unfiled",
            colorHex: CeciliasNotesColorPresets.subjectColors.first ?? "#7F7F7F",
            sortOrder: subjects.count
        )
        context.insert(subject)
        try context.save()
        return subject.id
    }

    /// Notebook ids that contain at least one audio page element.
    func notebookIdsContainingAudio() -> Set<UUID> {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        return Set(elements.lazy.filter { $0.kind == .audio }.map(\.notebookId))
    }

    /// Count of non-deleted notebooks in a subject. Drives the
    /// delete-subject confirmation alert so the user sees the blast
    /// radius before tapping Delete.
    func liveNotebookCount(in subject: Subject) -> Int {
        (subject.notebooks ?? []).filter { !$0.isDeleted }.count
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
            notebook.markModified()
        }
        try context.save()
    }
}

// MARK: - Full reset

extension StorageService {

    /// Release-safe destructive wipe. Hard-deletes every row in
    /// every user-visible model so CloudKit propagates the deletes
    /// to the user's iCloud account. Without this, "delete all in
    /// the app + reinstall" leaves the user staring at the old data
    /// — Apple's CloudKit preserves records across reinstalls
    /// because the data lives in the iCloud account, not the app
    /// sandbox.
    ///
    /// SwiftData's cascade delete rules handle child rows
    /// (`PageElement` → `StrokeContent`/etc., `Quiz` → questions /
    /// attempts), so we only need to delete the top-level entities.
    /// Audio + image attachments on disk are wiped alongside so the
    /// device's local Documents tree doesn't keep orphaned media.
    func resetAllUserData() async throws {
        // Top-level model deletes. SwiftData cascades to children
        // via the `inverse:` rules declared on each entity.
        for notebook in fetchAllNotebooks() {
            context.delete(notebook)
        }
        for subject in fetchSubjects() {
            context.delete(subject)
        }
        let quizDescriptor = FetchDescriptor<Quiz>()
        for quiz in (try? context.fetch(quizDescriptor)) ?? [] {
            context.delete(quiz)
        }
        try context.save()

        // Sweep the local media + audio caches. Failures are
        // logged but non-fatal — the SwiftData wipe above already
        // dropped the rows that referenced them.
        let fm = FileManager.default
        let docs = (try? fm.url(for: .documentDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: false)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        for sub in ["MediaAttachments", "Recordings", "Notebooks"] {
            let target = docs.appendingPathComponent(sub, isDirectory: true)
            try? fm.removeItem(at: target)
        }
        NotificationCenter.default.post(name: .userDataReset, object: nil)
    }
}

extension Notification.Name {
    /// Posted after the user confirms Settings → Reset iCloud Data
    /// so library / cloud sync views can drop caches and refresh.
    static let userDataReset = Notification.Name("ceciliasnotes.userDataReset")
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
            nb.folderId = folder.parentFolderId
            nb.markModified()
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
        notebook.markModified()
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

        // Every notebook must live in a subject — nil callers fall
        // through to the first available subject, or an auto-created
        // "Imports" bucket when no subjects exist yet. The user can
        // move the notebook elsewhere afterwards.
        let resolvedSubjectId: UUID = try {
            if let supplied = subjectId { return supplied }
            let active = fetchSubjects()
            if let first = active.first { return first.id }
            let imports = Subject(
                name: "Imports",
                colorHex: CeciliasNotesColorPresets.subjectColors.first ?? "#7F7F7F",
                sortOrder: 0
            )
            context.insert(imports)
            try context.save()
            return imports.id
        }()

        let notebook = Notebook(
            title: title,
            subjectId: resolvedSubjectId,
            coverColorHex: coverColorHex,
            coverTexture: coverTexture,
            pageSize: pageSize,
            defaultTemplate: template
        )
        let nextOrder = (fetchNotebooks(subjectId: resolvedSubjectId).map(\.sortOrder).max() ?? -1) + 1
        notebook.sortOrder = nextOrder
        context.insert(notebook)

        // Link to subject relationship and pick a cover tone from the
        // subject's rotation. Computed *before* we insert into the
        // relationship so `existingNotebooks` doesn't already include
        // this row.
        do {
            let subjectId = resolvedSubjectId
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
        NotebookOriginRecorder.stampCreation(on: notebook)

        try context.save()
        try ensureDir(notebookDir(notebook.id))
        scheduleSpotlightReindex(for: notebook)
        scheduleWidgetSnapshot()
        CeciliasNotesExporter.shared.export(notebook)
        MultipeerNotebookHint.broadcastNotebookChanged(notebookId: notebook.id)
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
            predicate: #Predicate {
                $0.isDeleted == false && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchPinnedNotebooks() -> [Notebook] {
        var descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isPinned == true && $0.isDeleted == false },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        // Cap the fetch — the library sidebar surfaces a small
        // strip of pins, not the whole pile. At library-scale this
        // also prevents the descriptor from materialising every
        // pinned row when only the head matters.
        descriptor.fetchLimit = 50
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

        // Predicate-filter directly on the tracked id set instead of
        // pulling every live notebook into memory and post-filtering.
        // The tracker keeps at most 50 entries, so this materialises
        // ~50 rows at most regardless of library size — the previous
        // approach was a full-table scan that dominated subject-swap
        // refresh time at 1000-notebook scale.
        let idSet = Set(recentIds)
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { !$0.isDeleted && idSet.contains($0.id) }
        )
        let matched = (try? context.fetch(descriptor)) ?? []
        let byId = Dictionary(
            matched.map { ($0.id, $0) },
            uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 }
        )

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
        notebook.markModified()
        try context.save()
        scheduleSpotlightReindex(for: notebook)
        scheduleWidgetSnapshot()
        CeciliasNotesExporter.shared.export(notebook)
        MultipeerNotebookHint.broadcastNotebookChanged(notebookId: notebook.id)
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
        notebook.markModified()

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
        notebook.markModified()
        try context.save()
        let id = notebook.id
        // Drop the in-memory search entry immediately; SpotlightService
        // is hit inside removeNotebook(id:) too, so this also clears
        // the OS-level Spotlight donation without a duplicate call.
        SearchIndexService.shared.removeNotebook(id: id)
        scheduleWidgetSnapshot()
        CeciliasNotesExporter.shared.removeExport(for: id)
        MultipeerNotebookHint.broadcastNotebookChanged(notebookId: id)
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
        NotebookOriginRecorder.stampCreation(on: copy)
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
            newPage.notebook = copy
            context.insert(newPage)
            copy.pages = (copy.pages ?? []) + [newPage]
            // Step 8: clone the stroke singleton instead of copying
            // the retired `Page.strokeData` field.
            cloneStrokeContent(fromPageId: page.id, toPage: newPage)

            for block in (page.textBlocks ?? []) where !block.isDeleted && block.deletedAt == nil {
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

            cloneV6PageElements(fromPageId: page.id, toPage: newPage, notebookId: copy.id)
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
            notebook.markModified()
        }
        try context.save()
    }

    func updateThumbnail(for notebook: Notebook, image: PlatformImage) throws {
        guard let data = PlatformImageFactory.jpegData(from: image, compressionQuality: 0.80) else { return }
        notebook.thumbnailData = data
        notebook.markModified()
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
        notebook.markModified()
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
        // Synchronous variant — encodes on the calling (main)
        // thread. Reserved for teardown/dismiss flushes that need
        // durability before the editor deallocates. Scroll- and
        // draw-time saves go through `updatePageStrokes(_:strokeData:)`
        // with the encode done off-main (`EditorViewModel.savePageAsync`).
        // Write-through to the in-memory cache so the next canvas
        // mount on this page hits without re-decoding from SwiftData.
        StrokeCache.shared.cache(drawing, forPage: page.id)
        try updatePageStrokes(page, strokeData: drawing.dataRepresentation())
    }

    func updatePageStrokes(_ page: Page, strokeData data: Data) throws {
        // Step 8: writes flow through V6
        // `PageElement(.stroke) + StrokeContent`. The Page-level
        // `strokeData` / `strokeDataSize` fields are gone; this
        // helper preserves its API so every caller
        // (`EditorViewModel.savePage`, `performSave`, page-unmount
        // flush) keeps working unchanged.
        guard let pair = StrokeCommit.ensureStrokeElement(
            forPageId:  page.id,
            notebookId: page.notebookId,
            context:    context
        ) else {
            throw CeciliasNotesStorageError.fileWriteFailed(
                NSError(
                    domain: "CeciliasNotes",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "stroke element seed failed"]
                )
            )
        }
        pair.content.strokeData = data
        pair.content.updatedAt  = Date()
        pair.element.updatedAt  = Date()
        page.updatedAt = Date()
        // Bump the parent notebook so Library, widget, and origin reflect activity.
        if let nb = notebookById(page.notebookId) {
            nb.markModified()
            scheduleSpotlightReindex(for: nb)
        }
        try context.save()
        scheduleWidgetSnapshot()
    }

    func cloneStrokeContent(fromPageId source: UUID, toPage destination: Page) {
        guard let sourceElement = StrokeCommit.strokeElement(
            forPageId: source,
            context:   context
        ),
        let sourceContent = sourceElement.strokeContent,
        !sourceContent.strokeData.isEmpty
        else { return }

        guard let pair = StrokeCommit.ensureStrokeElement(
            forPageId:  destination.id,
            notebookId: destination.notebookId,
            context:    context
        ) else { return }
        pair.content.strokeData = sourceContent.strokeData
        pair.content.toolKind   = sourceContent.toolKind
        pair.content.updatedAt  = Date()
        pair.element.updatedAt  = Date()
    }

    /// Clone V6 page elements when duplicating a whole notebook.
    /// Skips strokes (handled by `cloneStrokeContent`) and PDF
    /// highlights (re-anchor is non-trivial).
    func cloneV6PageElements(fromPageId sourcePageId: UUID, toPage destination: Page, notebookId: UUID) {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == sourcePageId && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.zIndex)]
        )
        guard let sourceElements = try? context.fetch(descriptor) else { return }

        for source in sourceElements {
            switch source.kind {
            case .stroke, .pdfPage, .highlight:
                continue
            case .text:
                guard let sc = source.textContent else { continue }
                let element = PageElement(
                    pageId: destination.id,
                    notebookId: notebookId,
                    kind: .text,
                    normalizedX: source.normalizedX,
                    normalizedY: source.normalizedY,
                    normalizedWidth: source.normalizedWidth,
                    normalizedHeight: source.normalizedHeight,
                    zIndex: source.zIndex
                )
                element.rotation = source.rotation
                element.opacity = source.opacity
                let content = TextContent(
                    text: sc.text,
                    source: sc.source,
                    size: sc.size,
                    anchorAudioId: sc.anchorAudioId,
                    attributedTextData: sc.attributedTextData
                )
                content.element = element
                element.textContent = content
                context.insert(element)
            case .stickyNote:
                guard let sc = source.stickyNoteContent else { continue }
                let element = PageElement(
                    pageId: destination.id,
                    notebookId: notebookId,
                    kind: .stickyNote,
                    normalizedX: source.normalizedX,
                    normalizedY: source.normalizedY,
                    normalizedWidth: source.normalizedWidth,
                    normalizedHeight: source.normalizedHeight,
                    zIndex: source.zIndex
                )
                element.rotation = source.rotation
                let content = StickyNoteContent(text: sc.text, colorVariant: sc.colorVariant)
                content.element = element
                element.stickyNoteContent = content
                context.insert(element)
            case .shape:
                guard let sc = source.shapeContent else { continue }
                let element = PageElement(
                    pageId: destination.id,
                    notebookId: notebookId,
                    kind: .shape,
                    normalizedX: source.normalizedX,
                    normalizedY: source.normalizedY,
                    normalizedWidth: source.normalizedWidth,
                    normalizedHeight: source.normalizedHeight,
                    zIndex: source.zIndex
                )
                element.rotation = source.rotation
                let content = ShapeContent(
                    shapeKind: sc.shapeKind,
                    strokeColorHex: sc.strokeColorHex,
                    strokeWidth: sc.strokeWidth,
                    strokeStyle: sc.strokeStyle
                )
                content.element = element
                element.shapeContent = content
                context.insert(element)
            case .image:
                guard let sc = source.imageContent else { continue }
                let newImageId = UUID()
                let element = PageElement(
                    pageId: destination.id,
                    notebookId: notebookId,
                    kind: .image,
                    normalizedX: source.normalizedX,
                    normalizedY: source.normalizedY,
                    normalizedWidth: source.normalizedWidth,
                    normalizedHeight: source.normalizedHeight,
                    zIndex: source.zIndex
                )
                element.rotation = source.rotation
                let content = ImageContent(
                    id: newImageId,
                    filename: "\(newImageId.uuidString).\(sc.fileFormat)",
                    fileFormat: sc.fileFormat,
                    originalPixelWidth: sc.originalPixelWidth,
                    originalPixelHeight: sc.originalPixelHeight,
                    imageData: sc.imageData
                )
                content.element = element
                element.imageContent = content
                context.insert(element)
                if let data = sc.imageData {
                    let url = MediaStorage.url(for: .images, id: newImageId, fileExtension: sc.fileFormat)
                    try? data.write(to: url, options: .atomic)
                } else {
                    let src = sc.fileURL
                    let dst = MediaStorage.url(for: .images, id: newImageId, fileExtension: sc.fileFormat)
                    if FileManager.default.fileExists(atPath: src.path) {
                        try? FileManager.default.copyItem(at: src, to: dst)
                    }
                }
            case .audio:
                guard let sc = source.audioContent else { continue }
                let newAudioId = UUID()
                let element = PageElement(
                    pageId: destination.id,
                    notebookId: notebookId,
                    kind: .audio,
                    normalizedX: source.normalizedX,
                    normalizedY: source.normalizedY,
                    normalizedWidth: source.normalizedWidth,
                    normalizedHeight: source.normalizedHeight,
                    zIndex: source.zIndex
                )
                element.rotation = source.rotation
                let content = AudioContent(
                    id: newAudioId,
                    filename: "\(newAudioId.uuidString).m4a",
                    durationSeconds: sc.durationSeconds,
                    transcript: sc.transcript,
                    timingMapData: sc.timingMapData,
                    audioData: sc.audioData
                )
                content.element = element
                element.audioContent = content
                context.insert(element)
                let src = sc.resolvedFileURL() ?? sc.fileURL
                let dst = MediaStorage.url(for: .audio, id: newAudioId)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
            }
        }
    }

    /// Read the active stroke blob for a page, or `nil` if the
    /// page has no strokes yet (no `PageElement(.stroke)` exists,
    /// or it exists with an empty `StrokeContent.strokeData`).
    /// Step 8 read-side abstraction over the migrated storage —
    /// every consumer (SearchIndexService OCR, ExportService PDF
    /// render, PageThumbnailCache fingerprint, ContinuousCanvasView
    /// mount) calls this instead of the retired `page.strokeData`.
    /// Cheap synchronous fetch; can be called on the main actor
    /// without blocking.
    func strokeData(for page: Page) -> Data? {
        guard let element = StrokeCommit.strokeElement(
            forPageId: page.id,
            context:   context
        ),
        let content = element.strokeContent
        else { return nil }
        let data = content.strokeData
        return data.isEmpty ? nil : data
    }

    /// Soft-deletes the page and renumbers all subsequent pages in the notebook.
    func deletePage(_ page: Page) throws {
        let notebookId  = page.notebookId
        let deletedNum  = page.pageNumber

        // Step 8: drop the page's stroke cache entry so a
        // subsequent re-create-at-same-id (or stale fetch) doesn't
        // resurrect the deleted drawing.
        StrokeCache.shared.invalidate(pageId: page.id)

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
            nb.markModified()
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
        newPage.notebook = notebook
        context.insert(newPage)
        notebook.pages = (notebook.pages ?? []) + [newPage]
        // Step 8: clone the stroke singleton from the source page
        // into the duplicate, replacing the retired `Page.strokeData`
        // direct copy.
        cloneStrokeContent(fromPageId: page.id, toPage: newPage)

        // Same `deletedAt` guard as `copyNotebook`'s block clone —
        // the `isDeleted` flag alone never reads true at runtime
        // (NSManagedObject name collision).
        for block in (page.textBlocks ?? []) where !block.isDeleted && block.deletedAt == nil {
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
        notebook.markModified()
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
        // `requiringSecureCoding: true` silences the
        // "NSKeyedUnarchiveFromData should not be used" deprecation
        // warning the OS emits when an archive's secure-coding flag
        // doesn't match the reader's. NSAttributedString conforms
        // to NSSecureCoding so the archive format is unchanged; the
        // flag only controls extra metadata used by secure decoders.
        block.richTextData = try NSKeyedArchiver.archivedData(
            withRootObject: richText,
            requiringSecureCoding: true
        )
        if let rect {
            block.x      = rect.origin.x
            block.y      = rect.origin.y
            block.width  = rect.width
            block.height = rect.height
        }
        block.updatedAt = Date()
        // User-edit on the legacy text-block path → mirror must
        // reflect the new text rather than the inkbook stash.
        Page.clearInkbookStash(forPageId: block.pageId, context: context)
        let pageId = block.pageId
        let pageDescriptor = FetchDescriptor<Page>(
            predicate: #Predicate { $0.id == pageId }
        )
        if let page = try? context.fetch(pageDescriptor).first {
            page.updatedAt = Date()
            if let nb = notebookById(page.notebookId) {
                nb.markModified()
            }
        }
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
        // Adding a new text block to an inkbook-origin page is a
        // user edit too — invalidate the stash so the mirror shows
        // the combined live content.
        Page.clearInkbookStash(forPageId: page.id, context: context)
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
        // Same invalidation reasoning as the sibling overload.
        Page.clearInkbookStash(forPageId: page.id, context: context)
        try context.save()
        return block
    }
}

// MARK: - Audio elements (V6)
//
// Step 5: `AudioRecord` + `LectureRecord` entities were retired in
// favour of `PageElement(kind: .audio) + AudioContent`. The legacy
// `addAudioRecord` / `updateTranscription` / `updateAmplitudes` /
// `deleteAudioRecord` / `insertAudioFile` / `fetchAudioRecord` /
// `fetchAudioRecords` / `moveAudioRecord` / `audioURL(for:)`
// helpers all went away — call sites now talk to
// `AudioElementCommit` (writes) and read directly from SwiftData
// via the per-page overlay's fetch descriptor (reads).

extension StorageService {

    /// V6 helper for consumers that need every active audio element
    /// for a given page (SearchIndexService transcript ingest,
    /// ExportService PDF render). Filters `kind == .audio` post-
    /// fetch in Swift because `#Predicate` on iOS 26 rejects
    /// enum-case equality inside key-path comparisons.
    func fetchAudioElements(forPageId pageId: UUID) -> [PageElement] {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pageId && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.kind == .audio }
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
            allPages.map { ($0.id, $0.notebookId) },
            uniquingKeysWith: { first, _ in first }
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

        // Text blocks. `deletedAt == nil` carries the real soft-
        // delete state — the stored `isDeleted` attribute never
        // gets written (NSManagedObject name collision swallows the
        // setter), so the flag-only predicate returned soft-deleted
        // blocks in search results.
        let blocks = (try? context.fetch(
            FetchDescriptor<TextBlock>(predicate: #Predicate {
                $0.isDeleted == false && $0.deletedAt == nil
            })
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

        // Audio transcripts — Step 5: V6 `PageElement(.audio)` rows
        // carry the transcript on the linked `AudioContent`.
        let audioElements = (try? context.fetch(
            FetchDescriptor<PageElement>(
                predicate: #Predicate { $0.deletedAt == nil }
            )
        ))?.filter { $0.kind == .audio } ?? []
        for element in audioElements {
            guard let transcript = element.audioContent?.transcript,
                  !transcript.isEmpty,
                  transcript.lowercased().contains(q),
                  let nbId = pageToNotebook[element.pageId] else { continue }
            results.append(SearchResult(
                notebookId: nbId,
                pageId: element.pageId,
                context: String(transcript.prefix(120)),
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

        let dbURL   = Self.ceciliasNotesDirectoryURL.appendingPathComponent("ceciliasnotes.sqlite")
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
        let fm = FileManager.default

        // Source of truth — `ExportService.makeOutputURL` writes
        // every exported PDF into `ExportService.globalExportsDirectory`,
        // and `exportedPDFsSizeBytes()` reads from the same location.
        // The legacy per-notebook `notebooks/<id>/exports/` tree was
        // walked here originally but no live export path writes
        // there, so the user saw "cleared" but the size badge stayed
        // populated on the next entry into Settings → Storage.
        // Clear the global directory first, then sweep the legacy
        // per-notebook locations to scrub any stale leftovers.
        let globalDir = Self.globalExportsDirectory
        if fm.fileExists(atPath: globalDir.path) {
            do {
                let entries = try fm.contentsOfDirectory(
                    at: globalDir,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                )
                for entry in entries {
                    try fm.removeItem(at: entry)
                }
            } catch {
                throw CeciliasNotesStorageError.fileWriteFailed(error)
            }
        }

        let dirs = (try? fm.contentsOfDirectory(
            at: Self.notebooksDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for dir in dirs {
            let legacyExportsDir = dir.appendingPathComponent("exports")
            guard fm.fileExists(atPath: legacyExportsDir.path) else { continue }
            // Remove the legacy folder entirely (no recreate) — it's
            // never written to by the current export pipeline, so a
            // re-create would just be an empty placeholder that
            // misleads future size walks.
            try? fm.removeItem(at: legacyExportsDir)
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
        // Step 5: soft-delete every V6 audio element. Short notes
        // and lectures share the same `PageElement(.audio)` row
        // now, so one sweep covers both.
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        let now = Date()
        for element in elements where element.kind == .audio {
            element.deletedAt = now
            element.updatedAt = now
        }
        try context.save()
    }

    func exportedPDFsSizeBytes() -> Int64 {
        directorySize(at: Self.globalExportsDirectory)
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

    /// Total count of soft-deleted top-level records (Subject /
    /// Folder / Notebook). Used by the Storage settings to report
    /// how many records the Purge action will hard-delete.
    func softDeletedTotalCount() -> Int {
        let subjects = (try? context.fetch(
            FetchDescriptor<Subject>(predicate: #Predicate { $0.isDeleted == true })
        ))?.count ?? 0
        let folders = (try? context.fetch(
            FetchDescriptor<Folder>(predicate: #Predicate { $0.isDeleted == true })
        ))?.count ?? 0
        let notebooks = (try? context.fetch(
            FetchDescriptor<Notebook>(predicate: #Predicate { $0.isDeleted == true })
        ))?.count ?? 0
        return subjects + folders + notebooks
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

    /// Public wrapper around `purgeNotebookFiles` for callers that
    /// permanently delete a notebook through their own SwiftData
    /// path (Trash UI). Removes the per-notebook asset directory
    /// and every side-channel store that holds notebook-scoped
    /// data; the caller is responsible for the actual `context.delete`.
    func purgeFiles(for notebook: Notebook) {
        purgeNotebookFiles(notebook)
    }

    /// Public wrapper around `purgeImageElements` + `purgeAudioElements`
    /// for the Trash UI's per-page permanent delete. Removes any
    /// image / audio backing files for elements scoped to the given
    /// pages and drops those element rows; the caller is responsible
    /// for deleting the parent `Page` row itself.
    func purgeFiles(forPageIds pageIds: [UUID]) {
        guard !pageIds.isEmpty else { return }
        purgeImageElements(forPageIds: pageIds)
        purgeAudioElements(forPageIds: pageIds)
    }

    private func purgeNotebookFiles(_ notebook: Notebook) {
        let dir = notebookDir(notebook.id)
        try? FileManager.default.removeItem(at: dir)
        // Side-channel stores live in UserDefaults — wipe entries for
        // every page in the purged notebook so the dictionaries don't
        // accumulate orphaned mappings over time.
        let pageIds = (notebook.pages ?? []).map(\.id)
        // Step 5.5: `PDFBackingStore` + `PDFTextAnnotationStore`
        // retired. PDF page metadata lives on V6
        // `PageElement(.pdfPage) + PDFPageContent` rows; highlight
        // metadata lives on `PageElement(.highlight) +
        // HighlightContent`. Both get cascade-purged below when
        // we drop every PageElement keyed to a dead page.
        // Step 7: `StickyNoteStore` retired — sticky elements are
        // V6 `PageElement(.stickyNote) + StickyNoteContent` rows
        // and ride the same PageElement sweep.
        // Image attachments — Step 4 retired `MediaAttachmentStore`.
        // V6 image elements are `PageElement(kind: .image)` rows
        // with backing files at `MediaStorage.url(for: .images, id:)`.
        // Fetch each element for the dead pages, remove the file
        // by `ImageContent.id` (which matches the filename UUID),
        // then drop the row.
        purgeImageElements(forPageIds: pageIds)
        // Step 5: audio elements (`PageElement(.audio)` + `AudioContent`).
        // Same pattern as `purgeImageElements`: fetch by pageId,
        // delete files via `AudioContent.fileURL`, then drop the
        // rows (cascade-deletes AudioContent). LectureStore is
        // gone — the legacy V5 lecture metadata went with it.
        purgeAudioElements(forPageIds: pageIds)
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
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[Storage] purgeImageElements SAVE FAILED pageCount=\(pageIds.count): \(error)")
            #endif
        }
    }

    /// Step 5: hard-delete V6 audio elements + their backing m4a
    /// files for the given pages. Mirrors `purgeImageElements`.
    /// SwiftData cascade-deletes `AudioContent` when the parent
    /// `PageElement` is removed.
    private func purgeAudioElements(forPageIds pageIds: [UUID]) {
        guard !pageIds.isEmpty else { return }
        let pageIdSet = Set(pageIds)
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { pageIdSet.contains($0.pageId) }
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        let fm = FileManager.default
        for element in elements where element.kind == .audio {
            if let content = element.audioContent {
                try? fm.removeItem(at: content.fileURL)
            }
            context.delete(element)
        }
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[Storage] purgeAudioElements SAVE FAILED pageCount=\(pageIds.count): \(error)")
            #endif
        }
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
            recentIds.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
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
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
#endif
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
    /// Yields between every batch so the main runloop can paint
    /// progress, dispatch input, and stay touch-responsive. Synchronous
    /// batch inserts on the main actor were freezing the UI for the
    /// entire seeding run — at 1000 notebooks × up to 30 pages each
    /// that's ~15k inserts before a single frame redraws. Posts
    /// `.syntheticDataDidChange` on completion so the library refreshes
    /// instead of leaving the user staring at an empty subject view.
    func generateSyntheticNotebooks(count: Int) async throws {
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
        let batchSize = 50

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
            nb.sortOrder = i
            nb.subject   = subject

            context.insert(nb)
            // Skip the materialized `subject.notebooks` array append —
            // SwiftData maintains the inverse from `nb.subject`, and
            // resolving the array every iteration walks the full
            // accumulated list (O(N²) over the seed run, which was a
            // multi-second main-actor stall on its own).

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
            }
            nb.totalPageCount = pageCount

            let tone = CoverToneAssigner.tone(in: subject)
            CoverToneStore.setTone(tone, for: nb.id)

            if i % batchSize == batchSize - 1 {
                try context.save()
                // Hop off the actor so SwiftUI gets a frame and the
                // user can see the progress indicator move. Without
                // this the entire run is one synchronous main-actor
                // block — the app appears hung even though work is
                // making progress.
                await Task.yield()
            }
        }
        try context.save()
        NotificationCenter.default.post(name: .syntheticDataDidChange, object: nil)
    }

    /// Hard wipe of every notebook and subject in the store. Intended
    /// for clearing synthetic data between perf runs — destructive
    /// enough that the Settings entry is labelled accordingly.
    func wipeAllSyntheticData() async throws {
        let allNotebooks = fetchAllNotebooks()
        let batchSize = 100
        for (i, nb) in allNotebooks.enumerated() {
            context.delete(nb)
            if i % batchSize == batchSize - 1 {
                try context.save()
                await Task.yield()
            }
        }
        for s in fetchSubjects() {
            context.delete(s)
        }
        try context.save()
        NotificationCenter.default.post(name: .syntheticDataDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Posted once the DEBUG synthetic-data generator / wiper finishes
    /// so observers (e.g. `LibraryViewModel`) can refresh their
    /// caches without waiting for a user-driven trigger.
    static let syntheticDataDidChange = Notification.Name("ceciliasnotes.debug.syntheticDataDidChange")
}
#endif
