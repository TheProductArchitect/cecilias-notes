import Foundation
import SwiftData

/// Discriminator for the polymorphic `PageElement` shape. Each case
/// corresponds to exactly one populated `*Content` relationship on
/// `PageElement`. New element kinds (e.g. embedded videos, math
/// blocks) get a new case + a new content entity + a new
/// `PageElementRenderer` switch arm — no other schema change.
///
/// `.shape` ships in the V6 schema so adding the shape tool later
/// (post-1.0) is a feature change, not a migration.
enum ElementKind: String, Codable, CaseIterable {
    case stroke
    case image
    case audio
    case text
    case stickyNote
    case pdfPage
    case shape
}

/// The unified per-element row. Every visible thing on a page —
/// strokes, images, audio strips, text blocks, sticky notes,
/// embedded PDF pages, future shapes — is a `PageElement` keyed by
/// `pageId` with one populated `*Content` relationship determined by
/// `kind`. Rendering a page = one SwiftData query for elements
/// matching `pageId`, sorted by `zIndex`, switched on `kind`.
///
/// V6 (Step 1): entity declared but inert. No view code reads or
/// writes `PageElement` yet — Steps 2-9 migrate the per-primitive
/// stores (text, image, audio, sticky, PDF, stroke) onto this row
/// in order. The V5 entities (TextBlock, ImageRecord, AudioRecord,
/// LectureRecord) keep serving rendering until their substep ships.
///
/// CloudKit compatibility (mirrors LectureRecord / AudioRecord /
/// ImageRecord conventions in `Core/Models/`):
///   • Every non-optional property has an inline default.
///   • No `@Attribute(.unique)` — CloudKit rejects unique
///     constraints at schema registration; UUID() avoids collisions.
///   • One-to-one cascade relationships to the 7 content entities;
///     the `inverse:` is declared here so the content side just
///     carries a bare `@Relationship var element: PageElement?`.
@Model
final class PageElement {

    var id: UUID = UUID()
    var pageId: UUID = UUID()
    /// Denormalised so a notebook reaper can sweep without joining
    /// through Page — same pattern as `AudioRecord.notebookId`.
    var notebookId: UUID = UUID()

    /// Discriminator. Exactly one `*Content` relationship below is
    /// non-nil and matches this kind. Stored as `String` raw value
    /// via Codable so CloudKit serialises it cleanly.
    var kind: ElementKind = ElementKind.text

    // MARK: Layout — normalised top-left-origin [0,1]^2 page space
    var normalizedX: Double      = 0
    var normalizedY: Double      = 0
    var normalizedWidth: Double  = 0
    var normalizedHeight: Double = 0

    /// Free rotation in radians (consistent with `TextBlock.rotation`).
    var rotation: Double = 0
    /// Stacking order within the page. Higher = drawn on top.
    var zIndex: Int      = 0
    /// 0.0 … 1.0
    var opacity: Double  = 1.0
    /// User-locked → ignored by hit-test, can't be moved/resized.
    var isLocked: Bool   = false

    // MARK: Polymorphic content — exactly one is non-nil per `kind`
    @Relationship(deleteRule: .cascade, inverse: \StrokeContent.element)
    var strokeContent: StrokeContent?
    @Relationship(deleteRule: .cascade, inverse: \ImageContent.element)
    var imageContent: ImageContent?
    @Relationship(deleteRule: .cascade, inverse: \AudioContent.element)
    var audioContent: AudioContent?
    @Relationship(deleteRule: .cascade, inverse: \TextContent.element)
    var textContent: TextContent?
    @Relationship(deleteRule: .cascade, inverse: \StickyNoteContent.element)
    var stickyNoteContent: StickyNoteContent?
    @Relationship(deleteRule: .cascade, inverse: \PDFPageContent.element)
    var pdfPageContent: PDFPageContent?
    @Relationship(deleteRule: .cascade, inverse: \ShapeContent.element)
    var shapeContent: ShapeContent?

    // MARK: Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Soft-delete stamp. `nil` = active; non-nil = in Trash.
    /// Trash UI is post-1.0; the column ships now so V7 doesn't need
    /// a migration when the feature lands. Background auto-purge
    /// after 30 days runs on app launch.
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        pageId: UUID,
        notebookId: UUID,
        kind: ElementKind,
        normalizedX: Double = 0,
        normalizedY: Double = 0,
        normalizedWidth: Double = 0,
        normalizedHeight: Double = 0,
        rotation: Double = 0,
        zIndex: Int = 0,
        opacity: Double = 1.0,
        isLocked: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id               = id
        self.pageId           = pageId
        self.notebookId       = notebookId
        self.kind             = kind
        self.normalizedX      = normalizedX
        self.normalizedY      = normalizedY
        self.normalizedWidth  = normalizedWidth
        self.normalizedHeight = normalizedHeight
        self.rotation         = rotation
        self.zIndex           = zIndex
        self.opacity          = opacity
        self.isLocked         = isLocked
        self.createdAt        = createdAt
        self.updatedAt        = updatedAt
        self.deletedAt        = deletedAt
    }
}
