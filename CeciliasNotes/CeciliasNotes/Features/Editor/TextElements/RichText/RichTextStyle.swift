import SwiftUI
import UIKit

/// Curated rich-text axes for text blocks. Each axis is a small
/// enum rather than a free value so the editor stays consistent
/// with the app's editorial tone — no arbitrary point sizes, no
/// open font picker, no exotic alignments. The toolbar exposes one
/// control per axis; the representable applies them through
/// `RichTextController`.

/// Heading level — applies to the whole paragraph at the caret.
enum RichTextHeading: String, Codable, CaseIterable {
    case body
    case h3
    case h2
    case h1

    /// Base point size before the per-paragraph `RichTextSize`
    /// multiplier kicks in.
    var basePointSize: CGFloat {
        switch self {
        // Body matches `NoteTypography.bodyPointSize` — a page is a
        // fixed point space shared with the Mac editor, so the same
        // note must not render at different physical sizes per
        // device.
        case .body: return NoteTypography.bodyPointSize
        case .h3:   return 20
        case .h2:   return 24
        case .h1:   return 30
        }
    }

    var weight: UIFont.Weight {
        switch self {
        case .body: return .regular
        default:    return .semibold
        }
    }

    var label: String {
        switch self {
        case .body: return "Body"
        case .h3:   return "H3"
        case .h2:   return "H2"
        case .h1:   return "H1"
        }
    }
}

/// Coarse size variant on top of the heading's base size. The three
/// named tiers keep the editor consistent — there is no arbitrary
/// point-size picker by design.
enum RichTextSize: String, Codable, CaseIterable {
    case small
    case regular
    case large

    var multiplier: CGFloat {
        switch self {
        case .small:   return 0.85
        case .regular: return 1.0
        case .large:   return 1.25
        }
    }

    var label: String {
        switch self {
        case .small:   return "S"
        case .regular: return "M"
        case .large:   return "L"
        }
    }
}

/// Curated font families — paragraph-level only (no per-character
/// family changes) to keep the toolbar simple and the renderer fast.
enum RichTextFontFamily: String, Codable, CaseIterable {
    case sans
    case serif
    case mono

    func uiFont(size: CGFloat, weight: UIFont.Weight, italic: Bool) -> UIFont {
        switch self {
        case .sans:
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            return italic ? base.with(traits: .traitItalic) : base
        case .serif:
            // SF Serif (New York)
            let desc = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
                .withDesign(.serif) ?? UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            var resolved = desc.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: weight]
            ])
            if italic, let it = resolved.withSymbolicTraits(resolved.symbolicTraits.union(.traitItalic)) {
                resolved = it
            }
            return UIFont(descriptor: resolved, size: size)
        case .mono:
            let base = UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            return italic ? base.with(traits: .traitItalic) : base
        }
    }

    var label: String {
        switch self {
        case .sans:  return "Sans"
        case .serif: return "Serif"
        case .mono:  return "Mono"
        }
    }
}

/// Paragraph alignment — left/center/right. Justify is deliberately
/// off; it reads poorly in handwritten-style notes.
enum RichTextAlignment: String, Codable, CaseIterable {
    case left
    case center
    case right

    var ns: NSTextAlignment {
        switch self {
        case .left:   return .left
        case .center: return .center
        case .right:  return .right
        }
    }

    static func from(_ ns: NSTextAlignment) -> RichTextAlignment {
        switch ns {
        case .center: return .center
        case .right:  return .right
        default:      return .left
        }
    }

    var systemImage: String {
        switch self {
        case .left:   return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right:  return "text.alignright"
        }
    }
}

/// Paragraph list mode — flat (none), bulleted, or numbered.
/// Implemented as paragraph prefixes plus a `headIndent` so wrapped
/// lines align with the text after the bullet/number. A real
/// `NSTextList` would be more correct but the typing experience for
/// it on iOS is finicky; the prefix approach is robust and survives
/// round-trip through encoding cleanly.
enum RichTextListMode: String, Codable, CaseIterable {
    case none
    case bullet
    case numbered
}

/// Curated text-color swatches. Eight values chosen to read well on
/// both light (`#FAFAF8`) and dark (`#1C1C1A`) page backgrounds. The
/// first entry (`nil`) means "follow the page's ink color" — what
/// new text uses by default.
enum RichTextColorPalette {
    /// Eight curated swatches. The system color picker is the
    /// overflow path for anything outside this set.
    static let swatchesLight: [UIColor] = [
        UIColor(hex: "#1C1C1A"),  // ink
        UIColor(hex: "#C0392B"),  // red
        UIColor(hex: "#D68910"),  // amber
        UIColor(hex: "#1E8449"),  // green
        UIColor(hex: "#2471A3"),  // blue
        UIColor(hex: "#6C3483"),  // purple
        UIColor(hex: "#7B6F4F"),  // sand
        UIColor(hex: "#7F8C8D"),  // grey
    ]
    static let swatchesDark: [UIColor] = [
        UIColor(hex: "#EDEDEB"),  // ink (paper-dark)
        UIColor(hex: "#E57373"),
        UIColor(hex: "#F5B041"),
        UIColor(hex: "#58D68D"),
        UIColor(hex: "#5DADE2"),
        UIColor(hex: "#BB8FCE"),
        UIColor(hex: "#C7A877"),
        UIColor(hex: "#B0B0B0"),
    ]
}

/// Snapshot of all formatting attributes at the current caret /
/// selection. The toolbar subscribes to this via the
/// `RichTextController` so its buttons reflect what would happen if
/// the user typed at the current spot.
struct RichTextAttributeSnapshot: Equatable {
    var isBold: Bool          = false
    var isItalic: Bool        = false
    var isUnderline: Bool     = false
    var isStrikethrough: Bool = false
    var heading: RichTextHeading       = .body
    var size: RichTextSize             = .regular
    var family: RichTextFontFamily     = .sans
    var alignment: RichTextAlignment   = .left
    var listMode: RichTextListMode     = .none
    /// `nil` means "inherit page ink color".
    var foreground: UIColor?           = nil
}

// MARK: - UIFont italic helper

extension UIFont {
    /// Returns a copy of the font with the given symbolic traits
    /// merged in. Used for italic on system / mono fonts.
    func with(traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let desc = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(traits)
        ) else { return self }
        return UIFont(descriptor: desc, size: pointSize)
    }

    /// Returns a copy with the given trait removed.
    func without(traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let desc = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.subtracting(traits)
        ) else { return self }
        return UIFont(descriptor: desc, size: pointSize)
    }
}
