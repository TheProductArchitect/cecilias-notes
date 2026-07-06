import AppKit
import SwiftData
import SwiftUI

/// Tracks the active inline `NSTextView` for the floating format bar.
@MainActor
final class MacTextEditingController: ObservableObject {
    weak var activeTextView: NSTextView?
    @Published var toolbarOffset: CGSize = .zero

    func attach(_ textView: NSTextView) {
        activeTextView = textView
        MacDictationTrigger.register(textView)
    }

    func detach() {
        activeTextView = nil
    }

    func focusActiveTextView() {
        guard let textView = activeTextView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}

// MARK: - Inline editor

struct MacInlineTextEditor: NSViewRepresentable {
    @Bindable var element: PageElement
    let width: CGFloat
    let height: CGFloat
    let pagePixelHeight: CGFloat
    @ObservedObject var editingController: MacTextEditingController
    let modelContext: ModelContext

    func makeCoordinator() -> Coordinator {
        Coordinator(
            element: element,
            pagePixelHeight: pagePixelHeight,
            editingController: editingController,
            modelContext: modelContext
        )
    }

    func makeNSView(context: Context) -> MacInlineTextContainer {
        let container = MacInlineTextContainer()
        let textView = container.textView
        textView.delegate = context.coordinator
        context.coordinator.configure(textView: textView, width: width, height: height)
        editingController.attach(textView)
        MacDictationTrigger.register(textView)
        container.onMovedToWindow = { [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
        return container
    }

    func updateNSView(_ container: MacInlineTextContainer, context: Context) {
        context.coordinator.element = element
        let textView = container.textView
        let target = NSSize(width: width, height: max(28, height))
        if container.frame.size != target {
            container.frame.size = target
        }
        if textView.frame.size != target {
            textView.frame = NSRect(origin: .zero, size: target)
            textView.textContainer?.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        editingController.attach(textView)
        if textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    static func dismantleNSView(_ nsView: MacInlineTextContainer, coordinator: Coordinator) {
        coordinator.flushSave()
        coordinator.editingController.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var element: PageElement
        let pagePixelHeight: CGFloat
        let editingController: MacTextEditingController
        let modelContext: ModelContext
        private var saveTask: Task<Void, Never>?
        private weak var textView: NSTextView?

        init(
            element: PageElement,
            pagePixelHeight: CGFloat,
            editingController: MacTextEditingController,
            modelContext: ModelContext
        ) {
            self.element = element
            self.pagePixelHeight = pagePixelHeight
            self.editingController = editingController
            self.modelContext = modelContext
        }

        func configure(textView: NSTextView, width: CGFloat, height: CGFloat) {
            self.textView = textView
            MacDictationTrigger.register(textView)
            guard let content = element.textContent else { return }
            let decoded = MacRichTextCodec.decode(from: content)
            if textView.attributedString() != decoded {
                textView.textStorage?.setAttributedString(decoded)
            }
            textView.typingAttributes = MacRichTextCodec.defaultTypingAttributes(
                size: content.size
            )
            let h = max(28, height)
            textView.frame = NSRect(x: 0, y: 0, width: width, height: h)
            textView.textContainer?.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            scheduleSave(from: tv)
            growToFit(tv)
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            MacDictationTrigger.register(tv)
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
                persist(snapshot, textView: textView)
            }
        }

        private func flushSave(from textView: NSTextView) {
            saveTask?.cancel()
            let snapshot = NSAttributedString(attributedString: textView.attributedString())
            persist(snapshot, textView: textView)
        }

        private func persist(_ attributed: NSAttributedString, textView: NSTextView) {
            let data = MacRichTextCodec.encode(attributed)
            MacElementEditing.updateTextContent(
                element,
                plain: attributed.string,
                attributedData: data,
                context: modelContext
            )
            growToFit(textView, commit: true)
        }

        private func growToFit(_ textView: NSTextView, commit: Bool = false) {
            guard let container = textView.textContainer,
                  let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let needed = max(28, ceil(used.height) + textView.textContainerInset.height * 2 + 4)
            if abs(textView.frame.height - needed) > 1 {
                textView.frame.size.height = needed
                textView.superview?.frame.size.height = needed
                textView.superview?.needsLayout = true
            }
            guard commit, pagePixelHeight > 0 else { return }
            let normH = min(0.92, max(0.06, Double(needed / pagePixelHeight)))
            if abs(element.normalizedHeight - normH) > 0.005 {
                element.normalizedHeight = normH
                element.updatedAt = Date()
                try? modelContext.save()
            }
        }
    }
}

/// Fixed-size host for an inline `NSTextView` on the page canvas.
final class MacInlineTextContainer: NSView {
    let textView: NSTextView
    var onMovedToWindow: (() -> Void)?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(1, frame.width), height: max(28, frame.height))
    }

    override init(frame frameRect: NSRect) {
        textView = NSTextView(frame: frameRect)
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
        textView.insertionPointColor = NSColor.labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = MacRichTextCodec.defaultTypingAttributes()
        textView.autoresizingMask = [.width, .height]
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onMovedToWindow?()
        }
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let local = convert(point, to: textView)
        return textView.hitTest(local) ?? textView
    }
}

// MARK: - Floating toolbar (movable, iPad-like)

struct MacFloatingTextToolbar: View {
    @ObservedObject var controller: MacTextEditingController
    @Environment(\.theme) private var theme
    @State private var dragOrigin: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.recessiveTertiary)
                Text("text")
                    .font(.system(size: 8, weight: .regular))
                    .tracking(0.12)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.recessiveTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        controller.toolbarOffset = CGSize(
                            width: dragOrigin.width + value.translation.width,
                            height: dragOrigin.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        dragOrigin = controller.toolbarOffset
                    }
            )

            Rectangle().fill(theme.hairline).frame(height: 0.5)

            MacRichTextFormatBar(textView: controller.activeTextView)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: 520)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.hairline, lineWidth: 0.5)
        }
        .offset(controller.toolbarOffset)
        .onAppear { dragOrigin = controller.toolbarOffset }
    }
}
