import Foundation
import SwiftData

/// Image content for a `PageElement` of kind `.image`. The image
/// bytes live in `MediaStorage` at
/// `Documents/MediaAttachments/images/<id>.<fileFormat>` (iCloud
/// Drive synced); SwiftData / CloudKit hold only metadata.
///
/// V6 (Step 4): live. `ImageElementsOverlayView` renders one of
/// these per `PageElement(kind: .image)` with selection chrome
/// (resize / rotate / delete) under both the cursor and image
/// tools. The legacy `ImageRecord` entity was removed in the same
/// commit — Step 1's wipe means there was no prior data to
/// migrate.
@Model
final class ImageContent {

    var id: UUID = UUID()
    @Relationship var element: PageElement?

    /// Filename inside `MediaStorage/images/`, e.g. `<id>.jpg`.
    /// Equal to `\(id.uuidString).\(fileFormat)` for elements
    /// created in V6 — the renderer derives the file URL from
    /// `MediaStorage.url(for: .images, id: self.id, fileExtension: fileFormat)`.
    var filename: String = ""

    /// On-disk format suffix, e.g. `"jpg"`, `"png"`, `"heic"`.
    /// Added in Step 4 so source format can be preserved when the
    /// picker hands us HEIC; defaulted to `"jpg"` for older or
    /// CloudKit-synced rows that pre-date this field. The
    /// `MediaStorage.writeImage` path emits jpg/png today; HEIC
    /// passthrough is a follow-up.
    var fileFormat: String = "jpg"

    /// Source pixel dimensions captured at import. Preserves aspect
    /// ratio when on-page size drifts due to pinch round-off.
    var originalPixelWidth: Int  = 0
    var originalPixelHeight: Int = 0

    /// Optional crop rect in normalised image-space ([0, 1]^2).
    /// When all four are non-nil the renderer crops to this sub-
    /// rect before fitting into the element's bounds. When any are
    /// nil the full image is shown. The UI for setting these is
    /// post-1.0; the schema ships now so a future crop tool is a
    /// feature change, not a migration.
    var cropOriginX: Double? = nil
    var cropOriginY: Double? = nil
    var cropWidth: Double? = nil
    var cropHeight: Double? = nil

    /// Set true once Vision OCR has indexed the image's text — used
    /// by future search features. Defaults false; OCR is post-1.0.
    var hasOCRText: Bool = false

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        filename: String = "",
        fileFormat: String = "jpg",
        originalPixelWidth: Int = 0,
        originalPixelHeight: Int = 0,
        cropOriginX: Double? = nil,
        cropOriginY: Double? = nil,
        cropWidth: Double? = nil,
        cropHeight: Double? = nil,
        hasOCRText: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id                  = id
        self.filename            = filename
        self.fileFormat          = fileFormat
        self.originalPixelWidth  = originalPixelWidth
        self.originalPixelHeight = originalPixelHeight
        self.cropOriginX         = cropOriginX
        self.cropOriginY         = cropOriginY
        self.cropWidth           = cropWidth
        self.cropHeight          = cropHeight
        self.hasOCRText          = hasOCRText
        self.createdAt           = createdAt
        self.updatedAt           = updatedAt
    }

    // MARK: - Convenience

    /// Resolved on-disk URL for the image bytes. The renderer reads
    /// this on first paint; missing files surface the
    /// `photo.badge.exclamationmark` placeholder until iCloud Drive
    /// finishes a restore.
    var fileURL: URL {
        MediaStorage.url(for: .images, id: id, fileExtension: fileFormat)
    }
}
