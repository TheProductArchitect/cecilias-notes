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
    /// JSON-encoded PageTemplate stored as String — see Notebook.defaultTemplateRaw.
    var backgroundTemplateRaw: String

    var backgroundTemplate: PageTemplate {
        get { .from(jsonString: backgroundTemplateRaw) }
        set { backgroundTemplateRaw = newValue.jsonString }
    }
    /// Serialised PKDrawing — written by StorageService.updatePageStrokes.
    var strokeData: Data?
    /// Byte count of strokeData; updated atomically with strokeData.
    var strokeDataSize: Int

    /// Vertical extension of this page, in points, beyond the base
    /// `pageSize.pointSize.height`. Auto-extended by the editor when
    /// the user draws into the bottom half of the *last* page in a
    /// notebook — instead of inserting a new page, the existing page
    /// just gets longer. Optional so the V3→V4 lightweight migration
    /// can add the column without rewriting every existing row;
    /// callers should treat nil as 0 (use `effectiveExtraHeight`).
    var extraHeight: Double?

    /// Convenience: the extension to use in layout. nil → 0.
    var effectiveExtraHeight: CGFloat { CGFloat(extraHeight ?? 0) }

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
        self.pageSize              = pageSize
        self.backgroundTemplateRaw = backgroundTemplate.jsonString
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
