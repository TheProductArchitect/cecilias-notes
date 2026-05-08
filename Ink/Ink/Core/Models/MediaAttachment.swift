import Foundation
import SwiftData

@Model
final class MediaAttachment {
    // MARK: Identity
    var id: UUID

    // MARK: Data
    var pageId: UUID
    /// Denormalised from page.notebookId — required for building file URLs
    /// without an extra context fetch.
    var notebookId: UUID
    var type: MediaType
    var fileName: String
    var mimeType: String
    var fileSizeBytes: Int64
    var originalWidth: Int
    var originalHeight: Int

    // MARK: Layout — normalised 0.0–1.0 in page coordinate space
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rotation: Double
    var zIndex: Int
    var caption: String?
    /// 0.2–1.0. Applied as UIImage alpha during rendering.
    var opacity: Double

    // MARK: Timestamps
    var createdAt: Date
    var updatedAt: Date

    // MARK: Soft delete
    var isDeleted: Bool
    var deletedAt: Date?

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
