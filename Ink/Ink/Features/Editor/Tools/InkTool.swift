import Foundation
import PencilKit
import UIKit

// MARK: - InkTool

/// User-facing tool model. Maps to a `PKTool` in `CanvasContainerView`.
/// Associated values are the *current* settings; defaults live in `InkTool.defaults`.
enum InkTool: Equatable {
    case pen(colour: UIColor, width: CGFloat, opacity: CGFloat)
    case highlighter(colour: UIColor, width: CGFloat)
    case pencil(colour: UIColor, width: CGFloat, opacity: CGFloat)
    case eraser(mode: EraserMode)
    case lasso
    case ruler
    case text                   // finger-driven text block mode

    enum Identity: String, CaseIterable {
        case pen, highlighter, pencil, eraser, lasso, ruler, text
    }

    var identity: Identity {
        switch self {
        case .pen:          return .pen
        case .highlighter:  return .highlighter
        case .pencil:       return .pencil
        case .eraser:       return .eraser
        case .lasso:        return .lasso
        case .ruler:        return .ruler
        case .text:         return .text
        }
    }

    var systemImage: String {
        switch self {
        case .pen:          return "pencil.tip"
        case .highlighter:  return "highlighter"
        case .pencil:       return "pencil"
        case .eraser:       return "eraser"
        case .lasso:        return "lasso"
        case .ruler:        return "ruler"
        case .text:         return "text.cursor"
        }
    }

    /// Tools that have an editable colour swatch.
    var hasColour: Bool {
        switch self {
        case .pen, .highlighter, .pencil: return true
        case .eraser, .lasso, .ruler, .text: return false
        }
    }

    /// Tools that have an editable width.
    var hasWidth: Bool {
        switch self {
        case .pen, .highlighter, .pencil: return true
        case .eraser(.pixel):             return true
        case .eraser:                     return false
        case .lasso, .ruler, .text:       return false
        }
    }

    /// Tools that support an editable opacity slider (highlighter is fixed at 40%).
    var hasOpacity: Bool {
        switch self {
        case .pen, .pencil:    return true
        default:               return false
        }
    }

    var currentColour: UIColor {
        switch self {
        case .pen(let c, _, _):       return c
        case .highlighter(let c, _):  return c
        case .pencil(let c, _, _):    return c
        default:                      return .inkTextPrimary
        }
    }

    var currentWidth: CGFloat {
        switch self {
        case .pen(_, let w, _):       return w
        case .highlighter(_, let w):  return w
        case .pencil(_, let w, _):    return w
        case .eraser(.pixel):
            // Reads the user's saved Pixel Eraser default. Falls back to 24 pt.
            let stored = UserDefaults.standard.double(forKey: "ink.eraser.pixelSize")
            return stored > 0 ? CGFloat(stored) : 24
        default:                      return 0
        }
    }

    var currentOpacity: CGFloat {
        switch self {
        case .pen(_, _, let o):           return o
        case .pencil(_, _, let o):        return o
        case .highlighter:                return 0.4
        default:                          return 1.0
        }
    }

    var isTextMode: Bool {
        if case .text = self { return true }
        return false
    }

    /// Tools that act on the PKCanvasView (strokes, erasing, selection, guides).
    /// Finger touches for these tools must reach the canvas, not the media overlay,
    /// or the eraser/lasso/ruler stops working when used with a finger.
    /// Only `.text` is genuinely non-canvas.
    var isDrawingTool: Bool {
        switch self {
        case .pen, .highlighter, .pencil, .eraser, .lasso, .ruler: return true
        case .text: return false
        }
    }

    /// Images are interactive (selectable/moveable) only in non-canvas modes (text).
    var isMediaInteractive: Bool { !isDrawingTool }

    // MARK: Mutators

    func withColour(_ colour: UIColor) -> InkTool {
        switch self {
        case .pen(_, let w, let o):       return .pen(colour: colour, width: w, opacity: o)
        case .highlighter(_, let w):      return .highlighter(colour: colour, width: w)
        case .pencil(_, let w, let o):    return .pencil(colour: colour, width: w, opacity: o)
        default:                          return self
        }
    }

    func withWidth(_ width: CGFloat) -> InkTool {
        let clamped = max(0.5, min(20, width))
        switch self {
        case .pen(let c, _, let o):        return .pen(colour: c, width: clamped, opacity: o)
        case .highlighter(let c, _):       return .highlighter(colour: c, width: clamped)
        case .pencil(let c, _, let o):     return .pencil(colour: c, width: clamped, opacity: o)
        default:                           return self
        }
    }

    func withOpacity(_ opacity: CGFloat) -> InkTool {
        let clamped = max(0.1, min(1.0, opacity))
        switch self {
        case .pen(let c, let w, _):        return .pen(colour: c, width: w, opacity: clamped)
        case .pencil(let c, let w, _):     return .pencil(colour: c, width: w, opacity: clamped)
        default:                           return self
        }
    }

    // MARK: Defaults

    enum Defaults {
        static func pen(theme: InkTheme) -> InkTool {
            let c: UIColor = theme == .dark ? UIColor(hex: "#F5F5F2") : UIColor(hex: "#1D1D1B")
            return .pen(colour: c, width: 2, opacity: 1.0)
        }
        static let highlighter: InkTool = .highlighter(colour: UIColor(hex: "#FFD60A"), width: 12)
        static func pencil(theme: InkTheme) -> InkTool {
            let c: UIColor = theme == .dark ? UIColor(hex: "#F5F5F2") : UIColor(hex: "#1D1D1B")
            return .pencil(colour: c, width: 3, opacity: 1.0)
        }
        static let eraser: InkTool = .eraser(mode: .wholeStroke)
        static let lasso: InkTool = .lasso
        static let ruler: InkTool = .ruler
        static let text: InkTool  = .text
    }

    // MARK: PKTool mapping

    /// Builds the `PKTool` corresponding to this InkTool.
    /// Note: `.ruler` is not a PKTool — it toggles `canvasView.isRulerActive`.
    func makePKTool() -> PKTool {
        switch self {
        case .pen(let c, let w, let opacity):
            // Apply opacity as alpha — PKInkingTool .pen does not have a separate opacity setting.
            let resolved = c.withAlphaComponent(opacity)
            return PKInkingTool(.pen, color: resolved, width: w)
        case .highlighter(let c, let w):
            // Spec: highlighter is colour at 40% alpha (fixed).
            let resolved = c.withAlphaComponent(0.4)
            return PKInkingTool(.marker, color: resolved, width: w)
        case .pencil(let c, let w, let opacity):
            return PKInkingTool(.pencil, color: c.withAlphaComponent(opacity), width: w)
        case .eraser(.pixel):
            // PKEraserTool(.bitmap, width:) is iOS 16.4+; safe on this iOS 17+ app.
            let stored = UserDefaults.standard.double(forKey: "ink.eraser.pixelSize")
            let width: CGFloat = stored > 0 ? CGFloat(stored) : 24
            return PKEraserTool(.bitmap, width: width)
        case .eraser(.wholeStroke):
            return PKEraserTool(.vector)
        case .eraser(.page):
            // .page is a one-shot action handled by the toolbar (eraseCurrentPage),
            // not an active PKTool. Return a harmless no-op so the canvas doesn't
            // mis-handle it if this branch is ever hit.
            return PKInkingTool(.pen, color: .clear, width: 1)
        case .lasso:
            return PKLassoTool()
        case .ruler:
            // Caller toggles canvasView.isRulerActive instead. Returning a no-op pen
            // keeps PKCanvasView from crashing if this branch is reached unexpectedly.
            return PKInkingTool(.pen, color: .clear, width: 1)
        case .text:
            // Text tool does not interact with PKCanvasView; return a no-op pen.
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
