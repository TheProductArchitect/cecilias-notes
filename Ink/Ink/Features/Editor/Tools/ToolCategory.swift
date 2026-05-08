import Foundation

// MARK: - ToolCategory

/// Groups InkTool variants. The palette renders one category button per
/// case; the button shows the user's *last-used variant* for that category
/// (so when the user has just been using Fountain Pen, the Pen button
/// shows the fountain-pen glyph).
///
/// Eraser is also category-like but already has its own mode-picker UI
/// (see `EraserMode` + the eraser popover), so it's not modelled here.
/// Lasso / Ruler / Text are standalone — no variants — and stay as direct
/// buttons in the palette.
enum ToolCategory: String, CaseIterable, Codable {
    case pen
    case pencil
    case brush
    case highlighter

    /// Variants in display order. The first element is the category default
    /// (the variant a never-touched category falls back to).
    var variants: [InkTool.Identity] {
        switch self {
        case .pen:         return [.pen, .fountainPen, .monoline]
        case .pencil:      return [.pencil, .crayon]
        case .brush:       return [.brush, .marker]
        case .highlighter: return [.highlighter]
        }
    }

    var defaultVariant: InkTool.Identity {
        variants.first ?? .pen
    }

    var displayName: String {
        switch self {
        case .pen:         return "Pen"
        case .pencil:      return "Pencil"
        case .brush:       return "Brush"
        case .highlighter: return "Highlighter"
        }
    }
}

// MARK: - InkTool.Identity → ToolCategory

extension InkTool.Identity {
    /// Reverse lookup. Nil for utility tools (eraser, lasso, ruler, text)
    /// that aren't part of the category system.
    var category: ToolCategory? {
        for c in ToolCategory.allCases where c.variants.contains(self) {
            return c
        }
        return nil
    }
}
