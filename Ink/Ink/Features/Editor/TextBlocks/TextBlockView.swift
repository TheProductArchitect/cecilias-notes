import SafariServices
import SwiftUI
import UIKit

// MARK: - InkTextView

/// UITextView subclass that adds Cmd+B/I/U/K key commands and exposes a
/// callback so the hosting coordinator can respond without being in the responder chain.
final class InkTextView: UITextView {

    var onKeyCommand: ((RichTextToolbar.Action) -> Void)?
    var onEscape:     (() -> Void)?
    var onTab:        (() -> Void)?
    var onShiftTab:   (() -> Void)?

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
            UIKeyCommand(input: "\t", modifierFlags: [],
                         action: #selector(cmdTab),
                         discoverabilityTitle: "Indent / Next Block"),
            UIKeyCommand(input: "\t", modifierFlags: .shift,
                         action: #selector(cmdShiftTab),
                         discoverabilityTitle: "Outdent / Previous Block"),
        ]
    }

    @objc private func cmdBold()      { onKeyCommand?(.bold) }
    @objc private func cmdItalic()    { onKeyCommand?(.italic) }
    @objc private func cmdUnderline() { onKeyCommand?(.underline) }
    @objc private func cmdLink()      { onKeyCommand?(.link) }
    @objc private func cmdEscape()    { onEscape?() }
    @objc private func cmdTab()       { onTab?() }
    @objc private func cmdShiftTab()  { onShiftTab?() }
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
    /// Tab pressed while NOT inside a list — overlay should focus the next block by zIndex.
    var onRequestNextBlock: (() -> Void)? = nil
    /// Shift+Tab pressed while NOT inside a list — overlay should focus the previous block.
    var onRequestPreviousBlock: (() -> Void)? = nil

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
        // Always interactive — required for the `shouldInteractWith URL` delegate
        // to fire in idle/selected states. Hit-testing is gated by the parent
        // TextModeGestureController so this doesn't steal pencil/scroll.
        textView.isUserInteractionEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        // Link detection is enabled in idle/selected states (see updateUIView).
        textView.dataDetectorTypes = .link

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
        // Tab + Shift+Tab routing — list indent if inside a list, else focus next/prev block.
        let onNext = onRequestNextBlock
        let onPrev = onRequestPreviousBlock
        textView.onTab = { [weak coordinator] in
            guard let coord = coordinator, let tv = coord.textView else { return }
            if coord.isInListItem(textView: tv) {
                coord.indentListItem(textView: tv)
            } else {
                onNext?()
            }
        }
        textView.onShiftTab = { [weak coordinator] in
            guard let coord = coordinator, let tv = coord.textView else { return }
            if coord.isInListItem(textView: tv) {
                coord.dedentListItem(textView: tv)
            } else {
                onPrev?()
            }
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

        // Link tap-through is enabled in idle/selected, disabled in editing
        // (so the user can edit a URL without it auto-launching Safari).
        // dataDetectorTypes is also re-evaluated when attributedText is set,
        // which is why we set it on every update rather than once in makeUIView.
        let detectors: UIDataDetectorTypes = shouldEdit ? [] : .link
        if textView.dataDetectorTypes != detectors {
            textView.dataDetectorTypes = detectors
        }
        // Pass the current state down so the delegate can branch behaviour.
        context.coordinator.currentState = interactionState

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
        /// Updated by `updateUIView`. Used by `shouldInteractWith URL` to decide
        /// whether to intercept (idle/selected) or let UITextView handle it (editing).
        var currentState: TextBlockInteractionState = .idle

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

        // MARK: Link tap-through (idle / selected)

        /// In .idle and .selected states, intercept link taps and open them in
        /// SFSafariViewController. In .editing state, do nothing — let the user
        /// continue editing the underlying text. This is the canonical pattern
        /// for non-editing UITextViews.
        func textView(_ textView: UITextView,
                      shouldInteractWith URL: URL,
                      in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            guard currentState != .editing else { return true }
            presentSafari(for: URL)
            return false
        }

        private func presentSafari(for url: URL) {
            // Only present http(s) URLs to avoid e.g. tel: or mailto: surprises.
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            let safari = SFSafariViewController(url: url)
            safari.preferredControlTintColor = UIColor.inkAccentPrimary

            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
                  let root = scene.windows.first?.rootViewController
            else { return }

            // Walk to topmost presented view controller — settings sheets etc.
            var presenter: UIViewController = root
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(safari, animated: true)
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

        // MARK: List indent / outdent

        /// True iff the paragraph at the current cursor location has a non-empty
        /// `textLists` (i.e. it's a bullet or numbered-list item).
        func isInListItem(textView: UITextView) -> Bool {
            currentParagraphStyle(textView: textView)?
                .textLists.isEmpty == false
        }

        /// Increases list nesting level by one. Appends a new `NSTextList` to the
        /// paragraph's `textLists` array — UITextView re-renders the marker
        /// indented by one level. No-op if the cursor isn't in a list.
        func indentListItem(textView: UITextView) {
            mutateListLevel(textView: textView) { textLists in
                guard let last = textLists.last else { return textLists }
                // Reuse the marker style of the last (innermost) list.
                let marker = last.markerFormat
                let nested = NSTextList(markerFormat: marker, options: 0)
                return textLists + [nested]
            }
        }

        /// Decreases list nesting by one. Removes the last `NSTextList` from the
        /// paragraph's `textLists` array. If only one list level remains, it's
        /// removed entirely — the paragraph becomes a non-list paragraph.
        func dedentListItem(textView: UITextView) {
            mutateListLevel(textView: textView) { textLists in
                guard !textLists.isEmpty else { return textLists }
                return Array(textLists.dropLast())
            }
        }

        // MARK: List helpers

        private func currentParagraphStyle(textView: UITextView) -> NSParagraphStyle? {
            guard let attrText = textView.attributedText else { return nil }
            guard attrText.length > 0 else { return nil }
            let loc = max(0, min(textView.selectedRange.location, attrText.length - 1))
            return attrText.attribute(.paragraphStyle, at: loc, effectiveRange: nil)
                as? NSParagraphStyle
        }

        /// Applies a transformation to the paragraph-style `textLists` of the
        /// current paragraph and writes the result back. Preserves selection.
        private func mutateListLevel(
            textView: UITextView,
            transform: ([NSTextList]) -> [NSTextList]
        ) {
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let paragraphRange = (mutable.string as NSString)
                .paragraphRange(for: textView.selectedRange)

            mutable.enumerateAttribute(.paragraphStyle, in: paragraphRange,
                                        options: []) { value, subRange, _ in
                let style = (value as? NSParagraphStyle).flatMap {
                    $0.mutableCopy() as? NSMutableParagraphStyle
                } ?? NSMutableParagraphStyle()
                style.textLists = transform(style.textLists)
                mutable.addAttribute(.paragraphStyle, value: style, range: subRange)
            }

            let preservedSelection = textView.selectedRange
            textView.attributedText = mutable
            textView.selectedRange  = preservedSelection
            scheduleSave()
        }
    }
}
