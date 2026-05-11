import Foundation
import SwiftData

@Model
final class MediaAttachment {
    // MARK: Identity
    var id: UUID = UUID()

    // MARK: Data
    var pageId: UUID = UUID()
    /// Denormalised from page.notebookId — required for building file URLs
    /// without an extra context fetch.
    var notebookId: UUID = UUID()
    var type: MediaType = MediaType.image
    var fileName: String = ""
    var mimeType: String = ""
    var fileSizeBytes: Int64 = 0
    var originalWidth: Int = 0
    var originalHeight: Int = 0

    // MARK: Layout — normalised 0.0–1.0 in page coordinate space
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    var rotation: Double = 0
    var zIndex: Int = 0
    var caption: String?
    /// 0.2–1.0. Applied as UIImage alpha during rendering.
    var opacity: Double = 1.0

    // MARK: Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: Soft delete
    var isDeleted: Bool = false
    var deletedAt: Date?

    // MARK: Relationships
    /// CloudKit-compatible back-reference to the owning page. The
    /// `inverse:` on `Page.mediaAttachments` makes this bidirectional.
    @Relationship var page: Page?

    // MARK: Init
    init(
        pageId: UUID,
        notebookId: UUID,
        type: MediaType,
        fileName: String,
        mimeType: String,
        fileSizeBytes: Int64,
        originalWidth: Int,
        originalHeight: Int,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.id             = UUID()
        self.pageId         = pageId
        self.notebookId     = notebookId
        self.type           = type
        self.fileName       = fileName
        self.mimeType       = mimeType
        self.fileSizeBytes  = fileSizeBytes
        self.originalWidth  = originalWidth
        self.originalHeight = originalHeight
        self.x              = x
        self.y              = y
        self.width          = width
        self.height         = height
        self.rotation       = 0
        self.zIndex         = 0
        self.caption        = nil
        self.opacity        = 1.0
        self.createdAt      = Date()
        self.updatedAt      = Date()
        self.isDeleted      = false
        self.deletedAt      = nil
    }
}
