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

    // Step 5.5: `pdfPageIndex` removed. The "which PDF page does
    // this canvas page render?" question is now answered by the
    // single full-bleed `PageElement(kind: .pdfPage)` row scoped
    // to this Page — `PDFPageContent.pageIndex` carries the
    // index. The UserDefaults-backed `PDFBackingStore` map is gone.

    // Step 8: `strokeData` / `strokeDataSize` removed. Strokes are
    // now the singleton `PageElement(kind: .stroke) + StrokeContent`
    // scoped to this Page — `StrokeContent.strokeData` carries the
    // serialised PKDrawing. Reads/writes flow through
    // `StorageService.strokeData(for:)` /
    // `StorageService.updatePageStrokes(_:drawing:)` which transparently
    // resolve the singleton.

    // MARK: Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: Soft delete
    var isDeleted: Bool = false
    var deletedAt: Date?

    // MARK: Relationships
    //
    // CloudKit-compatible bidirectional shape: `notebook` is the
    // back-reference paired with `Notebook.pages`; `textBlocks` owns
    // its inverse on `TextBlock.page`. Audio (Phase 5A+5C Step 3)
    // and lectures (Step 2) and images (side-channel) all live as
    // denormalised-by-pageId records — no relationship from `Page`
    // to them. Queries go through `FetchDescriptor<AudioRecord>` /
    // `FetchDescriptor<LectureRecord>` keyed by `pageId`.
    @Relationship var notebook: Notebook?

    @Relationship(deleteRule: .cascade, inverse: \TextBlock.page)
    var textBlocks: [TextBlock]?

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
        self.createdAt          = Date()
        self.updatedAt          = Date()
        self.isDeleted          = false
        self.deletedAt          = nil
    }
}
