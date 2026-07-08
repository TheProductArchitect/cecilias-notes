import AppKit
import SwiftData
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
        MacDictationTrigger.register(textView)
        onTextViewCreated?(textView)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Never push the SwiftUI binding back into the field while it is
        // first responder — system dictation streams partial results and
        // fighting the text view here freezes the app.
        guard textView.window?.firstResponder !== textView else { return }
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

        func textDidBeginEditing(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            MacDictationTrigger.register(tv)
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

            let menu = MacDocSlashMenu(
                onCommand: { [weak self] command in
                    self?.handleSlashCommand(command)
                },
                onDismiss: { [weak self] in
                    self?.dismissSlashPopover()
                }
            )
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

// MARK: - Doc-mode growing editor (no inner scroll — newlines expand downward)

/// Non-scrollable text host for the linear doc view. The previous
/// `NSTextView.scrollableTextView()` wrapper scrolled inside a fixed
/// 22pt frame, so Return moved text up instead of growing the block.
final class MacDocTextContainer: NSView {
    let textView: NSTextView
    var onMovedToWindow: (() -> Void)?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(24, bounds.height))
    }

    override init(frame frameRect: NSRect) {
        textView = NSTextView(frame: .zero)
        super.init(frame: frameRect)
        wantsLayer = true
        focusRingType = .none
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.focusRingType = .none
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMovedToWindow?() }
    }

    override func layout() {
        super.layout()
        textView.frame = NSRect(origin: .zero, size: bounds.size)
    }

    func applyWidth(_ width: CGFloat) {
        guard width > 1, abs(frame.width - width) > 0.5 else {
            growToFit(maxHeight: nil)
            return
        }
        frame.size.width = width
        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        growToFit(maxHeight: nil)
    }

    func growToFit(maxHeight: CGFloat? = nil) {
        guard let container = textView.textContainer,
              let layout = textView.layoutManager else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        var needed = max(24, ceil(used.height) + textView.textContainerInset.height * 2 + 6)
        if let maxHeight {
            needed = min(needed, max(24, maxHeight))
        }
        guard abs(bounds.height - needed) > 1 else { return }
        frame.size.height = needed
        textView.frame.size.height = needed
        invalidateIntrinsicContentSize()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let local = convert(point, to: textView)
        return textView.hitTest(local) ?? textView
    }
}

struct MacDocGrowingRichTextEditor: NSViewRepresentable {
    @Bindable var element: PageElement
    let notebook: Notebook
    let page: Page
    let modelContext: ModelContext
    var columnWidth: CGFloat
    var pageDisplayHeight: CGFloat
    var richTextController: MacRichTextController
    var onWritingBegan: () -> Void
    var onEndEdit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            element: element,
            notebook: notebook,
            page: page,
            modelContext: modelContext,
            pageDisplayHeight: pageDisplayHeight,
            richTextController: richTextController,
            onWritingBegan: onWritingBegan,
            onEndEdit: onEndEdit
        )
    }

    func makeNSView(context: Context) -> MacDocTextContainer {
        let container = MacDocTextContainer()
        let textView = container.textView
        textView.delegate = context.coordinator
        context.coordinator.attach(textView: textView, in: container)
        container.onMovedToWindow = { [weak textView] in
            textView?.window?.makeFirstResponder(textView)
        }
        return container
    }

    func updateNSView(_ container: MacDocTextContainer, context: Context) {
        context.coordinator.element = element
        context.coordinator.page = page
        context.coordinator.pageDisplayHeight = pageDisplayHeight
        context.coordinator.richTextController = richTextController
        container.applyWidth(max(1, columnWidth))
        // Restore caret when SwiftUI re-lays out the field but nothing
        // else owns first responder (e.g. after header reflow).
        DispatchQueue.main.async {
            guard let window = container.window, window.isKeyWindow else { return }
            if window.firstResponder == nil {
                window.makeFirstResponder(container.textView)
            }
        }
    }

    static func dismantleNSView(_ container: MacDocTextContainer, coordinator: Coordinator) {
        coordinator.flushSave()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var element: PageElement
        let notebook: Notebook
        var page: Page
        let modelContext: ModelContext
        var pageDisplayHeight: CGFloat
        var richTextController: MacRichTextController
        let onWritingBegan: () -> Void
        let onEndEdit: () -> Void
        private var saveTask: Task<Void, Never>?
        private weak var textView: NSTextView?
        private weak var container: MacDocTextContainer?
        private let slash = MacDocSlashCommandHandler()

        init(
            element: PageElement,
            notebook: Notebook,
            page: Page,
            modelContext: ModelContext,
            pageDisplayHeight: CGFloat,
            richTextController: MacRichTextController,
            onWritingBegan: @escaping () -> Void,
            onEndEdit: @escaping () -> Void
        ) {
            self.element = element
            self.notebook = notebook
            self.page = page
            self.modelContext = modelContext
            self.pageDisplayHeight = pageDisplayHeight
            self.richTextController = richTextController
            self.onWritingBegan = onWritingBegan
            self.onEndEdit = onEndEdit
        }

        func attach(textView: NSTextView, in container: MacDocTextContainer) {
            self.textView = textView
            self.container = container
            slash.textView = textView
            MacDictationTrigger.register(textView)
            guard let content = element.textContent else { return }
            let decoded = MacRichTextCodec.decode(from: content)
            if textView.attributedString() != decoded {
                textView.textStorage?.setAttributedString(decoded)
            }
            textView.typingAttributes = MacRichTextCodec.defaultTypingAttributes(size: content.size)
            richTextController.attach(textView)
            container.growToFit()
            focusTextView(atClickY: MacPendingTextCursor.take(elementId: element.id), in: textView)
        }

        private func focusTextView(atClickY clickY: CGFloat?, in textView: NSTextView) {
            textView.window?.makeFirstResponder(textView)
            guard let clickY else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                return
            }
            let point = NSPoint(
                x: textView.textContainerInset.width + 8,
                y: clickY + textView.textContainerInset.height
            )
            let index = textView.characterIndexForInsertion(at: point)
            let clamped = min(max(0, index), (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
            textView.scrollRangeToVisible(NSRange(location: clamped, length: 0))
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            onWritingBegan()
            richTextController.refresh()
            scheduleSave(from: tv)
            container?.growToFit(maxHeight: remainingPageHeightPixels())
            syncLayout(from: tv)
            slash.handleTextChange(in: tv)
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            MacDictationTrigger.register(tv)
            MacStateUpdates.deferred { [weak self] in
                self?.richTextController.attach(tv)
            }
            onWritingBegan()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            MacStateUpdates.deferred { [weak self] in
                self?.richTextController.refresh()
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            flushSave(from: tv)
            syncLayout(from: tv, commit: true)
            if let content = element.textContent {
                let originY = element.normalizedY * page.pageSize.pointSize.height
                _ = MacTextElementSplitter.splitIfNeeded(
                    element: element,
                    content: content,
                    pageSize: page.pageSize.pointSize,
                    originY: originY
                )
            }
            slash.dismiss()
            MacStateUpdates.deferred { [onEndEdit] in onEndEdit() }
        }

        func flushSave() {
            saveTask?.cancel()
            if let tv = textView { flushSave(from: tv) }
        }

        private func scheduleSave(from textView: NSTextView) {
            saveTask?.cancel()
            let snapshot = NSAttributedString(attributedString: textView.attributedString())
            saveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                persist(snapshot)
            }
        }

        private func flushSave(from textView: NSTextView) {
            saveTask?.cancel()
            let snapshot = NSAttributedString(attributedString: textView.attributedString())
            persist(snapshot)
        }

        private func persist(_ attributed: NSAttributedString) {
            MacElementEditing.updateTextContent(
                element,
                plain: attributed.string,
                attributedData: MacRichTextCodec.encode(attributed),
                context: modelContext
            )
        }

        private func syncLayout(from textView: NSTextView, commit: Bool = false) {
            guard pageDisplayHeight > 0 else { return }
            let pixelHeight = container?.bounds.height ?? textView.frame.height
            let pagePoints = page.pageSize.pointSize.height
            let scale = pageDisplayHeight / max(1, pagePoints)
            let layoutPoints = pixelHeight / max(0.01, scale)
            let normalizedMaxY = element.normalizedY + Double(layoutPoints / pagePoints)

            if commit {
                let normH = min(0.92, max(0.06, Double(layoutPoints / pagePoints)))
                if abs(element.normalizedHeight - normH) > 0.005 {
                    element.normalizedHeight = normH
                    let pageWidth = page.pageSize.pointSize.width
                    element.normalizedX = MacDocPageLayout.normalizedHorizontalMargin(pageWidth: pageWidth)
                    element.normalizedWidth = MacDocPageLayout.normalizedContentWidth(pageWidth: pageWidth)
                    element.updatedAt = Date()
                    try? modelContext.save()
                }
            }

            MacPageAutoAdd.considerAfterTextGrowth(
                notebook: notebook,
                page: page,
                normalizedMaxY: normalizedMaxY,
                storage: StorageService.shared
            )
        }

        private func remainingPageHeightPixels() -> CGFloat {
            let pagePoints = page.pageSize.pointSize.height
            let scale = pageDisplayHeight / max(1, pagePoints)
            let originPixels = element.normalizedY * pageDisplayHeight
            return max(24, pageDisplayHeight - originPixels - 6)
        }
    }
}

@MainActor
final class MacDocSlashCommandHandler {
    weak var textView: NSTextView?
    private var slashPopover: NSPopover?
    private var slashOriginIndex: Int?

    func dismiss() {
        slashPopover?.performClose(nil)
        slashPopover = nil
        slashOriginIndex = nil
    }

    func handleTextChange(in tv: NSTextView) {
        let str = tv.string as NSString
        let selected = tv.selectedRange()

        if let origin = slashOriginIndex {
            let outOfBounds = origin >= str.length
            let caretMoved = selected.location < origin || selected.location > origin + 32
            let sigilGone = !outOfBounds && str.character(at: origin) != 47
            if outOfBounds || caretMoved || sigilGone { dismiss() }
        }

        guard selected.length == 0, selected.location > 0 else { return }
        let idx = selected.location - 1
        guard idx < str.length, str.character(at: idx) == 47 else { return }
        let atLineStart = idx == 0 || str.character(at: idx - 1) == 10
        guard atLineStart else { return }
        if slashOriginIndex == idx, slashPopover?.isShown == true { return }
        presentSlashPopover(at: idx, in: tv)
    }

    private func presentSlashPopover(at charIndex: Int, in tv: NSTextView) {
        dismiss()
        let range = NSRange(location: charIndex, length: 1)
        let screenRect = tv.firstRect(forCharacterRange: range, actualRange: nil)
        guard let window = tv.window else { return }
        let windowRect = window.convertFromScreen(screenRect)
        let anchor = tv.convert(windowRect, from: nil)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 300, height: 210)
        let menu = MacDocSlashMenu(
            onCommand: { [weak self] command in
                self?.handleSlashCommand(command)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )
        popover.contentViewController = NSHostingController(
            rootView: menu.environment(\.theme, ThemeManager.shared.current)
        )
        popover.show(relativeTo: anchor, of: tv, preferredEdge: .maxY)
        slashPopover = popover
        slashOriginIndex = charIndex
    }

    private func handleSlashCommand(_ command: MacDocSlashMenu.Command) {
        guard let tv = textView, let origin = slashOriginIndex else { return }
        tv.textStorage?.deleteCharacters(in: NSRange(location: origin, length: 1))
        tv.setSelectedRange(NSRange(location: origin, length: 0))
        dismiss()
        switch command {
        case .summarize:
            NotificationCenter.default.post(name: .macSummarizePage, object: nil)
        case .ask:
            NotificationCenter.default.post(name: .macAskAboutPage, object: nil)
        case .rewrite, .continueWriting:
            runInlineAI(command: command, textView: tv, at: origin)
        }
    }

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
        let placeholderRange = NSRange(location: charIndex, length: 0)
        let placeholderAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .light),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let placeholder = NSAttributedString(string: " …", attributes: placeholderAttrs)
        tv.textStorage?.insert(placeholder, at: charIndex)
        let placeholderSpan = NSRange(location: charIndex, length: placeholder.length)
        #if canImport(FoundationModels)
        let provider = AppleFoundationProvider()
        Task { [weak tv] in
            do {
                let result = try await provider.complete(
                    systemPrompt: system,
                    userPrompt: user,
                    maxTokens: 260,
                    temperature: 0.4
                )
                await MainActor.run {
                    guard let tv else { return }
                    if placeholderSpan.location + placeholderSpan.length <= (tv.string as NSString).length {
                        tv.textStorage?.deleteCharacters(in: placeholderSpan)
                    }
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 15),
                        .foregroundColor: NSColor.labelColor,
                    ]
                    let attributed = NSAttributedString(string: result, attributes: attributes)
                    switch command {
                    case .rewrite:
                        tv.textStorage?.replaceCharacters(in: paragraphRange, with: attributed)
                    case .continueWriting:
                        let prefix = result.hasPrefix(" ") ? "" : " "
                        let combined = NSAttributedString(string: prefix + result, attributes: attributes)
                        tv.textStorage?.insert(combined, at: charIndex)
                    default:
                        break
                    }
                }
            } catch {
                await MainActor.run {
                    guard let tv else { return }
                    if placeholderSpan.location + placeholderSpan.length <= (tv.string as NSString).length {
                        tv.textStorage?.deleteCharacters(in: placeholderSpan)
                    }
                }
                #if DEBUG
                print("[slash] AI command failed: \(error)")
                #endif
            }
        }
        #endif
    }
}

enum MacRichTextCodec {
    /// Note text carries the shared editorial voice (`NoteTypography`):
    /// one page-space body size across every platform, airy leading,
    /// real paragraph spacing, and role-matched tracking — bare
    /// `systemFont` with default leading is what made typed and
    /// dictated notes read like a 2005 text field against the rest
    /// of the design.
    static func defaultTypingAttributes(size: TextSize = .body) -> [NSAttributedString.Key: Any] {
        let font: NSFont
        switch size {
        case .heading: font = NoteTypography.headingFont
        case .small:   font = NoteTypography.smallFont
        default:       font = NoteTypography.bodyFont
        }
        return [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: NoteTypography.paragraphStyle(
                isHeading: size == .heading,
                pointSize: font.pointSize
            ),
            .kern: NoteTypography.kern(forPointSize: font.pointSize),
        ]
    }

    static func decode(from content: TextContent) -> NSAttributedString {
        if let data = content.attributedTextData, !data.isEmpty,
           let attr = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) {
            return attr
        }
        return NSAttributedString(
            string: content.text,
            attributes: defaultTypingAttributes(size: content.size)
        )
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
