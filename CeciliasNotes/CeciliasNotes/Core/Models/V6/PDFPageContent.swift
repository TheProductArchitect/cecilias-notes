import Foundation
import SwiftData

/// PDF-page content for a `PageElement` of kind `.pdfPage`.
/// Supports both architecture-doc workflows (§13):
///   • A — "PDF as notebook": one `PDFPageContent` element per PDF
///     page, each filling its own `Page` at `zIndex = 0`.
///   • B — "PDF as reference": user inserts one or more PDF pages
///     onto an existing page; element is movable / resizable /
///     rotatable like any other.
///
/// V6 (Step 1): inert. The existing PDF-backing pipeline
/// (`PDFBackingStore` + per-page `pdfPageIndex`) still serves PDF
/// notebooks until Step 4.5 migrates onto this row.
///
/// **Shared PDF file storage.** Multiple rows can reference the
/// same PDF document. The PDF lives once at
/// `MediaStorage/pdfs/<pdfDocumentId>.pdf`; each row picks a
/// specific `pageIndex` inside that file. Background GC removes
/// PDFs with zero referencing rows after a sweep.
@Model
final class PDFPageContent {

    var id: UUID = UUID()
    @Relationship var element: PageElement?

    /// Identifies the PDF file in `MediaStorage/pdfs/`. Multiple
    /// rows can share a single PDF document (e.g. user imported
    /// page 3 and page 7 of the same textbook).
    var pdfDocumentId: UUID = UUID()
    /// 0-indexed page within `pdfDocumentId.pdf`.
    var pageIndex: Int      = 0

    /// Original PDF-point dimensions, used to preserve aspect ratio
    /// when the user resizes the on-page element.
    var originalPageWidth: Double  = 0
    var originalPageHeight: Double = 0

    /// Filename of a small cached preview PNG generated at import
    /// time and shown while PDFKit loads the full page. Lives in
    /// `MediaStorage/pdf-previews/`. Nil = no preview cached yet.
    var previewImageFilename: String? = nil

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        pdfDocumentId: UUID = UUID(),
        pageIndex: Int = 0,
        originalPageWidth: Double = 0,
        originalPageHeight: Double = 0,
        previewImageFilename: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id                   = id
        self.pdfDocumentId        = pdfDocumentId
        self.pageIndex            = pageIndex
        self.originalPageWidth    = originalPageWidth
        self.originalPageHeight   = originalPageHeight
        self.previewImageFilename = previewImageFilename
        self.createdAt            = createdAt
        self.updatedAt            = updatedAt
    }
}
