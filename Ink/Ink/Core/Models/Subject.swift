import Foundation
import SwiftData

@Model
final class Subject {
    // MARK: Identity
    var id: UUID

    // MARK: Data
    var name: String
    var colorHex: String
    var sortOrder: Int

    // MARK: Timestamps
    var createdAt: Date
    var updatedAt: Date

    // MARK: Soft delete
    var isDeleted: Bool
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
