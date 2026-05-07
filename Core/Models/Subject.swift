import Foundation
import SwiftData

@Model
final class Subject {
    // MARK: Identity
    var id: UUID

    // MARK: Data — each mutable property auto-bumps updatedAt via willSet.
    // Note: SwiftData's @Model macro rewrites properties as computed accessors
    // backed by PersistentBackingData. Property observers ARE preserved in
    // the macro expansion for iOS 17+. StorageService also sets updatedAt
    // explicitly in every mutation as a safety net.
    var name: String {
        willSet { updatedAt = Date() }
    }
    var colorHex: String {
        willSet { updatedAt = Date() }
    }
    var sortOrder: Int {
        willSet { updatedAt = Date() }
    }

    // MARK: Timestamps
    var createdAt: Date
    var updatedAt: Date

    // MARK: Soft delete
    var isDeleted: Bool {
        willSet { updatedAt = Date() }
    }
    var deletedAt: Date?

    // MARK: Relationships
    @Relationship(deleteRule: .cascade) var notebooks: [Notebook]

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
        self.notebooks = []
    }
}
