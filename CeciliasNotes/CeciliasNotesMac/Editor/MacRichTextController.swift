import AppKit
import Combine
import SwiftUI

// MARK: - Rich text axes (Mac mirror of iPad `RichTextStyle.swift`)

enum MacRichTextHeading: String, CaseIterable {
    case body, h3, h2, h1

    var basePointSize: CGFloat {
        switch self {
        case .body: return 17
        case .h3:   return 20
        case .h2:   return 24
        case .h1:   return 30
        }
    }

    var weight: NSFont.Weight {
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

enum MacRichTextSize: String, CaseIterable {
    case small, regular, large

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

enum MacRichTextFontFamily: String, CaseIterable {
    case sans, serif, mono

    var label: String {
        switch self {
        case .sans:  return "Sans"
        case .serif: return "Serif"
        case .mono:  return "Mono"
        }
    }

    func font(size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont {
        let base: NSFont = {
            switch self {
            case .sans:
                return NSFont.systemFont(ofSize: size, weight: weight)
            case .serif:
                return NSFont(name: "NewYork-Regular", size: size)
                    ?? NSFont(name: "Times New Roman", size: size)
                    ?? NSFont.systemFont(ofSize: size, weight: weight)
            case .mono:
                return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            }
        }()
        guard italic else { return base }
        let manager = NSFontManager.shared
        return manager.convert(base, toHaveTrait: .italicFontMask)
    }
}

enum MacRichTextAlignment: CaseIterable {
    case left, center, right

    var systemImage: String {
        switch self {
        case .left:   return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right:  return "text.alignright"
        }
    }

    var ns: NSTextAlignment {
        switch self {
        case .left:   return .left
        case .center: return .center
        case .right:  return .right
        }
    }

    static func from(_ alignment: NSTextAlignment) -> MacRichTextAlignment {
        switch alignment {
        case .center: return .center
        case .right, .justified, .natural: return .right
        default: return .left
        }
    }
}

enum MacRichTextListMode: String {
    case none, bullet, numbered
}

struct MacRichTextAttributeSnapshot: Equatable {
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isStrikethrough = false
    var heading: MacRichTextHeading = .body
    var size: MacRichTextSize = .regular
    var family: MacRichTextFontFamily = .sans
    var alignment: MacRichTextAlignment = .left
    var listMode: MacRichTextListMode = .none
    var foreground: NSColor?
    var highlight: NSColor?
}

enum MacRichTextColorPalette {
    static let swatchesLight: [NSColor] = [
        NSColor(hex: "#1C1C1A"),
        NSColor(hex: "#C0392B"),
        NSColor(hex: "#D68910"),
        NSColor(hex: "#1E8449"),
        NSColor(hex: "#2471A3"),
        NSColor(hex: "#6C3483"),
        NSColor(hex: "#7B6F4F"),
        NSColor(hex: "#7F8C8D"),
    ]

    static let swatchesDark: [NSColor] = [
        NSColor(hex: "#EDEDEB"),
        NSColor(hex: "#E57373"),
        NSColor(hex: "#F5B041"),
        NSColor(hex: "#58D68D"),
        NSColor(hex: "#5DADE2"),
        NSColor(hex: "#BB8FCE"),
        NSColor(hex: "#C7A877"),
        NSColor(hex: "#B0B0B0"),
    ]

    static let highlights: [NSColor] = [
        NSColor(hex: "#FFF59D"),
        NSColor(hex: "#C8E6C9"),
        NSColor(hex: "#BBDEFB"),
        NSColor(hex: "#F8BBD0"),
    ]

    static func textSwatches(isDark: Bool) -> [NSColor] {
        isDark ? swatchesDark : swatchesLight
    }
}

// MARK: - Controller

@MainActor
final class MacRichTextController: ObservableObject {
    @Published var currentAttributes = MacRichTextAttributeSnapshot()

    private weak var textView: NSTextView?
    private var defaultInkColor: NSColor = .labelColor
    private var pendingActions: [() -> Void] = []

    static let headingKey = NSAttributedString.Key("ceciliasnotes.heading")
    static let sizeKey = NSAttributedString.Key("ceciliasnotes.size")
    static let listKey = NSAttributedString.Key("ceciliasnotes.list")

    func attach(_ textView: NSTextView, defaultInk: NSColor = .labelColor) {
        self.textView = textView
        self.defaultInkColor = defaultInk
        MacStateUpdates.deferred { [weak self] in self?.refresh() }
        let pending = pendingActions
        pendingActions.removeAll()
        guard !pending.isEmpty else { return }
        MacStateUpdates.deferred { [weak self] in
            guard let self else { return }
            pending.forEach { $0() }
            self.refresh()
        }
    }

    func detach() {
        textView = nil
        pendingActions.removeAll()
        currentAttributes = MacRichTextAttributeSnapshot()
    }

    /// Runs on the next tick when a text view is attached; otherwise queues until attach.
    func performWhenReady(_ action: @escaping () -> Void) {
        if textView != nil {
            MacStateUpdates.deferred { action() }
        } else {
            pendingActions.append(action)
        }
    }

    /// A format action fired from preview state (no caret in the
    /// text) means "format this block" — a zero-length selection
    /// would silently mutate only typing attributes, which reads as
    /// the toolbar doing nothing. Select everything so the action
    /// has a visible target.
    func selectAllIfNoSelection() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        guard tv.selectedRange().length == 0, storage.length > 0 else { return }
        tv.setSelectedRange(NSRange(location: 0, length: storage.length))
    }

    func refresh() {
        guard let tv = textView else { return }
        let snap = snapshot(for: tv)
        if snap != currentAttributes {
            currentAttributes = snap
        }
    }

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    func toggleUnderline() {
        let on = !currentAttributes.isUnderline
        applyToSelection { attrs in
            var next = attrs
            next[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : 0
            return next
        }
    }

    func toggleStrikethrough() {
        let on = !currentAttributes.isStrikethrough
        applyToSelection { attrs in
            var next = attrs
            next[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : 0
            return next
        }
    }

    func setHeading(_ heading: MacRichTextHeading) {
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

    func setSize(_ size: MacRichTextSize) {
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

    func setFamily(_ family: MacRichTextFontFamily) {
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

    func setAlignment(_ alignment: MacRichTextAlignment) {
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

    func setForeground(_ color: NSColor?) {
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

    func setHighlight(_ color: NSColor?) {
        applyToSelection { attrs in
            var next = attrs
            if let color {
                next[.backgroundColor] = color
            } else {
                next.removeValue(forKey: .backgroundColor)
            }
            return next
        }
    }

    func clearFormatting() {
        applyToSelection { _ in
            var attrs = MacRichTextCodec.defaultTypingAttributes()
            attrs[Self.headingKey] = MacRichTextHeading.body.rawValue
            attrs[Self.sizeKey] = MacRichTextSize.regular.rawValue
            attrs[Self.listKey] = MacRichTextListMode.none.rawValue
            attrs[.font] = Self.buildFont(
                heading: .body,
                size: .regular,
                family: .sans,
                bold: false,
                italic: false
            )
            let para = NSMutableParagraphStyle()
            para.alignment = .left
            attrs[.paragraphStyle] = para
            attrs.removeValue(forKey: .backgroundColor)
            attrs.removeValue(forKey: .strikethroughStyle)
            attrs.removeValue(forKey: .underlineStyle)
            return attrs
        }
    }

    func toggleMono() {
        let next: MacRichTextFontFamily = currentAttributes.family == .mono ? .sans : .mono
        setFamily(next)
    }

    func toggleBullet() {
        let target: MacRichTextListMode = currentAttributes.listMode == .bullet ? .none : .bullet
        setListMode(target)
    }

    func toggleNumbered() {
        let target: MacRichTextListMode = currentAttributes.listMode == .numbered ? .none : .numbered
        setListMode(target)
    }

    // MARK: - Internals

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let isOn: Bool = trait == .boldFontMask ? currentAttributes.isBold : currentAttributes.isItalic
        applyToSelection { attrs in
            var next = attrs
            let base = (next[.font] as? NSFont) ?? Self.defaultFont(
                heading: currentAttributes.heading,
                size: currentAttributes.size,
                family: currentAttributes.family
            )
            let manager = NSFontManager.shared
            let converted = isOn
                ? manager.convert(base, toNotHaveTrait: trait)
                : manager.convert(base, toHaveTrait: trait)
            next[.font] = converted
            return next
        }
    }

    private func setListMode(_ mode: MacRichTextListMode) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let selection = tv.selectedRange()
        let nsText = storage.string as NSString
        let lineRange = nsText.lineRange(for: selection)
        let plain = storage.attributedSubstring(from: lineRange).string
        let lines = plain.components(separatedBy: "\n")
        var rebuilt: [String] = []
        var counter = 1
        for line in lines {
            let stripped = Self.stripListPrefix(line)
            switch mode {
            case .none: rebuilt.append(stripped)
            case .bullet: rebuilt.append(stripped.isEmpty ? "" : "• \(stripped)")
            case .numbered:
                rebuilt.append(stripped.isEmpty ? "" : "\(counter). \(stripped)")
                if !stripped.isEmpty { counter += 1 }
            }
        }
        let newText = rebuilt.joined(separator: "\n")
        var seedAttrs: [NSAttributedString.Key: Any] = [:]
        if storage.length > 0, lineRange.location < storage.length {
            seedAttrs = storage.attributes(at: lineRange.location, effectiveRange: nil)
        } else if !tv.typingAttributes.isEmpty {
            seedAttrs = tv.typingAttributes
        }
        seedAttrs[Self.listKey] = mode.rawValue
        storage.replaceCharacters(
            in: lineRange,
            with: NSAttributedString(string: newText, attributes: seedAttrs)
        )
        notifyDidChange()
        refreshDeferred()
    }

    private func applyToSelection(_ mutate: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            tv.typingAttributes = mutate(tv.typingAttributes)
            notifyDidChange()
            refreshDeferred()
            return
        }
        storage.beginEditing()
        storage.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            storage.setAttributes(mutate(attrs), range: subRange)
        }
        storage.endEditing()
        notifyDidChange()
        refreshDeferred()
    }

    private func applyToParagraph(_ mutate: ([NSAttributedString.Key: Any], NSRange) -> [NSAttributedString.Key: Any]) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let selection = tv.selectedRange()

        if selection.length == 0, storage.length == 0 {
            var current = tv.typingAttributes
            current = mutate(current, NSRange(location: 0, length: 0))
            tv.typingAttributes = current
            notifyDidChange()
            refreshDeferred()
            return
        }

        let nsText = storage.string as NSString
        let paragraphRange = nsText.paragraphRange(for: selection)

        guard paragraphRange.length > 0, paragraphRange.location < storage.length else {
            var current = tv.typingAttributes.isEmpty
                ? MacRichTextCodec.defaultTypingAttributes()
                : tv.typingAttributes
            current = mutate(current, paragraphRange)
            tv.typingAttributes = current
            notifyDidChange()
            refreshDeferred()
            return
        }

        storage.beginEditing()
        storage.enumerateAttributes(in: paragraphRange, options: []) { existing, subrange, _ in
            storage.setAttributes(mutate(existing, subrange), range: subrange)
        }
        storage.endEditing()

        var typing = tv.typingAttributes
        typing = mutate(typing, selection)
        tv.typingAttributes = typing
        notifyDidChange()
        refreshDeferred()
    }

    private func notifyDidChange() {
        guard let tv = textView else { return }
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
    }

    private func refreshDeferred() {
        MacStateUpdates.deferred { [weak self] in self?.refresh() }
    }

    private func snapshot(for tv: NSTextView) -> MacRichTextAttributeSnapshot {
        var snap = MacRichTextAttributeSnapshot()
        let range = tv.selectedRange()
        let attrs: [NSAttributedString.Key: Any] = {
            if range.length == 0 {
                if !tv.typingAttributes.isEmpty { return tv.typingAttributes }
                let loc = max(0, range.location - 1)
                if let storage = tv.textStorage, storage.length > 0, loc < storage.length {
                    return storage.attributes(at: loc, effectiveRange: nil)
                }
                return [:]
            }
            guard let storage = tv.textStorage, storage.length > 0 else { return [:] }
            let safeLoc = max(0, min(range.location, storage.length - 1))
            return storage.attributes(at: safeLoc, effectiveRange: nil)
        }()

        if let font = attrs[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            snap.isBold = traits.contains(.bold)
            snap.isItalic = traits.contains(.italic)
            snap.family = familyForFont(font)
            if let h = attrs[Self.headingKey] as? String, let parsed = MacRichTextHeading(rawValue: h) {
                snap.heading = parsed
            }
            if let s = attrs[Self.sizeKey] as? String, let parsed = MacRichTextSize(rawValue: s) {
                snap.size = parsed
            }
        }
        if let style = attrs[.underlineStyle] as? Int { snap.isUnderline = style != 0 }
        if let style = attrs[.strikethroughStyle] as? Int { snap.isStrikethrough = style != 0 }
        if let para = attrs[.paragraphStyle] as? NSParagraphStyle {
            snap.alignment = MacRichTextAlignment.from(para.alignment)
        }
        if let list = attrs[Self.listKey] as? String, let mode = MacRichTextListMode(rawValue: list) {
            snap.listMode = mode
        }
        if let fg = attrs[.foregroundColor] as? NSColor {
            snap.foreground = colorsMatch(fg, defaultInkColor) ? nil : fg
        }
        if let bg = attrs[.backgroundColor] as? NSColor {
            snap.highlight = bg
        }
        return snap
    }

    private func familyForFont(_ font: NSFont) -> MacRichTextFontFamily {
        let name = font.fontName.lowercased()
        if name.contains("mono") { return .mono }
        if name.contains("newyork") || name.contains("times") || name.contains("serif") { return .serif }
        return .sans
    }

    private func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let ca = a.usingColorSpace(.deviceRGB), let cb = b.usingColorSpace(.deviceRGB) else { return false }
        return abs(ca.redComponent - cb.redComponent) < 0.02
            && abs(ca.greenComponent - cb.greenComponent) < 0.02
            && abs(ca.blueComponent - cb.blueComponent) < 0.02
    }

    static func buildFont(
        heading: MacRichTextHeading,
        size: MacRichTextSize,
        family: MacRichTextFontFamily,
        bold: Bool,
        italic: Bool
    ) -> NSFont {
        let pointSize = heading.basePointSize * size.multiplier
        var font = family.font(size: pointSize, weight: heading.weight, italic: italic)
        if bold {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        return font
    }

    static func defaultFont(heading: MacRichTextHeading, size: MacRichTextSize, family: MacRichTextFontFamily) -> NSFont {
        buildFont(heading: heading, size: size, family: family, bold: false, italic: false)
    }

    static func stripListPrefix(_ line: String) -> String {
        var s = line
        if s.hasPrefix("• ") { s = String(s.dropFirst(2)) }
        if let dot = s.firstIndex(of: "."), dot > s.startIndex {
            let prefix = s[..<dot]
            if Int(prefix) != nil, s.index(after: dot) < s.endIndex, s[s.index(after: dot)] == " " {
                s = String(s[s.index(dot, offsetBy: 2)...])
            }
        }
        return s
    }
}

// MARK: - Format toolbar

struct MacTextFormatToolbar: View {
    @ObservedObject var controller: MacRichTextController
    var isEditingText: Bool
    var onNeedsTextFocus: () -> Void = {}
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isInkPopoverOpen = false
    @State private var isHighlightPopoverOpen = false

    private var textSwatches: [NSColor] {
        MacRichTextColorPalette.textSwatches(isDark: colorScheme == .dark)
    }

    var body: some View {
        HStack(spacing: 0) {
            formatEyebrow
            Spacer(minLength: 16)
            toolRail
            Spacer(minLength: 16)
            formatStatus
        }
        .padding(.horizontal, 4)
        .frame(height: MacEditorChromeMetrics.formatToolbarHeight)
    }

    private var formatEyebrow: some View {
        Text("format")
            .font(.system(size: 9.5, weight: .regular))
            .tracking(0.1)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveTertiary)
            .frame(width: 52, alignment: .leading)
    }

    /// Quiet editing indicator — a single accent dot while a block
    /// has the caret, nothing otherwise. (This slot briefly said
    /// "click text", which read as a broken button.)
    @ViewBuilder
    private var formatStatus: some View {
        Group {
            if isEditingText {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: 5, height: 5)
            }
        }
        .frame(width: 52, alignment: .trailing)
    }

    private var toolRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                styleToggles
                toolbarDivider
                headingMenu
                familyMenu
                sizePicker
                toolbarDivider
                alignmentPicker
                listToggles
                toolbarDivider
                inkControl
                highlightControl
                toolbarDivider
                iconToggle("textformat", isOn: false) { applyFormat { controller.clearFormatting() } }
                    .accessibilityLabel("Clear formatting")
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var foregroundBinding: Binding<Color> {
        Binding(
            get: {
                if let fg = controller.currentAttributes.foreground {
                    return Color(nsColor: fg)
                }
                return Color.primary
            },
            set: { color in
                applyFormat { controller.setForeground(NSColor(color)) }
            }
        )
    }

    private var highlightBinding: Binding<Color> {
        Binding(
            get: {
                if let bg = controller.currentAttributes.highlight {
                    return Color(nsColor: bg)
                }
                return Color.yellow.opacity(0.35)
            },
            set: { color in
                applyFormat { controller.setHighlight(NSColor(color)) }
            }
        )
    }

    private func applyFormat(_ action: @escaping () -> Void) {
        // From preview state the click first has to focus a block;
        // `performWhenReady` holds the action until the text view
        // attaches. `wasEditing` is captured NOW — once focus lands
        // the state always says "editing", but only a preview-state
        // click should widen to the whole block.
        let wasEditing = isEditingText
        MacStateUpdates.deferred {
            onNeedsTextFocus()
            controller.performWhenReady { [weak controller] in
                guard let controller else { return }
                if !wasEditing { controller.selectAllIfNoSelection() }
                action()
            }
        }
    }

    private var styleToggles: some View {
        HStack(spacing: 4) {
            iconToggle("bold", isOn: controller.currentAttributes.isBold) { applyFormat { controller.toggleBold() } }
            iconToggle("italic", isOn: controller.currentAttributes.isItalic) { applyFormat { controller.toggleItalic() } }
            iconToggle("underline", isOn: controller.currentAttributes.isUnderline) { applyFormat { controller.toggleUnderline() } }
            iconToggle("strikethrough", isOn: controller.currentAttributes.isStrikethrough) { applyFormat { controller.toggleStrikethrough() } }
            iconToggle("chevron.left.forwardslash.chevron.right", isOn: controller.currentAttributes.family == .mono) {
                applyFormat { controller.toggleMono() }
            }
            .accessibilityLabel("Monospace")
        }
    }

    private var headingMenu: some View {
        Menu {
            ForEach(MacRichTextHeading.allCases, id: \.self) { h in
                Button { applyFormat { controller.setHeading(h) } } label: {
                    HStack {
                        Text(h.label)
                        if controller.currentAttributes.heading == h {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            menuLabel(title: controller.currentAttributes.heading.label, width: 52)
        }
        .menuStyle(.borderlessButton)
        .macSuppressFocusRing()
    }

    private var sizePicker: some View {
        HStack(spacing: 0) {
            ForEach(MacRichTextSize.allCases, id: \.self) { size in
                Button { applyFormat { controller.setSize(size) } } label: {
                    Text(size.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            controller.currentAttributes.size == size
                                ? theme.accent
                                : theme.foregroundMuted
                        )
                        .frame(width: 26, height: 28)
                        .background(
                            controller.currentAttributes.size == size
                                ? theme.accentMuted
                                : Color.clear
                        )
                }
                .buttonStyle(.plain)
                .macSuppressFocusRing()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.recessiveQuinary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var inkControl: some View {
        Button {
            isInkPopoverOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(currentInkColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(theme.hairline, lineWidth: 0.5))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.recessiveSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.recessiveQuinary.opacity(0.35))
            )
        }
        .macEditorChromeButton()
        .popover(isPresented: $isInkPopoverOpen, arrowEdge: .bottom) {
            MacTextColorPopover(
                title: "Text color",
                selection: foregroundBinding,
                swatches: textSwatches,
                onDefault: { applyFormat { controller.setForeground(nil) } },
                onPickSwatch: { swatch in applyFormat { controller.setForeground(swatch) } }
            )
            .padding(14)
            .frame(width: 236)
        }
        .accessibilityLabel("Text color")
    }

    private var currentInkColor: Color {
        if let fg = controller.currentAttributes.foreground {
            return Color(nsColor: fg)
        }
        return theme.foreground
    }

    private func inkName(for swatch: NSColor) -> String {
        guard let rgb = swatch.usingColorSpace(.sRGB) else { return "Color" }
        if rgb.redComponent < 0.2, rgb.greenComponent < 0.2, rgb.blueComponent < 0.2 { return "Black" }
        if rgb.redComponent > 0.75, rgb.greenComponent < 0.4 { return "Red" }
        if rgb.greenComponent > 0.45, rgb.redComponent < 0.5 { return "Green" }
        if rgb.blueComponent > 0.55, rgb.redComponent < 0.4 { return "Blue" }
        return "Color"
    }

    private var highlightControl: some View {
        Button {
            isHighlightPopoverOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(currentHighlightColor)
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(theme.hairline, lineWidth: 0.5)
                    )
                Image(systemName: "highlighter")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.recessiveSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.recessiveQuinary.opacity(0.35))
            )
        }
        .macEditorChromeButton()
        .popover(isPresented: $isHighlightPopoverOpen, arrowEdge: .bottom) {
            MacTextColorPopover(
                title: "Highlight",
                selection: highlightBinding,
                swatches: MacRichTextColorPalette.highlights,
                onDefault: { applyFormat { controller.setHighlight(nil) } },
                onPickSwatch: { swatch in applyFormat { controller.setHighlight(swatch) } }
            )
            .padding(14)
            .frame(width: 236)
        }
        .accessibilityLabel("Highlight color")
    }

    private var currentHighlightColor: Color {
        if let highlight = controller.currentAttributes.highlight {
            return Color(nsColor: highlight)
        }
        return theme.recessiveQuinary.opacity(0.5)
    }

    private func colorsMatch(_ a: NSColor?, _ b: NSColor?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.usingColorSpace(.sRGB) == rhs.usingColorSpace(.sRGB)
        default: return false
        }
    }

    private func menuLabel(title: String, width: CGFloat? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(theme.foregroundMuted)
        .frame(minWidth: width ?? 0, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.recessiveQuinary.opacity(0.35))
        )
    }

    private var familyMenu: some View {
        Menu {
            ForEach(MacRichTextFontFamily.allCases, id: \.self) { f in
                Button { applyFormat { controller.setFamily(f) } } label: {
                    HStack {
                        Text(f.label)
                        if controller.currentAttributes.family == f {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            menuLabel(title: controller.currentAttributes.family.label, width: 48)
        }
        .menuStyle(.borderlessButton)
        .macSuppressFocusRing()
    }

    private var alignmentPicker: some View {
        HStack(spacing: 0) {
            ForEach(MacRichTextAlignment.allCases, id: \.self) { a in
                Button { applyFormat { controller.setAlignment(a) } } label: {
                    Image(systemName: a.systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            controller.currentAttributes.alignment == a
                                ? theme.accent
                                : theme.foregroundMuted
                        )
                        .frame(width: 30, height: 28)
                        .background(
                            controller.currentAttributes.alignment == a
                                ? theme.accentMuted
                                : Color.clear
                        )
                }
                .buttonStyle(.plain)
                .macSuppressFocusRing()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.recessiveQuinary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var listToggles: some View {
        HStack(spacing: 4) {
            iconToggle("list.bullet", isOn: controller.currentAttributes.listMode == .bullet) { applyFormat { controller.toggleBullet() } }
            iconToggle("list.number", isOn: controller.currentAttributes.listMode == .numbered) { applyFormat { controller.toggleNumbered() } }
        }
    }

    private func iconToggle(_ systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? theme.accent : theme.foregroundMuted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? theme.accentMuted : theme.recessiveQuinary.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .macSuppressFocusRing()
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(width: 0.5, height: 20)
    }
}

// MARK: - Color popover (Google Docs–style picker, not inline swatch row)

private struct MacTextColorPopover: View {
    let title: String
    @Binding var selection: Color
    let swatches: [NSColor]
    var onDefault: () -> Void
    var onPickSwatch: (NSColor) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.foregroundMuted)

            ColorPicker("Custom", selection: $selection, supportsOpacity: false)
                .labelsHidden()

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, swatch in
                    Button {
                        onPickSwatch(swatch)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: swatch))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(theme.hairline, lineWidth: 0.5))
                    }
                    .macEditorChromeButton()
                }
            }

            Button("Reset to default") {
                onDefault()
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.accent)
            .macEditorChromeButton()
        }
    }
}
