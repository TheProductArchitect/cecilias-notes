import Combine
import SwiftUI
import UIKit

/// Bridge between the SwiftUI formatting toolbar and a UITextView.
///
/// Owned by `TextElementView`; the representable installs a weak
/// reference to its UITextView on `attach(_:)`. The toolbar reads
/// `currentAttributes` to highlight the right buttons and calls the
/// command methods to mutate the text view's selection (or typing
/// attributes when the selection is collapsed).
///
/// All commands are non-destructive on empty selections: they
/// update `typingAttributes` so the next-typed character carries
/// the formatting, without mutating any existing glyphs.
final class RichTextController: ObservableObject {

    @Published var currentAttributes = RichTextAttributeSnapshot()

    private weak var textView: UITextView?
    /// Page ink color — used when a paragraph has no explicit
    /// foreground color attribute. Set by the parent view on attach
    /// (and updated when the trait changes) so `currentAttributes`
    /// reflects the *visible* color, not "no attribute set."
    private var defaultInkColor: UIColor = .label

    func attach(_ textView: UITextView, defaultInk: UIColor) {
        self.textView = textView
        self.defaultInkColor = defaultInk
        refresh()
    }

    func updateDefaultInk(_ color: UIColor) {
        self.defaultInkColor = color
        refresh()
    }

    // MARK: - Toolbar reads

    /// Re-derive `currentAttributes` from the text view's selection.
    /// Called by the coordinator on `textViewDidChangeSelection` and
    /// after each command apply.
    func refresh() {
        guard let tv = textView else { return }
        let snap = snapshot(for: tv)
        if snap != currentAttributes {
            currentAttributes = snap
        }
    }

    private func snapshot(for tv: UITextView) -> RichTextAttributeSnapshot {
        var snap = RichTextAttributeSnapshot()
        let range = tv.selectedRange
        let attrs: [NSAttributedString.Key: Any] = {
            if range.length == 0 {
                // Collapsed selection — use typingAttributes if
                // present, else the attributes immediately before the
                // caret, else the empty defaults.
                if !tv.typingAttributes.isEmpty {
                    return tv.typingAttributes
                }
                let loc = max(0, range.location - 1)
                if tv.attributedText.length > 0, loc < tv.attributedText.length {
                    return tv.attributedText.attributes(at: loc, effectiveRange: nil)
                }
                return [:]
            }
            // Use attributes at the start of the selection. A mixed
            // run would be ambiguous; the toolbar reflects the leading
            // edge which is the conventional behaviour.
            let safeLoc = max(0, min(range.location, tv.attributedText.length - 1))
            if tv.attributedText.length > 0 {
                return tv.attributedText.attributes(at: safeLoc, effectiveRange: nil)
            }
            return [:]
        }()

        if let font = attrs[.font] as? UIFont {
            let traits = font.fontDescriptor.symbolicTraits
            snap.isBold   = traits.contains(.traitBold)
            snap.isItalic = traits.contains(.traitItalic)
            snap.family   = familyForFont(font)
            // Heading + size from the descriptor's stored axes
            // (we round-trip these via UserInfo on the descriptor).
            if let h = attrs[Self.headingKey] as? String,
               let parsed = RichTextHeading(rawValue: h) {
                snap.heading = parsed
            }
            if let s = attrs[Self.sizeKey] as? String,
               let parsed = RichTextSize(rawValue: s) {
                snap.size = parsed
            }
        }
        if let style = attrs[.underlineStyle] as? Int {
            snap.isUnderline = style != 0
        }
        if let style = attrs[.strikethroughStyle] as? Int {
            snap.isStrikethrough = style != 0
        }
        if let para = attrs[.paragraphStyle] as? NSParagraphStyle {
            snap.alignment = RichTextAlignment.from(para.alignment)
        }
        if let list = attrs[Self.listKey] as? String,
           let mode = RichTextListMode(rawValue: list) {
            snap.listMode = mode
        }
        if let fg = attrs[.foregroundColor] as? UIColor {
            // Treat "matches default ink" as nil so the swatch
            // shows the inherited state.
            snap.foreground = fg.isApproximately(defaultInkColor) ? nil : fg
        }
        return snap
    }

    private func familyForFont(_ font: UIFont) -> RichTextFontFamily {
        let name = font.fontName.lowercased()
        if name.contains("mono") { return .mono }
        if name.contains("newyork") || name.contains("times") || name.contains("serif") {
            return .serif
        }
        return .sans
    }

    // MARK: - Custom attribute keys
    //
    // The heading/size/list axes don't have first-class
    // NSAttributedString.Key counterparts. Stash them on the
    // attribute dict so the snapshot can round-trip them and so the
    // encoded `Data` payload preserves them across launches.

    static let headingKey  = NSAttributedString.Key("ceciliasnotes.heading")
    static let sizeKey     = NSAttributedString.Key("ceciliasnotes.size")
    static let listKey     = NSAttributedString.Key("ceciliasnotes.list")

    // MARK: - Character-level commands

    func toggleBold()          { toggleTrait(.traitBold) }
    func toggleItalic()        { toggleTrait(.traitItalic) }

    func toggleUnderline() {
        let on = !currentAttributes.isUnderline
        applyToSelection { attrs in
            attrs[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : 0
            return attrs
        }
    }

    func toggleStrikethrough() {
        let on = !currentAttributes.isStrikethrough
        applyToSelection { attrs in
            attrs[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : 0
            return attrs
        }
    }

    private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard let tv = textView else { return }
        // Read the current trait state from the snapshot so the
        // toggle's "on" target is unambiguous across mixed runs.
        let isOn: Bool = {
            switch trait {
            case .traitBold:   return currentAttributes.isBold
            case .traitItalic: return currentAttributes.isItalic
            default: return false
            }
        }()
        applyToSelection { attrs in
            let base = (attrs[.font] as? UIFont) ?? Self.defaultFont(
                heading: currentAttributes.heading,
                size: currentAttributes.size,
                family: currentAttributes.family
            )
            let next = isOn ? base.without(traits: trait) : base.with(traits: trait)
            attrs[.font] = next
            return attrs
        }
        // Re-derive after; SwiftUI buttons depend on this.
        _ = tv
    }

    func setHeading(_ heading: RichTextHeading) {
        applyToParagraph { attrs, _ in
            var next = attrs
            next[Self.headingKey] = heading.rawValue
            next[.font] = Self.buildFont(
                heading: heading,
                size: currentAttributes.size,
                family: currentAttributes.family,
                bold: currentAttributes.isBold,
                italic: currentAttributes.isItalic
            )
            return next
        }
    }

    func setSize(_ size: RichTextSize) {
        applyToParagraph { attrs, _ in
            var next = attrs
            next[Self.sizeKey] = size.rawValue
            next[.font] = Self.buildFont(
                heading: currentAttributes.heading,
                size: size,
                family: currentAttributes.family,
                bold: currentAttributes.isBold,
                italic: currentAttributes.isItalic
            )
            return next
        }
    }

    func setFamily(_ family: RichTextFontFamily) {
        applyToParagraph { attrs, _ in
            var next = attrs
            next[.font] = Self.buildFont(
                heading: currentAttributes.heading,
                size: currentAttributes.size,
                family: family,
                bold: currentAttributes.isBold,
                italic: currentAttributes.isItalic
            )
            return next
        }
    }

    func setAlignment(_ alignment: RichTextAlignment) {
        applyToParagraph { attrs, _ in
            var next = attrs
            let para = (next[.paragraphStyle] as? NSParagraphStyle).map {
                ($0.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            } ?? NSMutableParagraphStyle()
            para.alignment = alignment.ns
            next[.paragraphStyle] = para
            return next
        }
    }

    func setForeground(_ color: UIColor?) {
        applyToSelection { attrs in
            var next = attrs
            if let color {
                next[.foregroundColor] = color
            } else {
                next.removeValue(forKey: .foregroundColor)
            }
            return next
        }
    }

    func toggleBullet() {
        let target: RichTextListMode = currentAttributes.listMode == .bullet ? .none : .bullet
        setListMode(target)
    }

    func toggleNumbered() {
        let target: RichTextListMode = currentAttributes.listMode == .numbered ? .none : .numbered
        setListMode(target)
    }

    private func setListMode(_ mode: RichTextListMode) {
        guard let tv = textView else { return }
        let storage = tv.textStorage
        let selection = tv.selectedRange
        let nsText = storage.string as NSString
        let lineRange = nsText.lineRange(for: selection)

        storage.beginEditing()
        // Strip any existing list prefix on each line in range, then
        // re-apply the new mode's prefix.
        let plain = (storage.attributedSubstring(from: lineRange).string)
        let lines = plain.components(separatedBy: "\n")
        var rebuilt: [String] = []
        var counter = 1
        for line in lines {
            let stripped = Self.stripListPrefix(line)
            switch mode {
            case .none:
                rebuilt.append(stripped)
            case .bullet:
                rebuilt.append(stripped.isEmpty ? stripped : "• \(stripped)")
            case .numbered:
                rebuilt.append(stripped.isEmpty ? stripped : "\(counter). \(stripped)")
                if !stripped.isEmpty { counter += 1 }
            }
        }
        let joined = rebuilt.joined(separator: "\n")
        // Preserve attributes from the first character in the line
        // range so the rebuilt run inherits font/color.
        var seedAttrs: [NSAttributedString.Key: Any] = [:]
        if storage.length > 0, lineRange.location < storage.length {
            seedAttrs = storage.attributes(at: lineRange.location, effectiveRange: nil)
        }
        seedAttrs[Self.listKey] = (mode == .none) ? nil : mode.rawValue
        storage.replaceCharacters(
            in: lineRange,
            with: NSAttributedString(string: joined, attributes: seedAttrs)
        )
        storage.endEditing()
        tv.selectedRange = NSRange(location: lineRange.location + joined.utf16.count, length: 0)
        notifyDidChange(tv)
        refresh()
    }

    /// UITextView's `textViewDidChange` does **not** fire for
    /// programmatic mutations of `textStorage`, `attributedText`,
    /// `typingAttributes`, etc. Call this after each toolbar action
    /// so the representable's coordinator pushes the new attributed
    /// string out through its binding — without this, formatting
    /// changes never reach `attributedTextData` on persist.
    private func notifyDidChange(_ tv: UITextView) {
        tv.delegate?.textViewDidChange?(tv)
    }

    private static func stripListPrefix(_ line: String) -> String {
        // Strip "• " or "N. " from the start.
        if line.hasPrefix("• ") {
            return String(line.dropFirst(2))
        }
        // Numbered "12. " — up to 3 digits.
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i].isNumber, i < 3 { i += 1 }
        if i > 0, i + 1 < chars.count, chars[i] == ".", chars[i + 1] == " " {
            return String(chars[(i + 2)...])
        }
        return line
    }

    // MARK: - Apply helpers

    /// Apply a transform to the attributes covering the current
    /// selection. For a collapsed selection, update
    /// `typingAttributes` so the next-typed character carries the
    /// change without mutating any existing run.
    private func applyToSelection(_ transform: (inout [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        if range.length == 0 {
            var current = tv.typingAttributes
            tv.typingAttributes = transform(&current)
        } else {
            let storage = tv.textStorage
            storage.beginEditing()
            storage.enumerateAttributes(in: range, options: []) { existing, subrange, _ in
                var mutable = existing
                let next = transform(&mutable)
                storage.setAttributes(next, range: subrange)
            }
            storage.endEditing()
            notifyDidChange(tv)
        }
        refresh()
    }

    /// Apply a transform to the attributes covering the paragraph(s)
    /// the current selection touches. Used by heading / size / family
    /// / alignment which are paragraph-level controls.
    private func applyToParagraph(_ transform: (_ attrs: [NSAttributedString.Key: Any], _ range: NSRange) -> [NSAttributedString.Key: Any]) {
        guard let tv = textView else { return }
        let nsText = tv.text as NSString
        let paragraphRange: NSRange
        if tv.selectedRange.length == 0, tv.text.isEmpty {
            // Empty document — fold into typingAttributes only.
            var current = tv.typingAttributes
            current = transform(current, NSRange(location: 0, length: 0))
            tv.typingAttributes = current
            refresh()
            return
        }
        paragraphRange = nsText.paragraphRange(for: tv.selectedRange)
        let storage = tv.textStorage
        storage.beginEditing()
        storage.enumerateAttributes(in: paragraphRange, options: []) { existing, subrange, _ in
            let next = transform(existing, subrange)
            storage.setAttributes(next, range: subrange)
        }
        storage.endEditing()
        // Also push into typingAttributes so the next character
        // typed at the caret carries the paragraph-level change.
        var typing = tv.typingAttributes
        typing = transform(typing, tv.selectedRange)
        tv.typingAttributes = typing
        notifyDidChange(tv)
        refresh()
    }

    // MARK: - Default attribute builder

    /// Build the canonical "starting state" attribute dict — used
    /// when seeding new content or backfilling missing attributes.
    static func defaultAttributes(
        ink: UIColor,
        heading: RichTextHeading = .body,
        size: RichTextSize = .regular,
        family: RichTextFontFamily = .sans
    ) -> [NSAttributedString.Key: Any] {
        // Shared editorial voice (`NoteTypography`): airy leading,
        // real paragraph space after a hard return (soft-wrap inside
        // a paragraph stays tight), and role-matched tracking. The
        // Mac editor consumes the same tokens, so a note reads
        // identically on every device that wrote it.
        let font = buildFont(
            heading: heading,
            size: size,
            family: family,
            bold: heading != .body,
            italic: false
        )
        return [
            .font: font,
            .foregroundColor: ink,
            .paragraphStyle: NoteTypography.paragraphStyle(
                isHeading: heading != .body,
                pointSize: font.pointSize
            ),
            .kern: NoteTypography.kern(forPointSize: font.pointSize),
            headingKey: heading.rawValue,
            sizeKey: size.rawValue,
        ]
    }

    static func defaultFont(
        heading: RichTextHeading,
        size: RichTextSize,
        family: RichTextFontFamily
    ) -> UIFont {
        buildFont(heading: heading, size: size, family: family, bold: heading != .body, italic: false)
    }

    static func buildFont(
        heading: RichTextHeading,
        size: RichTextSize,
        family: RichTextFontFamily,
        bold: Bool,
        italic: Bool
    ) -> UIFont {
        let pt = heading.basePointSize * size.multiplier
        let weight: UIFont.Weight = (bold || heading != .body) ? .semibold : .regular
        return family.uiFont(size: pt, weight: weight, italic: italic)
    }
}

// MARK: - UIColor approximate-equality

extension UIColor {
    /// True when two colors look the same to the eye (per-component
    /// within 1/255). Used to treat "explicit foreground that
    /// happens to match the page ink" as "no foreground attribute"
    /// for the toolbar's swatch state.
    func isApproximately(_ other: UIColor) -> Bool {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard
            self.getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
            other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        else { return false }
        return abs(r1 - r2) < 0.01 && abs(g1 - g2) < 0.01 && abs(b1 - b2) < 0.01 && abs(a1 - a2) < 0.05
    }
}
