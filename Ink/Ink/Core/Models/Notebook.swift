import Foundation
import SwiftData

@Model
final class Notebook {
    // MARK: Identity
    var id: UUID = UUID()

    // MARK: Data
    var title: String = ""
    /// nil = Uncategorised
    var subjectId: UUID?
    /// nil = directly under the subject. Non-nil = inside the folder with this id.
    /// Folder is always within the same subject as the notebook.
    var folderId: UUID?
    var coverColorHex: String = ""
    var coverTexture: CoverTexture = CoverTexture.none
    var sortOrder: Int = 0
    var isPinned: Bool = false
    /// U+001F-separated tags (stored as String so CoreData's transformer is
    /// never invoked, and so commas inside tags survive a round-trip).
    /// Access via the computed `tags` property.
    var tagsRaw: String = ""
    var pageSize: PageSize = PageSize.a4
    /// JSON-encoded PageTemplate (stored as String — plain Codable enums with associated
    /// values break CoreData's Transformable decoder). Access via `defaultTemplate`.
    var defaultTemplateRaw: String = ""

    var tags: [String] {
        get { tagsRaw.isEmpty ? [] : tagsRaw.components(separatedBy: "\u{001F}") }
        set { tagsRaw = newValue.joined(separator: "\u{001F}") }
    }

    var defaultTemplate: PageTemplate {
        get { .from(jsonString: defaultTemplateRaw) }
        set { defaultTemplateRaw = newValue.jsonString }
    }

    /// True when this notebook was created via "Import PDF…" and has a
    /// source PDF on disk. The PDF lives at
    /// `StorageService.sourcePDFURL(id)`. Used by the customise panel
    /// (to hide the template + page-size sections — neither applies
    /// to PDF backgrounds) and the export pipeline (to choose the
    /// annotated-PDF export path).
    var isPDFBacked: Bool {
        // Both `shared` and `hasSourcePDF` are `nonisolated` on
        // `StorageService` — see the singleton declaration. The call
        // is a pure file-existence check; no actor state is touched.
        StorageService.shared.hasSourcePDF(id)
    }

    /// Filesystem URL of the source PDF, if this notebook is
    /// PDF-backed. The file is copied into the notebook's directory
    /// during import so it's reaper-purged with the notebook.
    var sourcePDFURL: URL? {
        let url = StorageService.shared.sourcePDFURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// One of eight cover tones. Persisted via `CoverToneStore`
    /// (UserDefaults) rather than a SwiftData column to avoid the
    /// schema-checksum crash documented in `InkSchemas.swift`. Reads
    /// resolve to `.parchment` for notebooks that have never had a
    /// tone explicitly set, so existing libraries need no migration.
    var coverTone: NotebookCoverTone {
        get { CoverToneStore.tone(for: id) }
        set { CoverToneStore.setTone(newValue, for: id) }
    }

    /// When `true`, scrolling near the bottom of the last page appends
    /// a fresh page automatically. When `false`, the user must add
    /// pages manually via the page strip or the editor's More menu.
    /// Persisted via `NotebookPreferencesStore` (UserDefaults) for the
    /// same schema reasons as `coverTone`. Defaults to `true` for any
    /// notebook without an explicit setting.
    var autoAddPagesOnScroll: Bool {
        get { NotebookPreferencesStore.preferences(for: id).autoAddPagesOnScroll }
        set {
            var prefs = NotebookPreferencesStore.preferences(for: id)
            prefs.autoAddPagesOnScroll = newValue
            NotebookPreferencesStore.setPreferences(prefs, for: id)
        }
    }

    /// When `true`, the editor's cover-tone header auto-hides on
    /// first stroke and reappears via the 3pt return bar / swipe-down
    /// gesture. When `false`, the header is always visible. Defaults
    /// to `true`.
    var autoHideHeader: Bool {
        get { NotebookPreferencesStore.preferences(for: id).autoHideHeader }
        set {
            var prefs = NotebookPreferencesStore.preferences(for: id)
            prefs.autoHideHeader = newValue
            NotebookPreferencesStore.setPreferences(prefs, for: id)
        }
    }
    /// Denormalised page count — maintained by StorageService.
    var totalPageCount: Int = 0
    /// JPEG 200×260pt thumbnail of first page, regenerated on save.
    var thumbnailData: Data?

    // MARK: Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: Soft delete
    var isDeleted: Bool = false
    var deletedAt: Date?

    // MARK: Relationships
    //
    // `subject` is the CloudKit-compatible back-reference; the
    // existing `subjectId` UUID column above remains for read paths
    // that haven't been migrated to the relationship. `pages` is
    // owned here with cascade delete; its inverse on `Page.notebook`
    // closes the loop CloudKit Database requires.
    @Relationship var subject: Subject?

    @Relationship(deleteRule: .cascade, inverse: \Page.notebook)
    var pages: [Page]?

    // MARK: Init
    init(
        title: String,
        subjectId: UUID?,
        coverColorHex: String,
        coverTexture: CoverTexture = .none,
        pageSize: PageSize = .a4,
        defaultTemplate: PageTemplate = .blank
    ) {
        self.id              = UUID()
        self.title           = title
        self.subjectId       = subjectId
        self.folderId        = nil
        self.coverColorHex   = coverColorHex
        self.coverTexture    = coverTexture
        self.sortOrder          = 0
        self.isPinned           = false
        self.tagsRaw            = ""
        self.pageSize           = pageSize
        self.defaultTemplateRaw = defaultTemplate.jsonString
        self.totalPageCount  = 0
        self.thumbnailData   = nil
        self.createdAt       = Date()
        self.updatedAt       = Date()
        self.isDeleted       = false
        self.deletedAt       = nil
    }
}
