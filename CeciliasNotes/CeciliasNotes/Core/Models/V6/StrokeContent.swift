import Foundation
import SwiftData

/// PencilKit-backed stroke content for a `PageElement` of kind
/// `.stroke`. Each stroke becomes its own `PageElement` row in V6
/// (see architecture doc §11 — "Approach B with pre-warming"). The
/// per-page render path batches all of a page's stroke rows into a
/// single `PKDrawing` fed to one `PKCanvasView` to preserve
/// PencilKit's rendering performance.
///
/// V6 (Step 1): inert. Strokes still persist via `Page.strokeData`
/// blob until Step 8 migrates onto this row + the
/// `StrokeRenderCache` layer.
///
/// `strokeData` typically fits under CloudKit's 1 MB per-record
/// limit. The rare overflow case falls back to writing the blob to
/// `Documents/MediaAttachments/strokes/<id>.pkd` (iCloud Drive
/// synced) and storing only a file reference — handled at the
/// service layer when Step 8 lands.
@Model
final class StrokeContent {

    var id: UUID = UUID()
    /// Back-reference to the owning element. The forward
    /// relationship + inverse is declared on `PageElement` so this
    /// side is the bare `@Relationship`.
    @Relationship var element: PageElement?

    /// Serialised `PKDrawing` containing a single stroke.
    var strokeData: Data = Data()

    /// Tool family — kept for analytics + future per-tool migrations
    /// (e.g. swapping pen ink for a vector representation). Matches
    /// `Tool` enum raw values where possible.
    var toolKind: String  = ""
    var colorHex: String  = ""
    var widthBase: Double = 0
    var opacity: Double   = 1.0

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        strokeData: Data = Data(),
        toolKind: String = "",
        colorHex: String = "",
        widthBase: Double = 0,
        opacity: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id         = id
        self.strokeData = strokeData
        self.toolKind   = toolKind
        self.colorHex   = colorHex
        self.widthBase  = widthBase
        self.opacity    = opacity
        self.createdAt  = createdAt
        self.updatedAt  = updatedAt
    }
}
