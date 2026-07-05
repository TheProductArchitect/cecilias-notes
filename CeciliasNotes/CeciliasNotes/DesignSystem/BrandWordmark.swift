import SwiftUI
#if canImport(UIKit)
import UIKit
typealias BrandUIFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias BrandUIFont = NSFont
#endif

/// The brand wordmark — the masthead identity element.
///
/// Inline composition: the user's possessive name (heavy, large) sits
/// next to a small lowercase "notes" with a brand-accent middle dot
/// (`·`, U+00B7), all baseline-aligned. The name dominates; "notes·"
/// is a recessive label that sits at the same baseline regardless of
/// how large the name renders.
///
/// Sizing is intrinsic — the caller passes the user's name and the
/// wordmark picks the right tier. Long names step down through fixed
/// tiers (72 → 68 → 60 → 52 → 44 → 38 pt); a `minimumScaleFactor`
/// floor keeps the name above 28 pt so the hierarchy with the 18 pt
/// "notes·" label never inverts.
///
/// Used by:
///   • Library home masthead (`BrandWordmark(userName:)`)
///   • App icons via `BrandIconRenderer` (single-letter preview)
///   • Onboarding live preview (`BrandWordmark(letter:size:)`)
///
/// The splash and Settings → About compose their own treatments
/// because their scale and stacking differ enough that bending the
/// inline composition to fit them would compromise the masthead.
struct BrandWordmark: View {

    private enum Mode {
        case inline(userName: String)
        case letter(Character, CGFloat)
    }

    private let mode: Mode
    private let compact: Bool

    /// Theme drives every colour the wordmark renders. Reads from
    /// `@Environment(\.theme)` so name/notes/accent flip automatically
    /// when the user switches Default ↔ Midnight. Pre-D1 there was an
    /// `onDarkBackground: Bool` parameter that gated hardcoded literals;
    /// it was structurally theme-blind and every caller relied on its
    /// `false` default.
    @Environment(\.theme) private var theme

    /// The masthead inline composition: `[name]'s notes·` with the name
    /// auto-sized by length and "notes·" pinned at 18 pt.
    /// `compact` (default false) ratchets every size tier down so the
    /// wordmark fits a 96pt iPhone masthead band — the iPad band
    /// (180pt) still uses the full 72pt-down-to-38pt sequence.
    init(userName: String, compact: Bool = false) {
        self.mode = .inline(userName: userName)
        self.compact = compact
    }

    /// Single-letter preview used by the onboarding live preview and
    /// the icon renderer. Renders the lowercase letter + brand-accent
    /// full stop at the requested size — no "notes" label, since this
    /// is a typographic sketch rather than the full wordmark.
    init(letter: Character, size: CGFloat) {
        self.mode = .letter(letter, size)
        self.compact = false
    }

    var body: some View {
        switch mode {
        case .inline(let name):
            inlineBody(userName: name)
        case .letter(let ch, let size):
            letterBody(letter: ch, size: size)
        }
    }

    // MARK: Inline composition

    @ViewBuilder
    private func inlineBody(userName: String) -> some View {
        let possessive = NameFormatter.mastheadPossessive(for: userName)
        let nameSize   = computedNameSize(for: userName)
        // Baseline alignment carries through across name-size tiers
        // automatically — `firstTextBaseline` aligns the bottoms of
        // the largest line of text in each child, so the 18 pt
        // "notes·" sits on the same baseline as a 72 pt "venu's" or a
        // 38 pt long-name.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(possessive)
                .font(.system(size: nameSize, weight: .heavy))
                .tracking(-0.05 * nameSize)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .minimumScaleFactor(scaleFloor(for: nameSize))

            HStack(spacing: 0) {
                Text("notes")
                    .foregroundStyle(notesColor)
                Text("·")  // U+00B7 MIDDLE DOT
                    .foregroundStyle(brandAccent)
            }
            .font(.system(size: compact ? 12 : 18, weight: .regular))
            .tracking(-0.2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wordmark \(possessive) notes")
    }

    // MARK: Letter preview

    @ViewBuilder
    private func letterBody(letter: Character, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(String(letter).lowercased())
                .font(BrandFont.wordmark(size: size))
                .tracking(-0.05 * size)
                .foregroundStyle(theme.foreground)
            Text(".")
                .font(BrandFont.wordmark(size: size))
                .foregroundStyle(theme.accent)
        }
        .accessibilityHidden(true)
    }

    // MARK: Sizing

    private func computedNameSize(for name: String) -> CGFloat {
        if compact {
            switch NameFormatter.normalised(name).count {
            case 0...4:   return 38
            case 5...6:   return 34
            case 7...8:   return 30
            case 9...10:  return 26
            case 11...12: return 22
            default:      return 20
            }
        }
        switch NameFormatter.normalised(name).count {
        case 0...4:   return 72
        case 5...6:   return 68
        case 7...8:   return 60
        case 9...10:  return 52
        case 11...12: return 44
        default:      return 38
        }
    }

    /// Hard floor at 28 pt — `minimumScaleFactor` is a fraction of the
    /// chosen size, so we derive the floor from the size to guarantee
    /// the name never shrinks into the 18 pt "notes·" label's range.
    private func scaleFloor(for size: CGFloat) -> CGFloat {
        max(28 / size, 0.5)
    }

    // MARK: Colours
    //
    // All three are theme-driven via `@Environment(\.theme)`. The wordmark
    // automatically flips when the user switches Default ↔ Midnight.

    private var nameColor: Color { theme.foreground }

    private var notesColor: Color { theme.foregroundMuted }

    private var brandAccent: Color { theme.accent }
}

// MARK: - Brand font (SF Pro system)

/// Single source of truth for the wordmark typeface. Resolves to SF Pro
/// Heavy so both the SwiftUI view and the CoreGraphics icon renderer
/// draw with identical metrics.
enum BrandFont {
    static func wordmark(size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .default)
    }

    static func wordmarkUIFont(size: CGFloat) -> BrandUIFont {
#if canImport(UIKit)
        .systemFont(ofSize: size, weight: .heavy)
#else
        .systemFont(ofSize: size, weight: .heavy)
#endif
    }
}

// MARK: - Notebook header sizing

/// Picks a wordmark size for the editor's notebook header — driven by
/// the notebook title's character count. The masthead's wordmark sizes
/// itself intrinsically (see `BrandWordmark`); only this title-driven
/// surface still needs an external picker.
enum WordmarkSizing {
    static func notebookHeaderSize(for title: String) -> CGFloat {
        switch title.count {
        case 0...8:   return 22
        case 9...14:  return 18
        case 15...20: return 15
        default:      return 13
        }
    }
}
