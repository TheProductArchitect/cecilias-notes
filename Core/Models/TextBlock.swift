import Foundation
import SwiftData

@Model
final class TextBlock {
    // MARK: Identity
    var id: UUID

    // MARK: Data
    var pageId: UUID {
        willSet { updatedAt = Date() }
    }
    /// Plain text — used for full-text search indexing only.
    var content: String {
        willSet { updatedAt = Date() }
    }
    /// Archived NSAttributedString — the rendering source of truth.
    var richTextData: Data? {
        willSet { updatedAt = Date() }
    }

    // MARK: Layout — normalised 0.0–1.0 in page coordinate space
    var x: Double {
        willSet { updatedAt = Date() }
    }
    var y: Double {
        willSet { updatedAt = Date() }
    }
    var width: Double {
        willSet { updatedAt = Date() }
    }
    var height: Double {
        willSet { updatedAt = Date() }
    }
    var rotation: Double {  // radians
        willSet { updatedAt = Date() }
    }
    var zIndex: Int {
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

    // MARK: Init
    init(pageId: UUID, x: Double, y: Double, width: Double, height: Double) {
        self.id         = UUID()
        self.pageId     = pageId
        self.content    = ""
        self.richTextData = nil
        self.x          = x
        self.y          = y
        self.width      = width
        self.height     = height
        self.rotation   = 0
        self.zIndex     = 0
        self.createdAt  = Date()
        self.updatedAt  = Date()
        self.isDeleted  = false
        self.deletedAt  = nil
    }
}
