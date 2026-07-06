import AppKit
import SwiftUI

/// AppKit rich-text editor for Mac text elements — reads/writes
/// `TextContent.attributedTextData` using the same keyed archive as iPad.
struct MacRichTextEditor: NSViewRepresentable {
    @Binding var attributedString: NSAttributedString
    var onPlainTextChange: (String) -> Void
    var onTextViewCreated: ((NSTextView) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.textStorage?.setAttributedString(attributedString)
        context.coordinator.textView = textView
        onTextViewCreated?(textView)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.attributedString() != attributedString {
            textView.textStorage?.setAttributedString(attributedString)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(attributedString: $attributedString, onPlainTextChange: onPlainTextChange)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var attributedString: NSAttributedString
        let onPlainTextChange: (String) -> Void
        weak var textView: NSTextView?

        /// Popover that hosts the slash-command menu. Held here so a
        /// second `/` doesn't spawn a second popover — we reuse the
        /// same one and re-anchor it to the caret.
        private var slashPopover: NSPopover?
        /// Character index of the `/` that triggered the current
        /// popover. Used to delete the sigil when a command runs and
        /// to close the popover if the user backspaces past it.
        private var slashOriginIndex: Int?

        init(attributedString: Binding<NSAttributedString>, onPlainTextChange: @escaping (String) -> Void) {
            _attributedString = attributedString
            self.onPlainTextChange = onPlainTextChange
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let value = tv.attributedString()
            attributedString = value
            onPlainTextChange(value.string)
            handleSlashDetection(tv)
        }

        // MARK: - Slash commands

        /// Detect a `/` typed at the start of a line and open the
        /// command menu at the caret. We check on every keystroke so
        /// backspacing past the sigil (or moving the caret away)
        /// closes the popover.
        private func handleSlashDetection(_ tv: NSTextView) {
            let str = tv.string as NSString
            let selected = tv.selectedRange()

            // Close the popover if the caret drifted away from the
            // sigil or the character was deleted.
            if let origin = slashOriginIndex {
                let outOfBounds = origin >= str.length
                let caretMoved = selected.location < origin || selected.location > origin + 32
                let sigilGone = !outOfBounds && str.character(at: origin) != 47 // '/'
                if outOfBounds || caretMoved || sigilGone {
                    dismissSlashPopover()
                }
            }

            // Look at the character immediately before the caret.
            guard selected.length == 0, selected.location > 0 else { return }
            let idx = selected.location - 1
            guard idx < str.length, str.character(at: idx) == 47 else { return } // '/'

            // Line-start check: idx == 0 OR previous char is newline.
            let atLineStart = idx == 0 || str.character(at: idx - 1) == 10 // '\n'
            guard atLineStart else { return }

            // Don't re-open if we already have a popover anchored at
            // this exact position.
            if slashOriginIndex == idx, slashPopover?.isShown == true { return }

            presentSlashPopover(at: idx, in: tv)
        }

        private func presentSlashPopover(at charIndex: Int, in tv: NSTextView) {
            dismissSlashPopover()

            let range = NSRange(location: charIndex, length: 1)
            let screenRect = tv.firstRect(forCharacterRange: range, actualRange: nil)
            guard let window = tv.window else { return }
            let windowRect = window.convertFromScreen(screenRect)
            let anchor = tv.convert(windowRect, from: nil)

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 300, height: 210)

            let menu = MacDocSlashMenu(onCommand: { [weak self] command in
                self?.handleSlashCommand(command)
            })
            popover.contentViewController = NSHostingController(
                rootView: menu.environment(\.theme, ThemeManager.shared.current)
            )
            popover.show(relativeTo: anchor, of: tv, preferredEdge: .maxY)

            slashPopover = popover
            slashOriginIndex = charIndex
        }

        private func dismissSlashPopover() {
            slashPopover?.performClose(nil)
            slashPopover = nil
            slashOriginIndex = nil
        }

        private func handleSlashCommand(_ command: MacDocSlashMenu.Command) {
            guard let tv = textView, let origin = slashOriginIndex else { return }
            // Delete the `/` sigil so the command result reads clean
            // in the document (it's a trigger, not content).
            let deleteRange = NSRange(location: origin, length: 1)
            tv.textStorage?.deleteCharacters(in: deleteRange)
            tv.setSelectedRange(NSRange(location: origin, length: 0))
            dismissSlashPopover()

            switch command {
            case .summarize:
                NotificationCenter.default.post(name: .macSummarizePage, object: nil)
            case .ask:
                NotificationCenter.default.post(name: .macAskAboutPage, object: nil)
            case .rewrite:
                runInlineAI(command: .rewrite, textView: tv, at: origin)
            case .continueWriting:
                runInlineAI(command: .continueWriting, textView: tv, at: origin)
            }
        }

        /// Route `/rewrite` and `/continue` through the on-device
        /// provider directly. `/rewrite` operates on the current
        /// paragraph and replaces it; `/continue` appends after the
        /// caret. Gated on `IntelligenceService.canRun` so a device
        /// without on-device models silently no-ops rather than
        /// showing a broken command.
        private func runInlineAI(
            command: MacDocSlashMenu.Command,
            textView tv: NSTextView,
            at charIndex: Int
        ) {
            guard IntelligenceService.shared.canRun else { return }

            let str = tv.string as NSString
            let paragraphRange = str.paragraphRange(for: NSRange(location: charIndex, length: 0))
            let paragraphText = str.substring(with: paragraphRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let system: String
            let user: String
            switch command {
            case .rewrite:
                system = "You rewrite the user's paragraph for clarity and concision. Keep the voice. Return only the rewritten paragraph, no preamble."
                user = paragraphText.isEmpty ? "(empty paragraph — leave blank)" : paragraphText
            case .continueWriting:
                system = "You continue the user's writing from where they stopped. One or two sentences. Match the voice. Return only the continuation text."
                user = paragraphText.isEmpty ? "(no lead-in)" : paragraphText
            default:
                return
            }

            let placeholder = NSAttributedString(
                string: " …",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            )
            let insertLocation: Int = {
                switch command {
                case .rewrite:         return paragraphRange.location
                case .continueWriting: return charIndex
                default:               return charIndex
                }
            }()

            #if canImport(FoundationModels)
            let provider = AppleFoundationProvider()
            Task { [weak self] in
                do {
                    let result = try await provider.complete(
                        systemPrompt: system,
                        userPrompt: user,
                        maxTokens: 260,
                        temperature: 0.4
                    )
                    await MainActor.run {
                        self?.insertAIResult(
                            result,
                            command: command,
                            paragraphRange: paragraphRange,
                            insertLocation: insertLocation,
                            in: tv
                        )
                    }
                } catch {
                    #if DEBUG
                    print("[slash] AI command failed: \(error)")
                    #endif
                }
            }
            #endif
            _ = placeholder // reserved for a future in-flight indicator
        }

        private func insertAIResult(
            _ text: String,
            command: MacDocSlashMenu.Command,
            paragraphRange: NSRange,
            insertLocation: Int,
            in tv: NSTextView
        ) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.labelColor,
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            switch command {
            case .rewrite:
                tv.textStorage?.replaceCharacters(in: paragraphRange, with: attributed)
                tv.setSelectedRange(NSRange(location: paragraphRange.location + text.count, length: 0))
            case .continueWriting:
                let prefix = text.hasPrefix(" ") ? "" : " "
                let combined = NSAttributedString(string: prefix + text, attributes: attributes)
                tv.textStorage?.insert(combined, at: insertLocation)
                tv.setSelectedRange(NSRange(location: insertLocation + combined.length, length: 0))
            default:
                break
            }
            let value = tv.attributedString()
            attributedString = value
            onPlainTextChange(value.string)
        }
    }
}

enum MacRichTextCodec {
    static func defaultTypingAttributes(size: TextSize = .body) -> [NSAttributedString.Key: Any] {
        let font: NSFont = {
            switch size {
            case .heading: return .systemFont(ofSize: 22, weight: .semibold)
            case .small:   return .systemFont(ofSize: 13)
            default:       return .systemFont(ofSize: 15)
            }
        }()
        return [.font: font, .foregroundColor: NSColor.labelColor]
    }

    static func decode(from content: TextContent) -> NSAttributedString {
        if let data = content.attributedTextData, !data.isEmpty,
           let attr = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) {
            return attr
        }
        let font: NSFont = {
            switch content.size {
            case .heading: return .systemFont(ofSize: 22, weight: .semibold)
            case .small:   return .systemFont(ofSize: 13)
            default:       return .systemFont(ofSize: 15)
            }
        }()
        return NSAttributedString(string: content.text, attributes: [.font: font])
    }

    static func encode(_ value: NSAttributedString) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
    }
}

struct MacRichTextFormatBar: View {
    let textView: NSTextView?

    var body: some View {
        HStack(spacing: 8) {
            formatButton("Bold", systemImage: "bold") { toggleTrait(.boldFontMask) }
            formatButton("Italic", systemImage: "italic") { toggleTrait(.italicFontMask) }
            formatButton("Underline", systemImage: "underline") { toggleUnderline() }
            Divider().frame(height: 16)
            Menu {
                Button("Small") { applySize(13) }
                Button("Body") { applySize(15) }
                Button("Heading") { applySize(22, weight: .semibold) }
            } label: {
                Label("Size", systemImage: "textformat.size")
            }
            .menuStyle(.borderlessButton)
            Menu {
                Button("Default") { applyColor(.labelColor) }
                Button("Accent") { applyColor(.controlAccentColor) }
                Button("Red") { applyColor(.systemRed) }
                Button("Blue") { applyColor(.systemBlue) }
            } label: {
                Label("Color", systemImage: "paintpalette")
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func formatButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        if tv.selectedRange().length == 0 {
            tv.typingAttributes = mutatedFontAttributes(in: tv, trait: trait)
            return
        }
        let manager = NSFontManager.shared
        manager.target = tv
        manager.addFontTrait(trait)
    }

    private func mutatedFontAttributes(in tv: NSTextView, trait: NSFontTraitMask) -> [NSAttributedString.Key: Any] {
        var attrs = tv.typingAttributes
        let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 15)
        let manager = NSFontManager.shared
        let converted = manager.convert(font, toHaveTrait: trait)
        attrs[.font] = converted
        return attrs
    }

    private func toggleUnderline() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        guard let storage = tv.textStorage else { return }
        if range.length == 0 {
            var attrs = tv.typingAttributes
            let current = attrs[.underlineStyle] as? Int ?? 0
            attrs[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.typingAttributes = attrs
            return
        }
        let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
        let next = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        storage.addAttribute(.underlineStyle, value: next, range: range)
    }

    private func applySize(_ pointSize: CGFloat, weight: NSFont.Weight = .regular) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        guard let storage = tv.textStorage else { return }
        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.font] = NSFont.systemFont(ofSize: pointSize, weight: weight)
            tv.typingAttributes = attrs
            return
        }
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: pointSize, weight: weight), range: range)
    }

    private func applyColor(_ color: NSColor) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        guard let storage = tv.textStorage else { return }
        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.foregroundColor] = color
            tv.typingAttributes = attrs
            return
        }
        storage.addAttribute(.foregroundColor, value: color, range: range)
    }
}
