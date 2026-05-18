import SwiftUI
import UIKit

// MARK: - MarkdownShortcutHandler

/// Intercepts UITextView input and converts leading markdown syntax to rich text formatting.
/// Called from textView(_:shouldChangeTextIn:replacementText:) — returns false when it
/// consumed the event, true to let UIKit process it normally.
///
/// Patterns (typed at start of line, replaced on Space or Enter):
///   **  → bold
///   *   → italic (single asterisk at line start)
///   # , ## , ### → H1, H2, H3
///   - or * (+ space) → bullet list
///   ` → inline code (pair: `text` closed on second backtick)
///   > → blockquote
final class MarkdownShortcutHandler {

    weak var textView: UITextView?

    init(textView: UITextView) {
        self.textView = textView
    }

    /// Returns `true` if UIKit should process the keystroke normally;
    /// `false` if the handler consumed it.
    func handle(range: NSRange, text: String) -> Bool {
        guard let textView,
              text == " " || text == "\n" else { return true }

        let fullString = textView.text as NSString
        let lineRange  = fullString.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText   = fullString.substring(with: lineRange) as NSString

        // Find the text before the cursor on the current line (excluding trailing newline)
        let cursorInLine = range.location - lineRange.location
        guard cursorInLine >= 0 else { return true }
        let prefix = (lineText.substring(to: min(cursorInLine, lineText.length)))
            .trimmingCharacters(in: .newlines)

        // Headings
        if text == " " {
            if prefix == "###" { return applyHeading(.h3, lineRange: lineRange, prefixLen: 3) }
            if prefix == "##"  { return applyHeading(.h2, lineRange: lineRange, prefixLen: 2) }
            if prefix == "#"   { return applyHeading(.h1, lineRange: lineRange, prefixLen: 1) }
        }

        // Bold/italic markers — only on Space trigger
        if text == " " {
            if prefix == "**" { return applyInlineToggle(.traitBold, lineRange: lineRange, prefixLen: 2) }
            if prefix == "_"  { return applyInlineToggle(.traitItalic, lineRange: lineRange, prefixLen: 1) }
        }

        // Bullet list
        if text == " " && (prefix == "-" || prefix == "*") {
            return applyBullet(lineRange: lineRange, prefixLen: prefix.count)
        }

        // Blockquote
        if text == " " && prefix == ">" {
            return applyBlockquote(lineRange: lineRange, prefixLen: 1)
        }

        return true
    }

    // MARK: - Applicators

    private func applyHeading(_ level: RichTextAttributes.HeadingLevel,
                               lineRange: NSRange, prefixLen: Int) -> Bool {
        guard let textView else { return true }
        let attrString = NSMutableAttributedString(attributedString: textView.attributedText)
        // Remove the markdown prefix + the triggering space from the line
        let removeRange = NSRange(location: lineRange.location, length: prefixLen + 1)
        guard removeRange.location + removeRange.length <= attrString.length else { return true }
        attrString.deleteCharacters(in: removeRange)
        // Apply heading to the remainder of the line
        let newLineRange = (attrString.string as NSString).lineRange(
            for: NSRange(location: lineRange.location, length: 0)
        )
        RichTextAttributes.applyHeading(level, to: attrString, range: newLineRange)
        commit(attrString, cursorAt: lineRange.location)
        return false
    }

    private func applyInlineToggle(_ trait: UIFontDescriptor.SymbolicTraits,
                                    lineRange: NSRange, prefixLen: Int) -> Bool {
        guard let textView else { return true }
        let attrString = NSMutableAttributedString(attributedString: textView.attributedText)
        let removeRange = NSRange(location: lineRange.location, length: prefixLen + 1)
        guard removeRange.location + removeRange.length <= attrString.length else { return true }
        attrString.deleteCharacters(in: removeRange)
        let newLineRange = (attrString.string as NSString).lineRange(
            for: NSRange(location: lineRange.location, length: 0)
        )
        let current = attrString.attribute(.font, at: max(0, newLineRange.location), effectiveRange: nil) as? UIFont
            ?? UIFont.preferredFont(forTextStyle: .body)
        let newTraits = current.fontDescriptor.symbolicTraits.union(trait)
        if let desc = current.fontDescriptor.withSymbolicTraits(newTraits) {
            attrString.addAttribute(.font, value: UIFont(descriptor: desc, size: current.pointSize), range: newLineRange)
        }
        commit(attrString, cursorAt: lineRange.location)
        return false
    }

    private func applyBullet(lineRange: NSRange, prefixLen: Int) -> Bool {
        guard let textView else { return true }
        let attrString = NSMutableAttributedString(attributedString: textView.attributedText)
        let removeRange = NSRange(location: lineRange.location, length: prefixLen + 1)
        guard removeRange.location + removeRange.length <= attrString.length else { return true }
        attrString.deleteCharacters(in: removeRange)
        attrString.insert(NSAttributedString(string: "• "), at: lineRange.location)
        commit(attrString, cursorAt: lineRange.location + 2)
        return false
    }

    private func applyBlockquote(lineRange: NSRange, prefixLen: Int) -> Bool {
        guard let textView else { return true }
        let attrString = NSMutableAttributedString(attributedString: textView.attributedText)
        let removeRange = NSRange(location: lineRange.location, length: prefixLen + 1)
        guard removeRange.location + removeRange.length <= attrString.length else { return true }
        attrString.deleteCharacters(in: removeRange)
        let insertion = NSAttributedString(
            string: "❝ ",
            attributes: [.foregroundColor: UIColor(ThemeManager.shared.current.foregroundMuted),
                         .font: UIFont.preferredFont(forTextStyle: .body)]
        )
        attrString.insert(insertion, at: lineRange.location)
        commit(attrString, cursorAt: lineRange.location + 2)
        return false
    }

    // MARK: - Commit

    private func commit(_ attrString: NSMutableAttributedString, cursorAt location: Int) {
        guard let textView else { return }
        textView.attributedText = attrString
        let clamped = max(0, min(location, attrString.length))
        textView.selectedRange = NSRange(location: clamped, length: 0)
    }
}
