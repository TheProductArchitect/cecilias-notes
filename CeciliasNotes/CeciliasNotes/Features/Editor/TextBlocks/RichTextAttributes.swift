import SwiftUI
import UIKit

// MARK: - RichTextAttributes

/// Helpers for toggling and reading NSAttributedString formatting attributes.
/// All mutations are made on the full attributed string with a given range.
enum RichTextAttributes {

    // MARK: - Font traits

    static func toggleBold(_ attrString: NSMutableAttributedString, range: NSRange) {
        toggleTrait(.traitBold, in: attrString, range: range)
    }

    static func toggleItalic(_ attrString: NSMutableAttributedString, range: NSRange) {
        toggleTrait(.traitItalic, in: attrString, range: range)
    }

    static func toggleUnderline(_ attrString: NSMutableAttributedString, range: NSRange) {
        let current = attrString.attribute(.underlineStyle, at: max(0, range.location), effectiveRange: nil) as? Int ?? 0
        let style: NSUnderlineStyle.RawValue = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        attrString.addAttribute(.underlineStyle, value: style, range: range)
    }

    // MARK: - Heading

    enum HeadingLevel: Int, CaseIterable {
        case h1 = 1, h2 = 2, h3 = 3
        var fontSize: CGFloat { [28, 22, 18][rawValue - 1] }
    }

    static func applyHeading(_ level: HeadingLevel, to attrString: NSMutableAttributedString, range: NSRange) {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
            .withSymbolicTraits(.traitBold) ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        let font = UIFont(descriptor: descriptor, size: level.fontSize)
        attrString.addAttribute(.font, value: font, range: range)
    }

    static func removeHeading(from attrString: NSMutableAttributedString, range: NSRange) {
        let font = UIFont.preferredFont(forTextStyle: .body)
        attrString.addAttribute(.font, value: font, range: range)
    }

    // MARK: - Lists

    /// Prefixes selected lines with a bullet "• " if not already bulleted, or removes the prefix.
    static func toggleBulletList(_ attrString: NSMutableAttributedString, range: NSRange) {
        let string = attrString.string as NSString
        let lineRange = string.lineRange(for: range)
        let lineString = string.substring(with: lineRange)
        let hasBullet = lineString.hasPrefix("• ")
        if hasBullet {
            let stripped = NSMutableAttributedString(attributedString: attrString.attributedSubstring(from: lineRange))
            let strippedString = stripped.string.replacingOccurrences(of: "^• ", with: "", options: .regularExpression)
            let result = NSMutableAttributedString(string: strippedString)
            attrString.replaceCharacters(in: lineRange, with: result)
        } else {
            let result = NSMutableAttributedString(string: "• " + lineString)
            attrString.replaceCharacters(in: lineRange, with: result)
        }
    }

    // MARK: - Code

    static func toggleCode(_ attrString: NSMutableAttributedString, range: NSRange) {
        let current = attrString.attribute(.font, at: max(0, range.location), effectiveRange: nil) as? UIFont
        let isCode = current?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ?? false
        let font: UIFont = isCode
            ? UIFont.preferredFont(forTextStyle: .body)
            : UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        attrString.addAttribute(.font, value: font, range: range)
        let bg: UIColor = isCode ? .clear : UIColor(ThemeManager.shared.current.surface)
        attrString.addAttribute(.backgroundColor, value: bg, range: range)
    }

    // MARK: - Link

    static func applyLink(_ url: URL, to attrString: NSMutableAttributedString, range: NSRange) {
        attrString.addAttribute(.link, value: url, range: range)
        attrString.addAttribute(.foregroundColor, value: UIColor(ThemeManager.shared.current.accent), range: range)
        attrString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    }

    static func removeLink(from attrString: NSMutableAttributedString, range: NSRange) {
        attrString.removeAttribute(.link, range: range)
        attrString.removeAttribute(.foregroundColor, range: range)
        attrString.addAttribute(.underlineStyle, value: 0, range: range)
    }

    // MARK: - Blockquote

    static func toggleBlockquote(_ attrString: NSMutableAttributedString, range: NSRange) {
        let string = attrString.string as NSString
        let lineRange = string.lineRange(for: range)
        let lineString = string.substring(with: lineRange)
        let hasQuote = lineString.hasPrefix("❝ ")
        if hasQuote {
            let stripped = lineString.replacingOccurrences(of: "^❝ ", with: "", options: .regularExpression)
            attrString.replaceCharacters(in: lineRange, with: NSAttributedString(string: stripped))
        } else {
            let result = NSMutableAttributedString(string: "❝ " + lineString)
            result.addAttribute(.foregroundColor, value: UIColor(ThemeManager.shared.current.foregroundMuted),
                                range: NSRange(location: 0, length: result.length))
            attrString.replaceCharacters(in: lineRange, with: result)
        }
    }

    // MARK: - State queries

    static func isBold(in attrString: NSAttributedString, at location: Int) -> Bool {
        guard let font = attrString.attribute(.font, at: max(0, location), effectiveRange: nil) as? UIFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.traitBold)
    }

    static func isItalic(in attrString: NSAttributedString, at location: Int) -> Bool {
        guard let font = attrString.attribute(.font, at: max(0, location), effectiveRange: nil) as? UIFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.traitItalic)
    }

    static func isUnderline(in attrString: NSAttributedString, at location: Int) -> Bool {
        let val = attrString.attribute(.underlineStyle, at: max(0, location), effectiveRange: nil) as? Int ?? 0
        return val != 0
    }

    static func isCode(in attrString: NSAttributedString, at location: Int) -> Bool {
        guard let font = attrString.attribute(.font, at: max(0, location), effectiveRange: nil) as? UIFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
    }

    static func linkURL(in attrString: NSAttributedString, at location: Int) -> URL? {
        attrString.attribute(.link, at: max(0, location), effectiveRange: nil) as? URL
    }

    // MARK: - Default attributes

    static var defaultAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor(ThemeManager.shared.current.foreground),
        ]
    }

    static func makeDefault(_ string: String = "") -> NSAttributedString {
        NSAttributedString(string: string, attributes: defaultAttributes)
    }

    // MARK: - Private helpers

    private static func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits,
                                    in attrString: NSMutableAttributedString,
                                    range: NSRange) {
        let loc = max(0, range.location)
        guard loc < attrString.length else { return }
        let currentFont = attrString.attribute(.font, at: loc, effectiveRange: nil) as? UIFont
            ?? UIFont.preferredFont(forTextStyle: .body)
        let currentTraits = currentFont.fontDescriptor.symbolicTraits
        let newTraits = currentTraits.contains(trait)
            ? currentTraits.subtracting(trait)
            : currentTraits.union(trait)
        let newDescriptor = currentFont.fontDescriptor.withSymbolicTraits(newTraits)
            ?? currentFont.fontDescriptor
        let newFont = UIFont(descriptor: newDescriptor, size: currentFont.pointSize)
        attrString.addAttribute(.font, value: newFont, range: range)
    }
}
