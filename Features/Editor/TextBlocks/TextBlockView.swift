import SwiftUI
import UIKit

// MARK: - InkTextView

/// UITextView subclass that adds Cmd+B/I/U/K key commands and exposes a
/// callback so the hosting coordinator can respond without being in the responder chain.
final class InkTextView: UITextView {

    var onKeyCommand: ((RichTextToolbar.Action) -> Void)?
    var onEscape: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "b", modifierFlags: .command,
                         action: #selector(cmdBold), discoverabilityTitle: "Bold"),
            UIKeyCommand(input: "i", modifierFlags: .command,
                         action: #selector(cmdItalic), discoverabilityTitle: "Italic"),
            UIKeyCommand(input: "u", modifierFlags: .command,
                         action: #selector(cmdUnderline), discoverabilityTitle: "Underline"),
            UIKeyCommand(input: "k", modifierFlags: .command,
                         action: #selector(cmdLink), discoverabilityTitle: "Link"),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                         action: #selector(cmdEscape)),
        ]
    }

    @objc private func cmdBold()      { onKeyCommand?(.bold) }
    @objc private func cmdItalic()    { onKeyCommand?(.italic) }
    @objc private func cmdUnderline() { onKeyCommand?(.underline) }
    @objc private func cmdLink()      { onKeyCommand?(.link) }
    @objc private func cmdEscape()    { onEscape?() }
}

// MARK: - TextBlockView

/// UIViewRepresentable wrapping a UITextView configured for TextKit 2.
/// The host view is a fixed-frame overlay; the text view is non-scrolling and
/// auto-resizes by notifying onHeightChange.
struct TextBlockView: UIViewRepresentable {

    let block: TextBlock
    let pageSize: CGSize
    let interactionState: TextBlockInteractionState
    let onHeightChange: (CGFloat) -> Void    // called when intrinsic height changes
    let onCommit: (NSAttributedString) -> Void
    let onBecomeActive: () -> Void           // tapped but not editing → promote to editing
    let onRequestLink: (NSRange) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onBecomeActive: onBecomeActive,
                    onHeightChange: onHeightChange, onRequestLink: onRequestLink)
    }

    func makeUIView(context: Context) -> InkTextView {
        // TextKit 2 storage stack
        let storage    = NSTextContentStorage()
        let manager    = NSTextLayoutManager()
        let container  = NSTextContainer(size: CGSize(width: frameWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        manager.textContainer = container
        storage.addTextLayoutManager(manager)

        let textView = InkTextView(frame: .zero, textContainer: container)
        textView.backgroundColor   = .clear
        textView.isScrollEnabled   = false
        textView.isEditable        = false
        textView.isSelectable      = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []

        // Load content
        let attrText = loadAttributedText()
        textView.attributedText = attrText

        // Input accessory view
        let toolbar = RichTextToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        toolbar.delegate = context.coordinator
        textView.inputAccessoryView = toolbar

        // Wire external keyboard shortcuts through InkTextView callbacks
        let coordinator = context.coordinator
        textView.onKeyCommand = { [weak coordinator] action in
            guard let coord = coordinator, let tb = coord.toolbar else { return }
            coord.richTextToolbar(tb, didToggle: action)
        }
        textView.onEscape = { [weak coordinator] in
            coordinator?.textView?.resignFirstResponder()
        }

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.toolbar  = toolbar
        context.coordinator.block    = block

        return textView
    }

    func updateUIView(_ textView: InkTextView, context: Context) {
        // Sync editability with interaction state
        let shouldEdit = interactionState == .editing
        if textView.isEditable != shouldEdit {
            textView.isEditable = shouldEdit
            if shouldEdit {
                textView.becomeFirstResponder()
            } else {
                if textView.isFirstResponder { textView.resignFirstResponder() }
            }
        }

        // Reapply content only if block data changed (avoid disrupting active editing)
        if !textView.isFirstResponder {
            let fresh = loadAttributedText()
            if textView.attributedText.string != fresh.string {
                textView.attributedText = fresh
            }
        }

        // Update container width if frame changed
        let w = frameWidth
        if abs(textView.textContainer.size.width - w) > 1 {
            textView.textContainer.size = CGSize(width: w, height: .greatestFiniteMagnitude)
        }

        DispatchQueue.main.async {
            self.onHeightChange(textView.intrinsicContentSize.height)
        }
    }

    // MARK: Helpers

    private var frameWidth: CGFloat {
        block.width * pageSize.width - 16   // subtract insets
    }

    private func loadAttributedText() -> NSAttributedString {
        if let data = block.richTextData,
           let decoded = try? NSKeyedUnarchiver.unarchivedObject(
               ofClass: NSAttributedString.self, from: data) {
            return decoded
        }
        return block.content.isEmpty
            ? RichTextAttributes.makeDefault()
            : NSAttributedString(string: block.content, attributes: RichTextAttributes.defaultAttributes)
    }
}

// MARK: - Coordinator

extension TextBlockView {

    final class Coordinator: NSObject, UITextViewDelegate, RichTextToolbarDelegate {

        let onCommit: (NSAttributedString) -> Void
        let onBecomeActive: () -> Void
        let onHeightChange: (CGFloat) -> Void
        let onRequestLink: (NSRange) -> Void

        weak var textView: UITextView?
        weak var toolbar:  RichTextToolbar?
        var block: TextBlock?

        private var shortcutHandler: MarkdownShortcutHandler?
        private var saveTask: Task<Void, Never>?

        init(onCommit: @escaping (NSAttributedString) -> Void,
             onBecomeActive: @escaping () -> Void,
             onHeightChange: @escaping (CGFloat) -> Void,
             onRequestLink: @escaping (NSRange) -> Void) {
            self.onCommit       = onCommit
            self.onBecomeActive = onBecomeActive
            self.onHeightChange = onHeightChange
            self.onRequestLink  = onRequestLink
        }

        // MARK: UITextViewDelegate

        func textViewDidBeginEditing(_ textView: UITextView) {
            shortcutHandler = MarkdownShortcutHandler(textView: textView)
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            // Escape → resign
            if text == "\u{1B}" {
                textView.resignFirstResponder()
                return false
            }
            // Delegate to markdown handler
            return shortcutHandler?.handle(range: range, text: text) ?? true
        }

        func textViewDidChange(_ textView: UITextView) {
            // Update toolbar active states
            updateToolbarState()
            // Notify height change
            onHeightChange(textView.intrinsicContentSize.height)
            // Debounce save
            scheduleSave()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateToolbarState()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            commitNow()
        }

        // MARK: RichTextToolbarDelegate

        func richTextToolbar(_ toolbar: RichTextToolbar, didToggle action: RichTextToolbar.Action) {
            guard let textView else { return }
            let range = textView.selectedRange.length > 0
                ? textView.selectedRange
                : wholeTextRange(of: textView)
            let attrString = NSMutableAttributedString(attributedString: textView.attributedText)
            switch action {
            case .bold:       RichTextAttributes.toggleBold(attrString, range: range)
            case .italic:     RichTextAttributes.toggleItalic(attrString, range: range)
            case .underline:  RichTextAttributes.toggleUnderline(attrString, range: range)
            case .h1:         RichTextAttributes.applyHeading(.h1, to: attrString, range: range)
            case .h2:         RichTextAttributes.applyHeading(.h2, to: attrString, range: range)
            case .h3:         RichTextAttributes.applyHeading(.h3, to: attrString, range: range)
            case .bullet:     RichTextAttributes.toggleBulletList(attrString, range: range)
            case .code:       RichTextAttributes.toggleCode(attrString, range: range)
            case .blockquote: RichTextAttributes.toggleBlockquote(attrString, range: range)
            case .link:       break   // handled below
            }
            let selected = textView.selectedRange
            textView.attributedText = attrString
            textView.selectedRange  = selected
            updateToolbarState()
            scheduleSave()
        }

        func richTextToolbarDidRequestLink(_ toolbar: RichTextToolbar) {
            guard let textView else { return }
            onRequestLink(textView.selectedRange)
        }

        func richTextToolbarDidDismissKeyboard(_ toolbar: RichTextToolbar) {
            textView?.resignFirstResponder()
        }

        // MARK: Helpers

        private func updateToolbarState() {
            guard let textView, let toolbar else { return }
            let loc = max(0, textView.selectedRange.location - 1)
            guard let attrText = textView.attributedText, attrText.length > 0 else { return }
            toolbar.isBold      = RichTextAttributes.isBold(in: attrText, at: loc)
            toolbar.isItalic    = RichTextAttributes.isItalic(in: attrText, at: loc)
            toolbar.isUnderline = RichTextAttributes.isUnderline(in: attrText, at: loc)
            toolbar.isCode      = RichTextAttributes.isCode(in: attrText, at: loc)
            toolbar.hasLink     = RichTextAttributes.linkURL(in: attrText, at: loc) != nil
        }

        private func wholeTextRange(of textView: UITextView) -> NSRange {
            NSRange(location: 0, length: textView.attributedText.length)
        }

        private func scheduleSave() {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.0))
                guard !Task.isCancelled, let self else { return }
                await MainActor.run { self.commitNow() }
            }
        }

        private func commitNow() {
            guard let textView else { return }
            saveTask?.cancel()
            onCommit(textView.attributedText)
        }
    }
}
