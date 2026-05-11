import Foundation
import PencilKit
import UIKit

// MARK: - InkTool

/// User-facing tool model. Maps to a `PKTool` in `CanvasContainerView`.
/// Associated values are the *current* settings; defaults live in `InkTool.defaults`.
enum InkTool: Equatable {
    // Inking — each maps to a PKInkingTool ink type.
    case pen(colour: UIColor, width: CGFloat, opacity: CGFloat)
    case fountainPen(colour: UIColor, width: CGFloat, opacity: CGFloat)
    case monoline(colour: UIColor, width: CGFloat)
    case marker(colour: UIColor, width: CGFloat)
    case brush(colour: UIColor, width: CGFloat, opacity: CGFloat)
    case crayon(colour: UIColor, width: CGFloat)
    case pencil(colour: UIColor, width: CGFloat, opacity: CGFloat)
    case highlighter(colour: UIColor, width: CGFloat)
    /// Underline-text variant of the highlighter family. On a
    /// PDF-backed page with selectable text under the stroke, the
    /// editor intercepts the stroke and creates a
    /// `PDFTextAnnotationRecord(type: .underline)` instead of
    /// committing PencilKit ink. On non-PDF pages, or when no text
    /// is detected, it falls back to a marker stroke at 40% alpha.
    case highlighterUnderline(colour: UIColor, width: CGFloat)
    /// Strikethrough-text variant — same interception logic, type
    /// `.strikethrough`.
    case highlighterStrikethrough(colour: UIColor, width: CGFloat)
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

    enum Identity: String, CaseIterable, Codable {
        case pen, fountainPen, monoline, marker, brush, crayon, pencil, highlighter
        case highlighterUnderline, highlighterStrikethrough
        case eraser, lasso, ruler, text, stickyNote, image

        var systemImage: String {
            switch self {
            case .pen:                      return "pencil.tip"
            case .fountainPen:              return "applepencil.tip"
            case .monoline:                 return "scribble"
            case .marker:                   return "paintbrush.pointed"
            case .brush:                    return "paintbrush"
            case .crayon:                   return "pencil.tip.crop.circle"
            case .pencil:                   return "pencil"
            case .highlighter:              return "highlighter"
            case .highlighterUnderline:     return "underline"
            case .highlighterStrikethrough: return "strikethrough"
            case .eraser:                   return "eraser"
            case .lasso:                    return "lasso"
            case .ruler:                    return "ruler"
            case .text:                     return "text.cursor"
            case .stickyNote:               return "note.text"
            case .image:                    return "photo.on.rectangle"
            }
        }

        var displayName: String {
            switch self {
            case .pen:                      return "Pen"
            case .fountainPen:              return "Fountain Pen"
            case .monoline:                 return "Monoline"
            case .marker:                   return "Marker"
            case .brush:                    return "Brush"
            case .crayon:                   return "Crayon"
            case .pencil:                   return "Pencil"
            case .highlighter:              return "Highlighter"
            case .highlighterUnderline:     return "Underline"
            case .highlighterStrikethrough: return "Strikethrough"
            case .eraser:                   return "Eraser"
            case .lasso:                    return "Lasso"
            case .ruler:                    return "Ruler"
            case .text:                     return "Text"
            case .stickyNote:               return "Sticky Note"
            case .image:                    return "Image"
            }
        }
    }

    var identity: Identity {
        switch self {
        case .pen:                      return .pen
        case .fountainPen:              return .fountainPen
        case .monoline:                 return .monoline
        case .marker:                   return .marker
        case .brush:                    return .brush
        case .crayon:                   return .crayon
        case .pencil:                   return .pencil
        case .highlighter:              return .highlighter
        case .highlighterUnderline:     return .highlighterUnderline
        case .highlighterStrikethrough: return .highlighterStrikethrough
        case .eraser:                   return .eraser
        case .lasso:                    return .lasso
        case .ruler:                    return .ruler
        case .text:                     return .text
        case .stickyNote:               return .stickyNote
        case .image:                    return .image
        }
    }

    /// True when the active tool is a member of the highlighter
    /// family — base highlighter, underline, or strikethrough. The
    /// stroke-end hook in `EditorViewModel` uses this to decide
    /// whether to attempt PDF text detection on the just-committed
    /// stroke.
    var isHighlighterFamily: Bool {
        switch self {
        case .highlighter, .highlighterUnderline, .highlighterStrikethrough:
            return true
        default:
            return false
        }
    }

    /// Maps a highlighter-family tool to the corresponding
    /// `PDFTextAnnotationType` that should be recorded when text is
    /// detected under the stroke. Returns `nil` for non-highlighter
    /// tools.
    var pdfTextAnnotationType: PDFTextAnnotationType? {
        switch self {
        case .highlighter:              return .highlight
        case .highlighterUnderline:     return .underline
        case .highlighterStrikethrough: return .strikethrough
        default:                        return nil
        }
    }

    var systemImage: String { identity.systemImage }

    /// Tools that have an editable colour swatch.
    var hasColour: Bool {
        switch self {
        case .pen, .fountainPen, .monoline, .marker, .brush, .crayon, .pencil,
             .highlighter, .highlighterUnderline, .highlighterStrikethrough:
            return true
        case .eraser, .lasso, .ruler, .text, .stickyNote, .image:
            return false
        }
    }

    /// Tools that have an editable width.
    var hasWidth: Bool {
        switch self {
        case .pen, .fountainPen, .monoline, .marker, .brush, .crayon, .pencil,
             .highlighter, .highlighterUnderline, .highlighterStrikethrough:
            return true
        case .eraser(.pixel):                          return true
        case .eraser:                                  return false
        case .lasso, .ruler, .text, .stickyNote, .image: return false
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
             .highlighter(let c, _),
             .highlighterUnderline(let c, _),
             .highlighterStrikethrough(let c, _):     return c
        default:                                      return .inkTextPrimary
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
             .highlighter(_, let w),
             .highlighterUnderline(_, let w),
             .highlighterStrikethrough(_, let w):    return w
        case .eraser(.pixel):
            // Session value takes precedence over the Settings default.
            // Session is cleared at app cold-launch; the toolbar size
            // slider writes through to it on every adjustment.
            let session = UserDefaults.standard.double(forKey: "ink.eraser.pixelSize.session")
            if session > 0 { return CGFloat(session) }
            let stored  = UserDefaults.standard.double(forKey: "ink.eraser.pixelSize")
            return stored > 0 ? CGFloat(stored) : 24
        default:                                     return 0
        }
    }

    var currentOpacity: CGFloat {
        switch self {
        case .pen(_, _, let o),
             .fountainPen(_, _, let o),
             .brush(_, _, let o),
             .pencil(_, _, let o):                  return o
        case .highlighter,
             .highlighterUnderline,
             .highlighterStrikethrough:             return 0.4
        default:                                    return 1.0
        }
    }

    var isTextMode: Bool {
        if case .text = self { return true }
        return false
    }

    /// Tools that act on the PKCanvasView. `.text` is finger-driven
    /// inline text; `.stickyNote` is finger-driven tap-to-place on
    /// PDF-backed pages. Neither produces PencilKit strokes.
    var isDrawingTool: Bool {
        switch self {
        case .text, .stickyNote, .image: return false
        default:                         return true
        }
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

    /// Images are interactive (selectable/moveable) only in non-canvas modes (text).
    var isMediaInteractive: Bool { !isDrawingTool }

    // MARK: Mutators

    func withColour(_ colour: UIColor) -> InkTool {
        switch self {
        case .pen(_, let w, let o):          return .pen(colour: colour, width: w, opacity: o)
        case .fountainPen(_, let w, let o):  return .fountainPen(colour: colour, width: w, opacity: o)
        case .monoline(_, let w):            return .monoline(colour: colour, width: w)
        case .marker(_, let w):              return .marker(colour: colour, width: w)
        case .brush(_, let w, let o):        return .brush(colour: colour, width: w, opacity: o)
        case .crayon(_, let w):              return .crayon(colour: colour, width: w)
        case .pencil(_, let w, let o):       return .pencil(colour: colour, width: w, opacity: o)
        case .highlighter(_, let w):         return .highlighter(colour: colour, width: w)
        case .highlighterUnderline(_, let w):
            return .highlighterUnderline(colour: colour, width: w)
        case .highlighterStrikethrough(_, let w):
            return .highlighterStrikethrough(colour: colour, width: w)
        default:                             return self
        }
    }

    func withWidth(_ width: CGFloat) -> InkTool {
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
        case .highlighterUnderline(let c, _):
            return .highlighterUnderline(colour: c, width: clamped)
        case .highlighterStrikethrough(let c, _):
            return .highlighterStrikethrough(colour: c, width: clamped)
        default:                             return self
        }
    }

    func withOpacity(_ opacity: CGFloat) -> InkTool {
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
        private static func inkColour(_ theme: InkTheme) -> UIColor {
            theme == .dark ? UIColor(hex: "#F5F5F2") : UIColor(hex: "#1D1D1B")
        }

        static func pen(theme: InkTheme) -> InkTool {
            .pen(colour: inkColour(theme), width: 2, opacity: 1.0)
        }
        static func fountainPen(theme: InkTheme) -> InkTool {
            .fountainPen(colour: inkColour(theme), width: 2, opacity: 1.0)
        }
        static func monoline(theme: InkTheme) -> InkTool {
            .monoline(colour: inkColour(theme), width: 2)
        }
        static func marker(theme: InkTheme) -> InkTool {
            .marker(colour: inkColour(theme), width: 6)
        }
        static func brush(theme: InkTheme) -> InkTool {
            .brush(colour: inkColour(theme), width: 6, opacity: 0.85)
        }
        static func crayon(theme: InkTheme) -> InkTool {
            .crayon(colour: inkColour(theme), width: 5)
        }
        static func pencil(theme: InkTheme) -> InkTool {
            .pencil(colour: inkColour(theme), width: 3, opacity: 1.0)
        }
        static let highlighter: InkTool = .highlighter(colour: UIColor(hex: "#FFD60A"), width: 12)
        // Underline / strikethrough share the highlighter's colour
        // and width defaults — they're the same family from the
        // user's mental model, just applied with a different mark.
        static let highlighterUnderline: InkTool = .highlighterUnderline(colour: UIColor(hex: "#FFD60A"), width: 12)
        static let highlighterStrikethrough: InkTool = .highlighterStrikethrough(colour: UIColor(hex: "#FFD60A"), width: 12)
        static let eraser: InkTool = .eraser(mode: .wholeStroke)
        static let lasso: InkTool = .lasso
        static let ruler: InkTool = .ruler
        static let text: InkTool  = .text
        static let stickyNote: InkTool = .stickyNote
        static let image: InkTool = .image

        /// Build a default for any identity. Used by the palette when the
        /// per-tool persistence has nothing stored for that identity yet.
        static func forIdentity(_ id: Identity, theme: InkTheme) -> InkTool {
            switch id {
            case .pen:          return pen(theme: theme)
            case .fountainPen:  return fountainPen(theme: theme)
            case .monoline:     return monoline(theme: theme)
            case .marker:       return marker(theme: theme)
            case .brush:        return brush(theme: theme)
            case .crayon:       return crayon(theme: theme)
            case .pencil:       return pencil(theme: theme)
            case .highlighter:              return highlighter
            case .highlighterUnderline:     return highlighterUnderline
            case .highlighterStrikethrough: return highlighterStrikethrough
            case .eraser:       return eraser
            case .lasso:        return lasso
            case .ruler:        return ruler
            case .text:         return text
            case .stickyNote:   return stickyNote
            case .image:        return image
            }
        }
    }

    // MARK: PKTool mapping

    /// Builds the `PKTool` corresponding to this InkTool.
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
        case .highlighter(let c, let w),
             .highlighterUnderline(let c, let w),
             .highlighterStrikethrough(let c, let w):
            // Spec: highlighter is colour at 40% alpha (fixed). Marker ink type
            // gives the chunky chisel feel a highlighter expects.
            //
            // Underline + strikethrough share this PKTool — the visible
            // stroke is the user's drag preview. When the stroke ends
            // over selectable PDF text, the editor intercepts and
            // replaces the stroke with a `PDFTextAnnotationRecord`
            // (see EditorViewModel.handleHighlighterStrokeCompleted).
            // Over non-text regions the stroke stays as a fallback.
            return PKInkingTool(.marker, color: c.withAlphaComponent(0.4), width: w)
        case .eraser(.pixel):
            let session = UserDefaults.standard.double(forKey: "ink.eraser.pixelSize.session")
            let stored  = UserDefaults.standard.double(forKey: "ink.eraser.pixelSize")
            let width: CGFloat = session > 0 ? CGFloat(session)
                              : (stored > 0 ? CGFloat(stored) : 24)
            return PKEraserTool(.bitmap, width: width)
        case .eraser(.wholeStroke):
            return PKEraserTool(.vector)
        case .eraser(.page):
            return PKInkingTool(.pen, color: .clear, width: 1)
        case .lasso:
            return PKLassoTool()
        case .ruler, .text, .stickyNote, .image:
            // `.image` produces no strokes — same dummy PKTool as
            // the other finger-driven modes. The canvas-overlay
            // layer handles tap-to-place + selection above the
            // PKCanvasView.
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
