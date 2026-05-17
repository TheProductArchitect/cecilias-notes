import Foundation
import SwiftData

@Model
final class Subject {
    // MARK: Identity
    var id: UUID = UUID()

    // MARK: Data
    var name: String = ""
    var colorHex: String = ""
    var sortOrder: Int = 0
    /// Pinned subjects float to the top of the sidebar above all
    /// unpinned subjects, ordered among themselves by `sortOrder`.
    /// Additive field, default `false` — CloudKit-safe (no schema
    /// version bump required).
    var isPinned: Bool = false

    // MARK: Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: Soft delete
    //
    // Every model in the data layer carries the same pair: `isDeleted`
    // flags the record, `deletedAt` stamps the moment. Every fetch
    // predicate filters `isDeleted == false` — soft-deleted records
    // are invisible to the UI immediately. The 30-day reaper
    // (`StorageService.purgeExpiredDeletedRecords()`) hard-deletes
    // anything past its `deletedAt + 30 days` cutoff, at which point
    // the cascade rules drop the related rows and
    // `purgeNotebookFiles` clears file assets + side-channel stores.
    // `emptyTrash()` runs the same hard-delete without the cutoff.
    var isDeleted: Bool = false
    var deletedAt: Date?

    // MARK: Relationships
    //
    // **CloudKit requires every relationship to be optional**,
    // including to-many collections. The inverses live on
    // `Notebook.subject` and `Folder.subject`; the raw `subjectId`
    // / `parentSubjectId` UUID columns on the children remain for
    // backwards-compatible read paths. Read sites use the
    // `?? []` nil-coalescing pattern; write sites use
    // `notebooks = (notebooks ?? []) + [child]` instead of `.append`.
    @Relationship(deleteRule: .cascade, inverse: \Notebook.subject)
    var notebooks: [Notebook]?

    @Relationship(deleteRule: .cascade, inverse: \Folder.subject)
    var folders: [Folder]?

    // MARK: Init
    init(name: String, colorHex: String, sortOrder: Int = 0) {
        self.id        = UUID()
        self.name      = name
        self.colorHex  = colorHex
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isDeleted = false
        self.deletedAt = nil
    }
}
