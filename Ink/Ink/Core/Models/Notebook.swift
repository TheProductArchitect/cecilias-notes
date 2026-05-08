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
    /// Comma-separated tags (stored as String so CoreData's transformer is never invoked).
    /// Access via the computed `tags` property.
    var tagsRaw: String
    var pageSize: PageSize
    /// JSON-encoded PageTemplate (stored as String — plain Codable enums with associated
    /// values break CoreData's Transformable decoder). Access via `defaultTemplate`.
    var defaultTemplateRaw: String

    var tags: [String] {
        get { tagsRaw.isEmpty ? [] : tagsRaw.components(separatedBy: "\u{001F}") }
        set { tagsRaw = newValue.joined(separator: "\u{001F}") }
    }

    var defaultTemplate: PageTemplate {
        get { .from(jsonString: defaultTemplateRaw) }
        set { defaultTemplateRaw = newValue.jsonString }
    }
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
        self.sortOrder          = 0
        self.isPinned           = false
        self.tagsRaw            = ""
        self.pageSize           = pageSize
        self.defaultTemplateRaw = defaultTemplate.jsonString
        self.totalPageCount  = 0
        self.thumbnailData   = nil
        self.createdAt       = Date()
        self.updatedAt       = Date()
        self.isDeleted       = false
        self.deletedAt       = nil
        self.pages           = []
    }
}
