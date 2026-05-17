import Foundation
import SwiftData

@Model
final class TextBlock {
    // MARK: Identity
    var id: UUID = UUID()

    // MARK: Data
    /// Raw foreign-key UUID — preserved for read paths that haven't
    /// migrated to the `page` relationship. Always set in lockstep
    /// with `page` when writing.
    var pageId: UUID = UUID()
    /// Plain text — used for full-text search indexing only.
    var content: String = ""
    /// Archived NSAttributedString — the rendering source of truth.
    var richTextData: Data?

    // MARK: Layout — normalised 0.0–1.0 in page coordinate space
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    var rotation: Double = 0  // radians
    var zIndex: Int = 0

    // MARK: Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: Soft delete
    var isDeleted: Bool = false
    var deletedAt: Date?

    // MARK: Relationships
    /// CloudKit-compatible back-reference to the owning page. The
    /// `inverse:` on `Page.textBlocks` makes this bidirectional.
    @Relationship var page: Page?

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
