import Foundation
import SwiftData

/// SwiftData-backed image attachment record. Phase 5A+5C Step 4
/// (images subsystem): replaces the UserDefaults-JSON
/// `MediaAttachmentRecord` struct + `MediaAttachmentStore` static
/// API. The store survives as a façade so call sites don't change.
///
/// CloudKit compatibility rules followed (same as `LectureRecord`
/// and `AudioRecord`):
///   • Every property has an inline default.
///   • No `@Attribute(.unique)` — relies on `UUID()`.
///   • No relationships — `pageId` / `notebookId` are denormalised
///     UUID columns. The V5 schema deliberately doesn't grow
///     `Page` inverse arrays for any of the three new entities.
///
/// The image bytes live at `MediaStorage.url(for: .images, id: id)`
/// (`Documents/MediaAttachments/images/<uuid>.jpg`). No
/// `relativeFilePath` column — the path is derivable from `id`.
///
/// **Reshape from `MediaAttachmentRecord`:**
///   • `relativeFilePath: String`     → dropped (derived from id)
///   • `rotationDegrees: Double`       → `rotation: Double` (per spec)
///   • Added `zOrder: Int = 0` for layering
///   • Other fields keep their names + types
@Model
final class ImageRecord {

    var id: UUID = UUID()
    var pageId: UUID = UUID()
    /// Denormalised so the reaper can sweep every image record for
    /// a notebook without joining through `Page`.
    var notebookId: UUID = UUID()

    /// Normalised top-left-origin page coordinates of the image's
    /// origin + size. `ImageAttachmentsView` resolves these against
    /// the page's point size at render time.
    var normalizedX:      Double = 0
    var normalizedY:      Double = 0
    var normalizedWidth:  Double = 0
    var normalizedHeight: Double = 0

    /// 0 / 90 / 180 / 270. Spec is 90° steps only — no free
    /// rotation in this pass.
    var rotation: Double = 0

    /// Stacking order within the page. Higher = drawn on top. Used
    /// by the chrome's "bring to front" / "send to back" actions
    /// when those land in a future pass; today every image gets
    /// `0` and the natural fetch order (createdAt) is the visible
    /// stacking.
    var zOrder: Int = 0

    /// Source image pixel dimensions captured at import. Used to
    /// preserve aspect ratio during resize when on-page size drifts
    /// due to pinch round-off.
    var originalWidth:  Double = 0
    var originalHeight: Double = 0

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Soft-delete stamp. `nil` = active.
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        pageId: UUID,
        notebookId: UUID,
        normalizedX: Double,
        normalizedY: Double,
        normalizedWidth: Double,
        normalizedHeight: Double,
        rotation: Double = 0,
        zOrder: Int = 0,
        originalWidth: Double = 0,
        originalHeight: Double = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id               = id
        self.pageId           = pageId
        self.notebookId       = notebookId
        self.normalizedX      = normalizedX
        self.normalizedY      = normalizedY
        self.normalizedWidth  = normalizedWidth
        self.normalizedHeight = normalizedHeight
        self.rotation         = rotation
        self.zOrder           = zOrder
        self.originalWidth    = originalWidth
        self.originalHeight   = originalHeight
        self.createdAt        = createdAt
        self.updatedAt        = updatedAt
        self.deletedAt        = deletedAt
    }
}
