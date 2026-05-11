import Foundation
import SwiftData

// MARK: - Folder

/// Optional intermediate level between `Subject` and `Notebook`.
///
/// Hierarchy is now:
///   Subject → (Folder?) → Notebook
///
/// `parentSubjectId` is a raw UUID for read paths that haven't been
/// migrated; the canonical CloudKit-compatible reference is the
/// `subject` relationship below. Both stay in sync because every
/// write site sets the UUID.
/// `parentFolderId` allows nesting; the UI caps depth at 3 to keep
/// navigation sane. A notebook either sits directly under its
/// subject (`folderId == nil`) or inside a folder.
///
/// 30-day soft-delete pattern matches `Subject`/`Notebook`/etc.:
/// delete sets `isDeleted = true`, sweep reaper purges entries
/// older than 30 days.
@Model
final class Folder {
    // MARK: Identity
    var id: UUID = UUID()

    // MARK: Data
    var name: String = ""
    /// Raw foreign-key UUID — preserved for read paths that haven't
    /// been migrated to the `subject` relationship. Always set in
    /// lockstep with `subject` when writing.
    var parentSubjectId: UUID = UUID()
    /// Nil = direct child of the subject. Non-nil = nested folder.
    var parentFolderId: UUID?
    var sortOrder: Int = 0

    // MARK: Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: Soft delete
    var isDeleted: Bool = false
    var deletedAt: Date?

    // MARK: Relationships
    /// CloudKit-compatible back-reference to the owning subject.
    /// The `inverse:` on `Subject.folders` makes this bidirectional.
    @Relationship var subject: Subject?

    // MARK: Init
    init(
        name: String,
        parentSubjectId: UUID,
        parentFolderId: UUID? = nil,
        sortOrder: Int = 0
    ) {
        self.id              = UUID()
        self.name            = name
        self.parentSubjectId = parentSubjectId
        self.parentFolderId  = parentFolderId
        self.sortOrder       = sortOrder
        self.createdAt       = Date()
        self.updatedAt       = Date()
        self.isDeleted       = false
        self.deletedAt       = nil
    }
}
