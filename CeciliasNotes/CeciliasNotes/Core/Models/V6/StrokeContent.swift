import Foundation
import SwiftData

/// PencilKit-backed stroke content for a `PageElement` of kind
/// `.stroke`. Step 8 promoted this from inert to the single source
/// of truth — `Page.strokeData` is gone; every page now has at
/// most one `PageElement(.stroke)` whose `StrokeContent.strokeData`
/// holds the serialised `PKDrawing` for the entire page.
///
/// **One PageElement per page.** PencilKit already manages strokes
/// as a single `PKDrawing` (a collection of `PKStroke`); the
/// natural unit of the unified model is the collection. Per-stroke
/// operations (lasso selection, individual delete) happen at the
/// `PKDrawing` level inside the data blob — Step 9 wires that.
///
/// **Performance.** Writes are debounced (1.2s after the last
/// canvas-draw event). The `StrokeCache` (Step 8) keeps the
/// in-memory `PKDrawing` for the N most-recently-viewed pages so
/// page navigation doesn't decode + re-render on every swipe.
///
/// `strokeData` typically fits under CloudKit's 1 MB per-record
/// limit. The rare overflow case falls back to writing the blob to
/// `Documents/MediaAttachments/strokes/<id>.pkd` (iCloud Drive
/// synced) and storing only a file reference — handled at the
/// service layer when overflow surfaces in practice.
@Model
final class StrokeContent {

    var id: UUID = UUID()
    /// Back-reference to the owning element. The forward
    /// relationship + inverse is declared on `PageElement` so this
    /// side is the bare `@Relationship`.
    @Relationship var element: PageElement?

    /// Serialised `PKDrawing` containing every stroke on the page.
    /// Empty `Data()` for a freshly-created page with no strokes.
    var strokeData: Data = Data()

    /// Tool family — the *last tool used* hint for analytics +
    /// future per-tool migrations. Multi-tool drawings (the common
    /// case after Step 8) make this approximate; it's a hint, not
    /// a source of truth. Matches `Tool` enum raw values where
    /// possible.
    var toolKind: String  = ""

    /// Legacy per-stroke metadata fields from the original
    /// "one PageElement per stroke" design intent. Step 8 batched
    /// every stroke on a page into one `PageElement`; these no
    /// longer carry meaningful per-page values. Default to zero/
    /// empty and ignore in render — kept on the schema so the V6
    /// container doesn't have to wipe for the field removal.
    var colorHex: String  = ""
    var widthBase: Double = 0
    var opacity: Double   = 1.0

    /// Disk filename of an optional preview PNG used by the cache
    /// subsystem for fast first-paint while the full PKDrawing
    /// decodes. `nil` when no preview has been generated.
    /// Lives under `Documents/MediaAttachments/strokes/previews/<filename>`.
    var previewFilename: String? = nil

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        strokeData: Data = Data(),
        toolKind: String = "",
        colorHex: String = "",
        widthBase: Double = 0,
        opacity: Double = 1.0,
        previewFilename: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id              = id
        self.strokeData      = strokeData
        self.toolKind        = toolKind
        self.colorHex        = colorHex
        self.widthBase       = widthBase
        self.opacity         = opacity
        self.previewFilename = previewFilename
        self.createdAt       = createdAt
        self.updatedAt       = updatedAt
    }
}
