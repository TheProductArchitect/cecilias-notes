import Foundation
import SwiftData

/// Visual variant of a highlight. The legacy
/// `PDFTextAnnotationStore` supported three styles; Step 5.5
/// preserves all three behind a single `.highlight` ElementKind
/// rather than minting three kinds — the architectural unit
/// ("mark on PDF text") is the same, only the rendering differs.
enum HighlightStyle: String, Codable, CaseIterable, Sendable {
    /// Translucent fill over the selected text region — the default.
    case highlight
    /// 1.5pt stroke along the bottom edge of the selection.
    case underline
    /// 1.5pt stroke across the vertical midpoint of the selection.
    case strikethrough
}

/// Content for a `PageElement` of kind `.highlight`. Each highlight
/// is one rectangle in normalised PDF-page coordinates; a single
/// user-visible multi-line text selection becomes one
/// `HighlightContent` per line (per rect), grouped via `groupId` so
/// they can be selected / deleted as a logical unit.
///
/// Highlights are tied to a specific PDF page through
/// `pdfPageContentId`. The renderer (`HighlightElementView`) keeps
/// the rect in PDF coordinates and the host overlay
/// (`HighlightElementsOverlayView`) does the PDF → page-canvas
/// projection at draw time. Without the projection the rectangle
/// would always paint at the same absolute on-screen position
/// regardless of how the PDF page sits inside its `PageElement`
/// bounds (which can be resized / moved in Workflow B).
///
/// Step 5.5 (architecture §15): replaces `PDFTextAnnotationStore`
/// + `PDFTextAnnotationRecord`. Same data fields preserved
/// (rect, style, captured text, soft-delete) — now lives on
/// SwiftData inside the unified element model.
@Model
final class HighlightContent {

    var id: UUID = UUID()
    @Relationship var element: PageElement?

    /// The `PDFPageContent.id` this highlight is anchored to.
    /// Soft-deletes on the parent PDF page propagate at query time
    /// (the overlay filters out highlights whose pdfPageContent is
    /// gone) — not a SwiftData cascade because PDF pages and
    /// highlights are separate PageElement rows.
    var pdfPageContentId: UUID = UUID()

    /// Bounds of the highlighted region in normalised PDF-page
    /// coordinates ([0, 1]^2, top-left origin). Mirrors the legacy
    /// `PDFTextAnnotationRecord.normalizedBounds` shape exactly.
    var rectOriginX: Double = 0
    var rectOriginY: Double = 0
    var rectWidth: Double = 0
    var rectHeight: Double = 0

    /// Group identifier for multi-line highlights. Nil means
    /// standalone (single-line selection). When non-nil, the editor's
    /// soft-delete handler removes every `HighlightContent` row with
    /// the same `groupId` as one user action.
    var groupId: UUID? = nil

    /// Visual variant. See `HighlightStyle`.
    var style: HighlightStyle = HighlightStyle.highlight

    /// Theme-palette key (e.g. `"yellow"`, `"pink"`, `"blue"`,
    /// `"green"`). The renderer resolves to `Color` via
    /// `theme.highlightPalette[colorVariant]` — palette swap during
    /// a theme change re-tints highlights without touching the row.
    var colorVariant: String = "yellow"

    /// The text the user actually highlighted, captured at creation
    /// time. Backs search, the customise panel's annotation list,
    /// accessibility labels, and AI features (1.1+). Optional
    /// because `attemptHighlighterTextDetection` can fail to extract
    /// text from rasterised PDFs even when the highlight lands on
    /// visible glyphs.
    var capturedText: String? = nil

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        pdfPageContentId: UUID,
        rectOriginX: Double,
        rectOriginY: Double,
        rectWidth: Double,
        rectHeight: Double,
        style: HighlightStyle = .highlight,
        colorVariant: String = "yellow",
        groupId: UUID? = nil,
        capturedText: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id               = id
        self.pdfPageContentId = pdfPageContentId
        self.rectOriginX      = rectOriginX
        self.rectOriginY      = rectOriginY
        self.rectWidth        = rectWidth
        self.rectHeight       = rectHeight
        self.style            = style
        self.colorVariant     = colorVariant
        self.groupId          = groupId
        self.capturedText     = capturedText
        self.createdAt        = createdAt
        self.updatedAt        = updatedAt
    }
}
