import Foundation
import SwiftData

// MARK: - Folder

/// Optional intermediate level between `Subject` and `Notebook`.
///
/// Hierarchy is now:
///   Subject → (Folder?) → Notebook
///
/// A folder always lives inside a subject (`parentSubjectId` is non-optional).
/// `parentFolderId` allows nesting; the UI caps depth at 3 to keep navigation
/// sane. A notebook either sits directly under its subject (`folderId == nil`)
/// or inside a folder.
///
/// 30-day soft-delete pattern matches `Subject`/`Notebook`/etc.: delete sets
/// `isDeleted = true`, sweep reaper purges entries older than 30 days.
@Model
final class Folder {
    // MARK: Identity
    var id: UUID

    // MARK: Data
    var name: String
    /// Always non-nil: every folder lives inside a subject.
    var parentSubjectId: UUID
    /// Nil = direct child of the subject. Non-nil = nested folder.
    var parentFolderId: UUID?
    var sortOrder: Int

    // MARK: Timestamps
    var createdAt: Date
    var updatedAt: Date

    // MARK: Soft delete
    var isDeleted: Bool
    var deletedAt: Date?

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
