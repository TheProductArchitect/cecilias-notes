import Foundation
import SwiftData

@Model
final class Notebook {
    // MARK: Identity
    var id: UUID

    // MARK: Data
    var title: String {
        willSet { updatedAt = Date() }
    }
    /// nil = Uncategorised
    var subjectId: UUID? {
        willSet { updatedAt = Date() }
    }
    var coverColorHex: String {
        willSet { updatedAt = Date() }
    }
    var coverTexture: CoverTexture {
        willSet { updatedAt = Date() }
    }
    var sortOrder: Int {
        willSet { updatedAt = Date() }
    }
    var isPinned: Bool {
        willSet { updatedAt = Date() }
    }
    /// Max 5 tags, 20 chars each — enforced in StorageService.
    var tags: [String] {
        willSet { updatedAt = Date() }
    }
    var pageSize: PageSize {
        willSet { updatedAt = Date() }
    }
    var defaultTemplate: PageTemplate {
        willSet { updatedAt = Date() }
    }
    /// Denormalised page count — maintained by StorageService.
    var totalPageCount: Int {
        willSet { updatedAt = Date() }
    }
    /// JPEG 200×260pt thumbnail of first page, regenerated on save.
    var thumbnailData: Data? {
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
