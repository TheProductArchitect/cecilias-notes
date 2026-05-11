import Foundation
import SwiftData

@Model
final class Page {
    // MARK: Identity
    var id: UUID = UUID()

    // MARK: Data
    var notebookId: UUID = UUID()
    /// 1-indexed. Maintained by StorageService; never set directly by callers.
    var pageNumber: Int = 0
    var pageSize: PageSize = PageSize.a4
    /// JSON-encoded PageTemplate stored as String — see Notebook.defaultTemplateRaw.
    var backgroundTemplateRaw: String = ""

    var backgroundTemplate: PageTemplate {
        get { .from(jsonString: backgroundTemplateRaw) }
        set { backgroundTemplateRaw = newValue.jsonString }
    }

    /// When set, this page renders a page of the notebook's source
    /// PDF as its background. The integer is the 0-based index into
    /// the source PDF, *pinned to the page itself* — reordering the
    /// page's `pageNumber` doesn't change which PDF page it shows.
    /// Persisted in `PDFBackingStore` (UserDefaults) for the same
    /// schema reasons as `coverTone` / `autoAddPagesOnScroll`.
    var pdfPageIndex: Int? {
        get { PDFBackingStore.pdfPageIndex(for: id) }
        set { PDFBackingStore.setPDFPageIndex(newValue, for: id) }
    }
    /// Serialised PKDrawing — written by StorageService.updatePageStrokes.
    var strokeData: Data?
    /// Byte count of strokeData; updated atomically with strokeData.
    var strokeDataSize: Int = 0

    // Note: the auto-grow "extra height" for the last page in a
    // notebook is *not* stored on the model — `PageExtraHeightStore`
    // (UserDefaults) keeps it sidecar. That's a per-device UI
    // preference, not synced via CloudKit.

    // MARK: Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: Soft delete
    var isDeleted: Bool = false
    var deletedAt: Date?

    // MARK: Relationships
    //
    // CloudKit-compatible bidirectional shape: `notebook` is the
    // back-reference paired with `Notebook.pages`; the three child
    // collections own their inverses on `TextBlock.page`,
    // `MediaAttachment.page` and `AudioAnnotation.page`. The
    // `notebookId` UUID column above remains for read paths.
    @Relationship var notebook: Notebook?

    @Relationship(deleteRule: .cascade, inverse: \TextBlock.page)
    var textBlocks: [TextBlock]?

    @Relationship(deleteRule: .cascade, inverse: \MediaAttachment.page)
    var mediaAttachments: [MediaAttachment]?

    @Relationship(deleteRule: .cascade, inverse: \AudioAnnotation.page)
    var audioAnnotations: [AudioAnnotation]?

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
    }
}
