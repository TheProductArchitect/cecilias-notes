import Foundation
import SwiftData

/// Image content for a `PageElement` of kind `.image`. The image
/// bytes live in `MediaStorage` at
/// `Documents/MediaAttachments/images/<id>.<ext>` (iCloud Drive
/// synced); SwiftData / CloudKit hold only metadata.
///
/// V6 (Step 1): inert. The legacy `ImageRecord` entity still serves
/// rendering via `ImageAttachmentsView` until Step 4 migrates onto
/// this row.
@Model
final class ImageContent {

    var id: UUID = UUID()
    @Relationship var element: PageElement?

    /// Filename inside `MediaStorage/images/`, e.g. `<id>.jpg`.
    var filename: String = ""

    /// Source pixel dimensions captured at import. Preserves aspect
    /// ratio when on-page size drifts due to pinch round-off.
    var originalPixelWidth: Int  = 0
    var originalPixelHeight: Int = 0

    /// Set true once Vision OCR has indexed the image's text — used
    /// by future search features. Defaults false; OCR is post-1.0.
    var hasOCRText: Bool = false

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        filename: String = "",
        originalPixelWidth: Int = 0,
        originalPixelHeight: Int = 0,
        hasOCRText: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id                  = id
        self.filename            = filename
        self.originalPixelWidth  = originalPixelWidth
        self.originalPixelHeight = originalPixelHeight
        self.hasOCRText          = hasOCRText
        self.createdAt           = createdAt
        self.updatedAt           = updatedAt
    }
}
