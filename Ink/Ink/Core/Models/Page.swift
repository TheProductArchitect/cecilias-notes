import Foundation
import SwiftData

@Model
final class Page {
    // MARK: Identity
    var id: UUID

    // MARK: Data
    var notebookId: UUID
    /// 1-indexed. Maintained by StorageService; never set directly by callers.
    var pageNumber: Int
    var pageSize: PageSize
    var backgroundTemplate: PageTemplate
    /// Serialised PKDrawing — written by StorageService.updatePageStrokes.
    var strokeData: Data?
    /// Byte count of strokeData; updated atomically with strokeData.
    var strokeDataSize: Int

    // MARK: Timestamps
    var createdAt: Date
    var updatedAt: Date

    // MARK: Soft delete
    var isDeleted: Bool
    var deletedAt: Date?

    // MARK: Relationships
    @Relationship(deleteRule: .cascade) var textBlocks: [TextBlock]
    @Relationship(deleteRule: .cascade) var mediaAttachments: [MediaAttachment]
    @Relationship(deleteRule: .cascade) var audioAnnotations: [AudioAnnotation]

    // MARK: Init
    init(
        notebookId: UUID,
        pageNumber: Int,
        pageSize: PageSize,
        backgroundTemplate: PageTemplate
    ) {
        self.id                 = UUID()
        self.notebookId         = notebookId
        self.pageNumber         = pageNumber
        self.pageSize           = pageSize
        self.backgroundTemplate = backgroundTemplate
        self.strokeData         = nil
        self.strokeDataSize     = 0
        self.createdAt          = Date()
        self.updatedAt          = Date()
        self.isDeleted          = false
        self.deletedAt          = nil
        self.textBlocks         = []
        self.mediaAttachments   = []
        self.audioAnnotations   = []
    }
}
