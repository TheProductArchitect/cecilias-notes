import Foundation
import SwiftData

@Model
final class MediaAttachment {
    // MARK: Identity
    var id: UUID

    // MARK: Data
    var pageId: UUID {
        willSet { updatedAt = Date() }
    }
    /// Denormalised from page.notebookId — required for building file URLs
    /// without an extra context fetch.
    var notebookId: UUID {
        willSet { updatedAt = Date() }
    }
    var type: MediaType {
        willSet { updatedAt = Date() }
    }
    var fileName: String {
        willSet { updatedAt = Date() }
    }
    var mimeType: String {
        willSet { updatedAt = Date() }
    }
    var fileSizeBytes: Int64 {
        willSet { updatedAt = Date() }
    }
    var originalWidth: Int {
        willSet { updatedAt = Date() }
    }
    var originalHeight: Int {
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
    var rotation: Double {
        willSet { updatedAt = Date() }
    }
    var zIndex: Int {
        willSet { updatedAt = Date() }
    }
    var caption: String? {
        willSet { updatedAt = Date() }
    }
    /// 0.2–1.0. Applied as UIImage alpha during rendering.
    var opacity: Double {
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
