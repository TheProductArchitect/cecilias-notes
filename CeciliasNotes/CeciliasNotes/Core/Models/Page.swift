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

    /// JSON-encoded array of inkbook v1 `Block` values, captured
    /// verbatim from the source `.inkbook` file when this page was
    /// ingested. The mirror exporter emits this verbatim so an
    /// agent's read-modify-write loop sees structurally-identical
    /// blocks (heading levels, list styles, callout kinds, etc.)
    /// rather than the previous lossy
    /// `concatenate-everything-into-one-paragraph` flattening.
    ///
    /// Nil for user-created pages (no inkbook source) and for any
    /// page that gains a non-text element after ingestion (text
    /// edits, image insertion, ink) — the exporter's structured
    /// fallback rebuilds blocks from the live model in that case.
    /// Importer sets it on ingest; agent append flows preserve it
    /// for unchanged pages and set it for newly-appended pages.
    var inkbookBlocksJSON: String? = nil

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

// MARK: - Inkbook stash invalidation
//
// The exporter prefers `inkbookBlocksJSON` over the live SwiftData
// state when it's present so MCP-written structure (headings, lists,
// callouts) round-trips losslessly. Once the iPad user edits text
// on that page, the stash is stale — keeping it on the row hides the
// edit from the mirror, which means an MCP that subsequently reads
// the notebook would see the original AI text, not the user's
// changes.
//
// `clearInkbookStash(forPageId:context:)` is the single chokepoint
// every text-edit write site MUST call so the AI-write and
// user-edit paths funnel into the same exporter behaviour. Calls
// are no-ops when the page wasn't inkbook-sourced (stash already
// nil) so it's safe to call from hot paths.
extension Page {

    /// Reset the inkbook block stash on the page identified by
    /// `pageId` so the next mirror export rebuilds blocks from the
    /// live SwiftData text. Safe — and cheap — to call on every
    /// text mutation; performs no work when the row's stash is
    /// already nil (the user-created-page case). The caller's
    /// surrounding `context.save()` persists the change; this
    /// helper does NOT save on its own.
    static func clearInkbookStash(forPageId pageId: UUID, context: ModelContext) {
        let descriptor = FetchDescriptor<Page>(
            predicate: #Predicate { $0.id == pageId }
        )
        guard let page = (try? context.fetch(descriptor))?.first,
              page.inkbookBlocksJSON != nil
        else { return }
        page.inkbookBlocksJSON = nil
        page.updatedAt = Date()
    }
}
