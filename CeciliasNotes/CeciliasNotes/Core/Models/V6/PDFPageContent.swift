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
/// V6 (Step 4.5): live for Workflow B (PDF-as-reference inserted
/// on an existing page). Workflow A (PDF-as-notebook import) is
/// **not yet** refactored onto this row — the legacy
/// `PDFBackingStore` + `PageRenderer.updatePDFBacking` path is
/// preserved so the existing PDF-text annotation overlay
/// (`PDFTextAnnotationStore` records drawn on top of the PDF in
/// `PageRenderer.drawTextAnnotationOverlay`) keeps working. A
/// follow-up step will move both the PDF render and the
/// annotation overlay onto this element model.
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

    /// Plain-text extracted from this PDF page at import time via
    /// `PDFPage.string`. Populated for digital PDFs (Word/Pages
    /// exports, web "Save as PDF") where the text layer is
    /// embedded; nil for scanned/image-only PDFs. Read by quiz
    /// generation so on-device pattern matching can run against
    /// PDF content without a runtime OCR pass. Not user-visible —
    /// the page still renders from the PDF file itself.
    var extractedText: String? = nil

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        pdfDocumentId: UUID = UUID(),
        pageIndex: Int = 0,
        originalPageWidth: Double = 0,
        originalPageHeight: Double = 0,
        previewImageFilename: String? = nil,
        extractedText: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id                   = id
        self.pdfDocumentId        = pdfDocumentId
        self.pageIndex            = pageIndex
        self.originalPageWidth    = originalPageWidth
        self.originalPageHeight   = originalPageHeight
        self.previewImageFilename = previewImageFilename
        self.extractedText        = extractedText
        self.createdAt            = createdAt
        self.updatedAt            = updatedAt
    }

    // MARK: - Convenience

    /// On-disk URL for the shared PDF file. Multiple PDFPageContent
    /// rows can resolve to the same URL when they reference different
    /// pages of the same document (the deduplication contract).
    var pdfFileURL: URL {
        MediaStorage.url(forPDF: pdfDocumentId)
    }

    /// On-disk URL for this row's cached preview thumbnail, if any.
    /// Generated at import time at a small fixed width and shown
    /// while PDFKit asynchronously loads the full page for crisp
    /// render.
    var previewImageURL: URL? {
        guard let name = previewImageFilename else { return nil }
        return MediaStorage.pdfPreviewDirectory.appendingPathComponent(name)
    }
}
