import Foundation
import SwiftData

@Model
final class Notebook {
    // MARK: Identity
    var id: UUID

    // MARK: Data
    var title: String
    /// nil = Uncategorised
    var subjectId: UUID?
    var coverColorHex: String
    var coverTexture: CoverTexture
    var sortOrder: Int
    var isPinned: Bool
    /// Max 5 tags, 20 chars each — enforced in StorageService.
    var tags: [String]
    var pageSize: PageSize
    var defaultTemplate: PageTemplate
    /// Denormalised page count — maintained by StorageService.
    var totalPageCount: Int
    /// JPEG 200×260pt thumbnail of first page, regenerated on save.
    var thumbnailData: Data?

    // MARK: Timestamps
    var createdAt: Date
    var updatedAt: Date

    // MARK: Soft delete
    var isDeleted: Bool
    var deletedAt: Date?

    // MARK: Relationships
    @Relationship(deleteRule: .cascade) var pages: [Page]

    // MARK: Init
    init(
        title: String,
        subjectId: UUID?,
        coverColorHex: String,
        coverTexture: CoverTexture = .none,
        pageSize: PageSize = .a4,
        defaultTemplate: PageTemplate = .blank
    ) {
        self.id              = UUID()
        self.title           = title
        self.subjectId       = subjectId
        self.coverColorHex   = coverColorHex
        self.coverTexture    = coverTexture
        self.sortOrder       = 0
        self.isPinned        = false
        self.tags            = []
        self.pageSize        = pageSize
        self.defaultTemplate = defaultTemplate
        self.totalPageCount  = 0
        self.thumbnailData   = nil
        self.createdAt       = Date()
        self.updatedAt       = Date()
        self.isDeleted       = false
        self.deletedAt       = nil
        self.pages           = []
    }
}
