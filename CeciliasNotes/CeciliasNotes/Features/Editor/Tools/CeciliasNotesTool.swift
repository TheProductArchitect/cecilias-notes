import Foundation
import PencilKit
import SwiftUI
import UIKit

// MARK: - CeciliasNotesTool

/// User-facing tool model. Maps to a `PKTool` in `CanvasContainerView`.
/// Associated values are the *current* settings; defaults live in `CeciliasNotesTool.defaults`.
enum CeciliasNotesTool: Equatable {
    /// Neutral interaction mode — selects / edits existing content
    /// without producing strokes. Step 2 of the unified PageElement
    /// migration: lands the cursor concept so subsequent steps can
    /// lean on it (text editing in Step 3, image selection unified
    /// with cursor, etc.). Carries no colour / width / opacity.
    case cursor
    // Inking — each maps to a PKInkingTool ink type.
    case pen(colour: UIColor, width: CGFloat, opacity: CGFloat)
    case fountainPen(colour: UIColor, width: CGFloat, opacity: CGFloat)
    case monoline(colour: UIColor, width: CGFloat)
    case marker(colour: UIColor, width: CGFloat)
    case brush(colour: UIColor, width: CGFloat, opacity: CGFloat)
    case crayon(colour: UIColor, width: CGFloat)
    case pencil(colour: UIColor, width: CGFloat, opacity: CGFloat)
    case highlighter(colour: UIColor, width: CGFloat)
    // Modes
    case eraser(mode: EraserMode)
    case lasso
    case ruler
    case text                   // finger-driven text block mode
    /// Tap-to-place sticky note. Only surfaced in the palette when
    /// the active notebook is PDF-backed — non-PDF notebooks have
    /// inline text via the existing `.text` tool.
    case stickyNote
    /// Image-attachment tool. Tap-to-place on the canvas (any
    /// notebook, PDF-backed or not). Tap presents the import
    /// picker (camera / photo library / files). When active,
    /// existing image attachments become selectable for move /
    /// resize / 90° rotate / soft-delete — switching to any other
    /// tool deselects and makes images inert again.
    case image
    /// Shape tool. Drag on the canvas to create a parametric
    /// `PageElement` of kind `.shape` with the chosen `ShapeKind`.
    /// Selectable / resizable / recolourable like text & image
    /// elements (post-creation interactions added incrementally).
    case shape(kind: ShapeKind)

    enum Identity: String, CaseIterable, Codable {
        case cursor
        case pen, fountainPen, monoline, marker, brush, crayon, pencil, highlighter
        case eraser, lasso, ruler, text, stickyNote, image, shape

        var systemImage: String {
            switch self {
            case .cursor:                   return "cursorarrow"
            case .pen:                      return "pencil.tip"
            case .fountainPen:              return "applepencil.tip"
            case .monoline:                 return "scribble"
            case .marker:                   return "paintbrush.pointed"
            case .brush:                    return "paintbrush"
            case .crayon:                   return "pencil.tip.crop.circle"
            case .pencil:                   return "pencil"
            case .highlighter:              return "highlighter"
            case .eraser:                   return "eraser"
            case .lasso:                    return "lasso"
            case .ruler:                    return "ruler"
            case .text:                     return "text.cursor"
            case .stickyNote:               return "note.text"
            case .image:                    return "photo.on.rectangle"
            case .shape:                    return "square.on.circle"
            }
        }

        var displayName: String {
            switch self {
            case .cursor:                   return "Cursor"
            case .pen:                      return "Pen"
            case .fountainPen:              return "Fountain Pen"
            case .monoline:                 return "Monoline"
            case .marker:                   return "Marker"
            case .brush:                    return "Brush"
            case .crayon:                   return "Crayon"
            case .pencil:                   return "Pencil"
            case .highlighter:              return "Highlighter"
            case .eraser:                   return "Eraser"
            case .lasso:                    return "Lasso"
            case .ruler:                    return "Ruler"
            case .text:                     return "Text"
            case .stickyNote:               return "Sticky Note"
            case .image:                    return "Image"
            case .shape:                    return "Shape"
            }
        }
    }

    var identity: Identity {
        switch self {
        case .cursor:                   return .cursor
        case .pen:                      return .pen
        case .fountainPen:              return .fountainPen
        case .monoline:                 return .monoline
        case .marker:                   return .marker
        case .brush:                    return .brush
        case .crayon:                   return .crayon
        case .pencil:                   return .pencil
        case .highlighter:              return .highlighter
        case .eraser:                   return .eraser
        case .lasso:                    return .lasso
        case .ruler:                    return .ruler
        case .text:                     return .text
        case .stickyNote:               return .stickyNote
        case .image:                    return .image
        case .shape:                    return .shape
        }
    }

    /// True when the active tool is the highlighter. The stroke-end
    /// hook in `EditorViewModel` uses this to decide whether to
    /// attempt PDF text detection on the just-committed stroke.
    var isHighlighterFamily: Bool {
        switch self {
        case .highlighter: return true
        default:           return false
        }
    }

    /// Maps the highlighter tool to the corresponding V6
    /// `HighlightStyle`. Returns `nil` for non-highlighter tools.
    /// Only `.highlight` is mapped — underline / strikethrough
    /// variants were retired in the variant-collapse pass.
    var pdfHighlightStyle: HighlightStyle? {
        switch self {
        case .highlighter: return .highlight
        default:           return nil
        }
    }

    var systemImage: String { identity.systemImage }

    /// Tools that have an editable colour swatch.
    var hasColour: Bool {
        switch self {
        case .pen, .fountainPen, .monoline, .marker, .brush, .crayon, .pencil,
             .highlighter:
            return true
        case .cursor, .eraser, .lasso, .ruler, .text, .stickyNote, .image, .shape:
            return false
        }
    }

    /// Tools that have an editable width.
    var hasWidth: Bool {
        switch self {
        case .pen, .fountainPen, .monoline, .marker, .brush, .crayon, .pencil,
             .highlighter:
            return true
        // Pixel eraser used to expose a width slider in the
        // floating palette; spec retired the configurability, so
        // every eraser mode now reports `hasWidth = false`.
        case .eraser:                                  return false
        case .cursor, .lasso, .ruler, .text, .stickyNote, .image, .shape: return false
        }
    }

    /// Tools that support an editable opacity slider.
    /// Marker/crayon/monoline are full-opacity by design.
    /// Highlighter is fixed at 40%.
    var hasOpacity: Bool {
        switch self {
        case .pen, .fountainPen, .brush, .pencil:    return true
        default:                                     return false
        }
    }

    var currentColour: UIColor {
        switch self {
        case .pen(let c, _, _),
             .fountainPen(let c, _, _),
             .brush(let c, _, _),
             .pencil(let c, _, _):                    return c
        case .monoline(let c, _),
             .marker(let c, _),
             .crayon(let c, _),
             .highlighter(let c, _):                  return c
        // D2 fallback: this method is called from non-SwiftUI contexts
        // (sync, any actor) so it can't read @Environment(\.theme).
        // UIColor.label is the UIKit-side adaptive text colour — same
        // visual behaviour as theme.foreground would give in a SwiftUI
        // context. Used for the eraser/lasso/ruler/text "no associated
        // colour" tools as a placeholder; never paints a real stroke.
        default:                                      return .label
        }
    }

    var currentWidth: CGFloat {
        switch self {
        case .pen(_, let w, _),
             .fountainPen(_, let w, _),
             .brush(_, let w, _),
             .pencil(_, let w, _):                   return w
        case .monoline(_, let w),
             .marker(_, let w),
             .crayon(_, let w),
             .highlighter(_, let w):                 return w
        // Pixel eraser width is no longer user-configurable — the
        // dedicated Settings slider was removed and `hasWidth` is
        // now false for `.eraser(.pixel)`, so the floating
        // toolbar's size buttons stop affecting it. `makePKTool`
        // hardcodes the PencilKit-default-equivalent width.
        default:                                     return 0
        }
    }

    var currentOpacity: CGFloat {
        switch self {
        case .pen(_, _, let o),
             .fountainPen(_, _, let o),
             .brush(_, _, let o),
             .pencil(_, _, let o):                  return o
        case .highlighter:                          return 0.4
        default:                                    return 1.0
        }
    }

    var isTextMode: Bool {
        if case .text = self { return true }
        return false
    }

    /// True when the active tool is the neutral cursor — used by
    /// overlays that should accept finger interaction without the
    /// tool-specific placement behaviours (no image picker on tap,
    /// no new sticky on tap, etc.).
    var isCursorMode: Bool {
        if case .cursor = self { return true }
        return false
    }

    /// Tools that act on the PKCanvasView. `.cursor` yields the
    /// canvas to overlays — the whole point of the neutral mode.
    /// `.text` is finger-driven inline text; `.stickyNote` is
    /// finger-driven tap-to-place on PDF-backed pages. Step 9:
    /// `.lasso` moved from PKLassoTool (canvas-internal) to the
    /// custom V6 lasso overlay, so it yields the canvas the same
    /// way `.cursor` does. None of these produce PencilKit strokes.
    var isDrawingTool: Bool {
        switch self {
        case .cursor, .text, .stickyNote, .image, .lasso, .shape: return false
        default:                                                   return true
        }
    }

    /// True when the active tool is the parametric shape tool.
    /// The canvas yields touches to the SwiftUI shape overlay so
    /// the drag-to-create gesture can capture them.
    var isShapeMode: Bool {
        if case .shape = self { return true }
        return false
    }

    /// Currently-selected `ShapeKind` when `isShapeMode` is true;
    /// nil otherwise. Used by the overlay to know which shape to
    /// instantiate on drag-release.
    var currentShapeKind: ShapeKind? {
        if case .shape(let kind) = self { return kind }
        return nil
    }

    /// True when the active tool is the image-attachment placement
    /// tool. The canvas overlay reads this to enable the image
    /// import / selection layer; every other tool leaves images
    /// inert.
    var isImageMode: Bool {
        if case .image = self { return true }
        return false
    }

    /// True when the active tool is the sticky-note placement tool.
    /// The canvas overlay reads this to switch into placement mode
    /// (tap-anywhere creates a note); when false, only existing
    /// markers are hittable for editing.
    var isStickyNoteMode: Bool {
        if case .stickyNote = self { return true }
        return false
    }

    /// True when the active tool is the lasso. Step 9: the lasso
    /// overlay reads this to capture drag gestures + render the
    /// in-flight lasso path. The canvas is non-interactive in
    /// this mode (see `isDrawingTool`), so all finger input
    /// reaches the SwiftUI overlay layer cleanly.
    var isLassoMode: Bool {
        if case .lasso = self { return true }
        return false
    }

    /// Tools that let the user select & manipulate existing images
    /// on the page (handles, drag, resize, rotate, delete). Today
    /// `.image` (full power including new-image placement on empty
    /// taps) and `.cursor` (Step 2's neutral interaction mode —
    /// selects existing images but does NOT open the picker on an
    /// empty tap). Kept separate from `isImageMode` because the
    /// placement-on-empty-tap behaviour is `.image`-only.
    var allowsImageSelection: Bool {
        switch self {
        case .cursor, .image: return true
        default:              return false
        }
    }

    /// Images are interactive (selectable/moveable) only in non-canvas modes (text).
    var isMediaInteractive: Bool { !isDrawingTool }

    // MARK: Mutators

    func withColour(_ colour: UIColor) -> CeciliasNotesTool {
        switch self {
        case .pen(_, let w, let o):          return .pen(colour: colour, width: w, opacity: o)
        case .fountainPen(_, let w, let o):  return .fountainPen(colour: colour, width: w, opacity: o)
        case .monoline(_, let w):            return .monoline(colour: colour, width: w)
        case .marker(_, let w):              return .marker(colour: colour, width: w)
        case .brush(_, let w, let o):        return .brush(colour: colour, width: w, opacity: o)
        case .crayon(_, let w):              return .crayon(colour: colour, width: w)
        case .pencil(_, let w, let o):       return .pencil(colour: colour, width: w, opacity: o)
        case .highlighter(_, let w):         return .highlighter(colour: colour, width: w)
        default:                             return self
        }
    }

    func withWidth(_ width: CGFloat) -> CeciliasNotesTool {
        let clamped = max(0.5, min(20, width))
        switch self {
        case .pen(let c, _, let o):          return .pen(colour: c, width: clamped, opacity: o)
        case .fountainPen(let c, _, let o):  return .fountainPen(colour: c, width: clamped, opacity: o)
        case .monoline(let c, _):            return .monoline(colour: c, width: clamped)
        case .marker(let c, _):              return .marker(colour: c, width: clamped)
        case .brush(let c, _, let o):        return .brush(colour: c, width: clamped, opacity: o)
        case .crayon(let c, _):              return .crayon(colour: c, width: clamped)
        case .pencil(let c, _, let o):       return .pencil(colour: c, width: clamped, opacity: o)
        case .highlighter(let c, _):         return .highlighter(colour: c, width: clamped)
        default:                             return self
        }
    }

    func withOpacity(_ opacity: CGFloat) -> CeciliasNotesTool {
        let clamped = max(0.1, min(1.0, opacity))
        switch self {
        case .pen(let c, let w, _):          return .pen(colour: c, width: w, opacity: clamped)
        case .fountainPen(let c, let w, _):  return .fountainPen(colour: c, width: w, opacity: clamped)
        case .brush(let c, let w, _):        return .brush(colour: c, width: w, opacity: clamped)
        case .pencil(let c, let w, _):       return .pencil(colour: c, width: w, opacity: clamped)
        default:                             return self
        }
    }

    // MARK: Defaults

    enum Defaults {
        /// Default ink colour for a fresh stroke. Reads from the theme so
        /// switching themes affects new strokes; existing strokes keep
        /// their stored colour (Step 1 territory once strokes become
        /// PageElements).
        private static func defaultInk(_ theme: Theme) -> UIColor {
            UIColor(theme.defaultInkColor)
        }

        static func pen(theme: Theme) -> CeciliasNotesTool {
            .pen(colour: defaultInk(theme), width: 2, opacity: 1.0)
        }
        static func fountainPen(theme: Theme) -> CeciliasNotesTool {
            .fountainPen(colour: defaultInk(theme), width: 2, opacity: 1.0)
        }
        static func monoline(theme: Theme) -> CeciliasNotesTool {
            .monoline(colour: defaultInk(theme), width: 2)
        }
        static func marker(theme: Theme) -> CeciliasNotesTool {
            .marker(colour: defaultInk(theme), width: 6)
        }
        static func brush(theme: Theme) -> CeciliasNotesTool {
            .brush(colour: defaultInk(theme), width: 6, opacity: 0.85)
        }
        static func crayon(theme: Theme) -> CeciliasNotesTool {
            .crayon(colour: defaultInk(theme), width: 5)
        }
        static func pencil(theme: Theme) -> CeciliasNotesTool {
            .pencil(colour: defaultInk(theme), width: 3, opacity: 1.0)
        }
        static let highlighter: CeciliasNotesTool = .highlighter(colour: UIColor(hex: "#FFD60A"), width: 12)
        static let eraser: CeciliasNotesTool = .eraser(mode: .wholeStroke)
        static let lasso: CeciliasNotesTool = .lasso
        static let ruler: CeciliasNotesTool = .ruler
        static let text: CeciliasNotesTool  = .text
        static let stickyNote: CeciliasNotesTool = .stickyNote
        static let image: CeciliasNotesTool = .image
        static let cursor: CeciliasNotesTool = .cursor

        /// Build a default for any identity. Used by the palette when the
        /// per-tool persistence has nothing stored for that identity yet.
        static func forIdentity(_ id: Identity, theme: Theme) -> CeciliasNotesTool {
            switch id {
            case .cursor:       return cursor
            case .pen:          return pen(theme: theme)
            case .fountainPen:  return fountainPen(theme: theme)
            case .monoline:     return monoline(theme: theme)
            case .marker:       return marker(theme: theme)
            case .brush:        return brush(theme: theme)
            case .crayon:       return crayon(theme: theme)
            case .pencil:       return pencil(theme: theme)
            case .highlighter:              return highlighter
            case .eraser:       return eraser
            case .lasso:        return lasso
            case .ruler:        return ruler
            case .text:         return text
            case .stickyNote:   return stickyNote
            case .image:        return image
            // No persisted-per-identity default for shapes — the
            // last-used ShapeKind is restored from UserDefaults by
            // the tool palette directly.
            case .shape:        return .shape(kind: .rectangle)
            }
        }
    }

    // MARK: PKTool mapping

    /// Builds the `PKTool` corresponding to this CeciliasNotesTool.
    /// Note: `.ruler` is not a PKTool — it toggles `canvasView.isRulerActive`.
    func makePKTool() -> PKTool {
        switch self {
        case .pen(let c, let w, let opacity):
            return PKInkingTool(.pen, color: c.withAlphaComponent(opacity), width: w)
        case .fountainPen(let c, let w, let opacity):
            // PKInkingTool.InkType.fountainPen is iOS 17+ — pressure-sensitive
            // width modulation tied to stroke speed/pressure.
            return PKInkingTool(.fountainPen, color: c.withAlphaComponent(opacity), width: w)
        case .monoline(let c, let w):
            // Constant-width pen with no pressure response.
            return PKInkingTool(.monoline, color: c, width: w)
        case .marker(let c, let w):
            // Chunky, full-opacity, no pressure variation.
            return PKInkingTool(.marker, color: c, width: w)
        case .brush(let c, let w, let opacity):
            // iOS 17+ watercolour brush — soft edges, opacity buildup.
            return PKInkingTool(.watercolor, color: c.withAlphaComponent(opacity), width: w)
        case .crayon(let c, let w):
            // Textured wax-crayon look (iOS 17+).
            return PKInkingTool(.crayon, color: c, width: w)
        case .pencil(let c, let w, let opacity):
            return PKInkingTool(.pencil, color: c.withAlphaComponent(opacity), width: w)
        case .highlighter(let c, let w):
            // Spec: highlighter is colour at 40% alpha (fixed). Marker ink type
            // gives the chunky chisel feel a highlighter expects.
            //
            // On PDF-backed pages the stroke-end hook tries to detect
            // selectable text under the stroke and replaces the
            // PencilKit ink with a `PDFTextAnnotationRecord(.highlight)`.
            // Outside that detection path the stroke stays as the
            // visible mark.
            return PKInkingTool(.marker, color: c.withAlphaComponent(0.4), width: w)
        case .eraser(.pixel):
            // Width is configurable again — driven by the slider
            // in the eraser popover, persisted under the shared
            // `ceciliasnotes.eraser.pixelSize` key. Defaults to
            // 24pt (PencilKit's bitmap-eraser convention) when
            // the key is absent or zero.
            let raw = UserDefaults.standard.double(forKey: "ceciliasnotes.eraser.pixelSize")
            let width = raw > 0 ? CGFloat(raw) : 24
            return PKEraserTool(.bitmap, width: width)
        case .eraser(.wholeStroke):
            return PKEraserTool(.vector)
        case .eraser(.page):
            return PKInkingTool(.pen, color: .clear, width: 1)
        case .cursor, .ruler, .text, .stickyNote, .image, .lasso, .shape:
            // `.cursor` and `.image` produce no strokes — same dummy
            // PKTool as the other finger-driven modes. The canvas-
            // overlay layer handles tap-to-place + selection above
            // the PKCanvasView, and `canvasIsInteractive` is false
            // anyway so the canvas never sees finger input.
            return PKInkingTool(.pen, color: .clear, width: 1)
        }
    }
}

// MARK: - EraserMode

enum EraserMode: String, Codable, CaseIterable {
    case wholeStroke   // PKEraserTool(.vector) — default; tap any part erases full stroke
    case pixel         // PKEraserTool(.bitmap, width:) — pixel-tip eraser
    case page          // one-shot: clears the entire PKDrawing on this page

    var displayName: String {
        switch self {
        case .wholeStroke: return "Whole Stroke"
        case .pixel:       return "Pixel Eraser"
        case .page:        return "Erase Page"
        }
    }

    var iconName: String {
        switch self {
        case .wholeStroke: return "eraser"
        case .pixel:       return "eraser.line.dashed"
        case .page:        return "trash"
        }
    }
}

// MARK: - PencilDoubleTapAction

enum PencilDoubleTapAction: String, CaseIterable, Codable {
    case switchTool
    case toggleEraser
    case showColorPicker
    case doNothing

    var displayName: String {
        switch self {
        case .switchTool:       return "Switch Between Two Tools"
        case .toggleEraser:     return "Switch to Eraser"
        case .showColorPicker:  return "Show Colour Picker"
        case .doNothing:        return "Off"
        }
    }

    /// Mapped from the user's system-wide preference if available.
    static func from(_ system: UIPencilPreferredAction) -> PencilDoubleTapAction? {
        switch system {
        case .ignore:           return .doNothing
        case .switchEraser:     return .toggleEraser
        case .switchPrevious:   return .switchTool
        case .showColorPalette: return .showColorPicker
        // Covers .runSystemShortcut, .showInkAttributes (iOS 17.5+) and any future cases.
        default:                return nil
        }
    }
}
