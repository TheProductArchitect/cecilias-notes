import AppKit
import PDFKit
import PencilKit
import SwiftData
import SwiftUI

/// Renders one `PageElement` as an inline document block. Text and sticky
/// notes are editable; everything else is read-only with an "iPad" eyebrow
/// where relevant.
struct MacDocBlock: View {
    @Bindable var element: PageElement
    let page: Page
    let notebook: Notebook
    var isEditing: Bool
    var isSelected: Bool
    var onBeginEdit: () -> Void
    var onEndEdit: () -> Void
    var onSelect: () -> Void = {}
    var onWritingBegan: () -> Void = {}
    var pageDisplayHeight: CGFloat = 792
    var stackTopOffset: CGFloat = 40
    var maxBlockHeight: CGFloat = 600

    @Environment(\.theme) private var theme
    @EnvironmentObject private var storage: StorageService

    var body: some View {
        Group {
            switch element.kind {
            case .text:       textBlock
            case .stickyNote: stickyBlock
            case .image:      imageBlock
            case .stroke:     inlineStrokeBlock
            case .shape:      shapeBlock
            case .pdfPage:    pdfBlock
            case .audio:      audioBlock
            case .highlight:  highlightBlock
            }
        }
        .overlay(alignment: .leading) {
            if isSelected && !isEditing && element.kind != .text {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.accent.opacity(0.6))
                    .frame(width: 2)
            }
        }
        .overlay {
            if isSelected && !isEditing && element.kind != .text {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(theme.accent.opacity(0.55), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { blockContextMenu }
    }

    // MARK: - Text (click to edit — growing field, no inner scroll)

    private var textBlock: some View {
        MacDocTextBlock(
            element: element,
            notebook: notebook,
            page: page,
            pageDisplayHeight: pageDisplayHeight,
            stackTopOffset: stackTopOffset,
            maxBlockHeight: maxBlockHeight,
            isEditing: isEditing,
            isSelected: isSelected,
            onSelect: onSelect,
            onBeginEdit: onBeginEdit,
            onEndEdit: onEndEdit,
            onWritingBegan: onWritingBegan
        )
    }

    // MARK: - Sticky note (editable, tinted background)

    private var stickyBlock: some View {
        let tint = stickyTint(element.stickyNoteContent?.colorVariant ?? "yellow")
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 2)
            MacDocStickyEditor(
                element: element,
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onEndEdit: onEndEdit
            )
        }
        .padding(12)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing { return }
            if isSelected { onBeginEdit() } else { onSelect() }
        }
    }

    // MARK: - Image (inline with crop + imageData)

    @State private var isCroppingImage = false

    private var imageBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let content = element.imageContent, let image = docImage(for: content) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 480, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contextMenu {
                        Button("Crop Image…") { isCroppingImage = true }
                    }
            } else {
                fallback("image unavailable", icon: "photo")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isEditing { onSelect() } }
        .sheet(isPresented: $isCroppingImage) {
            if let content = element.imageContent {
                MacImageCropSheet(
                    content: content,
                    onDone: { isCroppingImage = false },
                    onCancel: { isCroppingImage = false }
                )
                .environmentObject(storage)
            }
        }
    }

    private func docImage(for content: ImageContent) -> NSImage? {
        let url = MediaStorage.url(for: .images, id: content.id, fileExtension: content.fileFormat)
        guard let raw = content.imageData.flatMap({ PlatformImageFactory.from(data: $0) })
                ?? NSImage(contentsOf: url) else { return nil }
        return MacImageCropMath.applyCrop(to: raw, content: content)
    }

    // MARK: - Ink / shapes (read-only inline)

    private var inlineStrokeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("handwriting from iPad")
            if let image = strokePreviewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
            } else {
                inkPlaceholder
            }
        }
    }

    private var shapeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let content = element.shapeContent {
                let aspect = max(0.25, element.normalizedWidth / max(0.1, element.normalizedHeight))
                let width = min(520, 720 * element.normalizedWidth)
                MacDocShapePreview(content: content)
                    .frame(width: width, height: width / aspect)
            } else {
                inkPlaceholder
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var strokePreviewImage: NSImage? {
        guard let data = element.strokeContent?.strokeData,
              !data.isEmpty,
              let drawing = try? PKDrawing(data: data),
              !drawing.bounds.isEmpty else { return nil }
        return drawing.image(from: drawing.bounds, scale: 2)
    }

    private var inkPlaceholder: some View {
        HStack {
            Image(systemName: "pencil.tip")
                .font(.system(size: 12))
                .foregroundStyle(theme.recessiveTertiary)
            Text("edit on iPad")
                .font(.system(size: 11).italic())
                .foregroundStyle(theme.foregroundSubtle)
            Spacer()
            Button("open on iPad") { publishHandoff() }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.surface.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.hairline, lineWidth: 0.5))
    }

    // MARK: - PDF page (inline thumbnail)

    private var pdfBlock: some View {
        MacDocPDFBlock(element: element)
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
    }

    // MARK: - Audio (play + transcript)

    private var audioBlock: some View {
        MacDocAudioBlock(element: element)
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
    }

    // MARK: - Highlight

    private var highlightBlock: some View {
        Text(element.highlightContent?.capturedText ?? "highlighted region")
            .font(.system(size: 14))
            .padding(.horizontal, 4)
            .background(Color.yellow.opacity(0.25))
    }

    // MARK: - Chrome helpers

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.12)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveTertiary)
    }

    private func fallback(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(theme.recessiveTertiary)
            Text(text)
                .font(.system(size: 12).italic())
                .foregroundStyle(theme.recessiveTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var blockContextMenu: some View {
        Button("Delete Block", role: .destructive) {
            MacElementEditing.softDelete(element, context: storage.context)
        }
        if element.kind == .text || element.kind == .stickyNote {
            Button("Ask AI about this") {
                NotificationCenter.default.post(
                    name: .macAskAIAboutElement,
                    object: nil,
                    userInfo: ["elementId": element.id]
                )
            }
        }
    }

    private func stickyTint(_ variant: String) -> Color {
        switch variant.lowercased() {
        case "pink":   return Color(red: 0.98, green: 0.72, blue: 0.75)
        case "blue":   return Color(red: 0.68, green: 0.80, blue: 0.95)
        case "green":  return Color(red: 0.72, green: 0.87, blue: 0.72)
        case "orange": return Color(red: 0.98, green: 0.78, blue: 0.55)
        default:       return Color(red: 0.98, green: 0.91, blue: 0.55)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func publishHandoff() {
        NotificationCenter.default.post(
            name: .macRequestHandoffToIPad,
            object: nil,
            userInfo: [
                MacHandoff.notebookIdKey: notebook.id,
                MacHandoff.pageIdKey: page.id,
            ]
        )
    }
}

// MARK: - Doc-mode audio player

private struct MacDocAudioBlock: View {
    let element: PageElement
    @StateObject private var player = MacAudioPlayer()
    @ObservedObject private var session = MacRecordingSession.shared
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storage: StorageService

    private var isRecordingThis: Bool {
        guard case .voiceMemo(let ctx) = session.mode else { return false }
        return ctx.audioElementId == element.id
    }

    var body: some View {
        if let content = element.audioContent {
            Group {
                if isRecordingThis {
                    recordingRow
                } else {
                    playbackRow(content: content)
                }
            }
            .padding(.vertical, 4)
            .onAppear { player.load(content: content) }
            .onDisappear { player.pause() }
            .onChange(of: content.durationSeconds) { _, _ in
                player.reload(content: content)
            }
        }
    }

    private var recordingRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red.opacity(0.9))
                .frame(width: 6, height: 6)
            Text(format(session.elapsedSeconds))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.foregroundMuted)
            Spacer(minLength: 0)
            Button {
                Task { await session.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.surfaceElevated))
                    .overlay(Circle().stroke(theme.hairline, lineWidth: 0.5))
            }
            .macEditorChromeButton()
            .accessibilityLabel("Stop recording")
        }
    }

    private func playbackRow(content: AudioContent) -> some View {
        HStack(spacing: 10) {
            Button {
                player.toggle(content: content)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.accentMuted.opacity(0.35)))
            }
            .macEditorChromeButton()
            .accessibilityLabel(player.isPlaying ? "Pause audio" : "Play audio")

            Text("\(format(player.currentTime)) / \(format(player.duration > 0 ? player.duration : content.durationSeconds))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.recessiveTertiary)

            progressTrack(content: content)
        }
        .accessibilityLabel("Audio recording, \(format(content.durationSeconds))")
    }

    @ViewBuilder
    private func progressTrack(content: AudioContent) -> some View {
        GeometryReader { geo in
            let total = player.duration > 0 ? player.duration : max(content.durationSeconds, 0.01)
            let active = player.scrubPreview ?? player.currentTime
            let fraction = min(1, max(0, active / total))
            ZStack(alignment: .leading) {
                Capsule().fill(theme.hairline).frame(height: 2)
                Capsule()
                    .fill(theme.accent.opacity(0.7))
                    .frame(width: max(0, geo.size.width * fraction), height: 2)
            }
            .frame(height: 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let f = min(1, max(0, value.location.x / geo.size.width))
                        player.scrubPreview = f * total
                    }
                    .onEnded { _ in
                        if let target = player.scrubPreview {
                            player.seek(to: target)
                        }
                        player.scrubPreview = nil
                    }
            )
        }
        .frame(height: 12)
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Click-to-edit text block

private struct MacDocTextBlock: View {
    @Bindable var element: PageElement
    let notebook: Notebook
    let page: Page
    let pageDisplayHeight: CGFloat
    let stackTopOffset: CGFloat
    let maxBlockHeight: CGFloat
    let isEditing: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onEndEdit: () -> Void
    var onWritingBegan: () -> Void = {}
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storage: StorageService
    @EnvironmentObject private var richTextController: MacRichTextController
    @ObservedObject private var session = MacRecordingSession.shared
    @State private var columnWidth: CGFloat = 576

    private var isLiveTarget: Bool {
        session.mode.isTranscribing && session.mode.textElementId == element.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLiveTarget {
                MacDocInlineRecordingChrome(elapsed: session.elapsedSeconds)
            }

            Group {
                if isEditing {
                    MacDocGrowingRichTextEditor(
                        element: element,
                        notebook: notebook,
                        page: page,
                        modelContext: storage.context,
                        columnWidth: columnWidth,
                        pageDisplayHeight: pageDisplayHeight,
                        stackTopOffset: stackTopOffset,
                        maxBlockHeight: maxBlockHeight,
                        richTextController: richTextController,
                        onWritingBegan: onWritingBegan,
                        onEndEdit: onEndEdit
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    MacDocTextPreview(element: element, maxHeight: maxBlockHeight)
                        .overlay {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(count: 1, coordinateSpace: .local) { location in
                                    MacPendingTextCursor.set(elementId: element.id, clickYInBlock: location.y)
                                    onWritingBegan()
                                    onSelect()
                                    onBeginEdit()
                                }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { columnWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in
                        if width > 1 { columnWidth = width }
                    }
            }
        )
        .accessibilityLabel(isEditing ? "Editing text" : "Text block")
    }
}

/// Minimal in-page recording controls — no duplicate header banner.
private struct MacDocInlineRecordingChrome: View {
    let elapsed: Double
    @Environment(\.theme) private var theme
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red.opacity(0.9))
                .frame(width: 6, height: 6)
                .scaleEffect(pulsing ? 1.2 : 0.9)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }

            Text(format(elapsed))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.recessiveTertiary)

            Text("listening")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.08)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveQuaternary)

            Spacer(minLength: 0)

            Button {
                Task { await MacRecordingSession.shared.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(theme.surfaceElevated))
                    .overlay(Circle().stroke(theme.hairline, lineWidth: 0.5))
            }
            .macEditorChromeButton()
            .accessibilityLabel("Stop transcription")
        }
        .padding(.bottom, 2)
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct MacDocTextPreview: View {
    @Bindable var element: PageElement
    var maxHeight: CGFloat?
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let content = element.textContent {
                let attributed = MacRichTextCodec.decode(from: content)
                if attributed.length > 0 {
                    // AppKit-backed: SwiftUI `Text(AttributedString(ns))`
                    // drops / remaps NSFont traits on macOS, so bold /
                    // italic / size changes looked correct while editing
                    // (NSTextView) then vanished in preview.
                    MacAttributedTextPreview(attributed: attributed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !content.text.isEmpty {
                    Text(content.text)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(" ")
                        .font(.system(size: 14))
                        .foregroundStyle(.clear)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
                        .accessibilityHidden(true)
                }
            } else {
                Text(" ")
                    .font(.system(size: 14))
                    .foregroundStyle(.clear)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxHeight: maxHeight, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// Read-only AppKit text that preserves the same attributed string
/// the editor writes — used for the non-editing preview of a block.
private struct MacAttributedTextPreview: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> MacPreviewTextView {
        let view = MacPreviewTextView(frame: .zero)
        view.setAttributed(attributed)
        return view
    }

    func updateNSView(_ view: MacPreviewTextView, context: Context) {
        view.setAttributed(attributed)
    }
}

/// Non-editable, non-scrolling text view that reports intrinsic height
/// from its text layout — mirrors the growing editor's metrics so
/// preview and edit modes don't jump.
private final class MacPreviewTextView: NSView {
    private let textView = NSTextView(frame: .zero)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setAttributed(_ attributed: NSAttributedString) {
        if textView.attributedString() != attributed {
            textView.textStorage?.setAttributedString(attributed)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        textView.textContainer?.containerSize = NSSize(
            width: max(1, width),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        let height = max(20, ceil(used.height))
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 1 ? bounds.width : 576
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        return NSSize(width: NSView.noIntrinsicMetric, height: max(20, ceil(used.height)))
    }
}

private struct MacDocStickyEditor: View {
    @Bindable var element: PageElement
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onEndEdit: () -> Void
    @EnvironmentObject private var storage: StorageService
    @State private var text: String = ""

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $text)
                    .font(.system(size: 14).italic())
                    .frame(minHeight: 28)
                    .scrollContentBackground(.hidden)
                    .onAppear { text = element.stickyNoteContent?.text ?? "" }
                    .onChange(of: text) { _, new in
                        element.stickyNoteContent?.text = new
                        element.updatedAt = Date()
                        try? storage.context.save()
                        NotebookOriginRecorder.markNotebookModified(
                            notebookId: element.notebookId,
                            context: storage.context
                        )
                    }
                    .onDisappear { onEndEdit() }
            } else if let note = element.stickyNoteContent?.text, !note.isEmpty {
                Text(note)
                    .font(.system(size: 14).italic())
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(" ")
                    .font(.system(size: 14))
                    .foregroundStyle(.clear)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
            }
        }
    }
}

extension Notification.Name {
    static let macAskAIAboutElement = Notification.Name("app.ceciliasnotes.mac.askAI")
    static let macRequestHandoffToIPad = Notification.Name("app.ceciliasnotes.mac.handoffToIPad")
    static let macStartDictation = Notification.Name("app.ceciliasnotes.mac.startDictation")
}

private struct MacDocPDFBlock: View {
    let element: PageElement
    @Environment(\.theme) private var theme
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if failed {
                    Text("pdf unavailable")
                        .font(.system(size: 12).italic())
                        .foregroundStyle(theme.recessiveTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .task(id: element.id) { await loadPDF() }
    }

    private func loadPDF() async {
        guard let content = element.pdfPageContent else {
            await MainActor.run { failed = true }
            return
        }
        if let previewURL = content.previewImageURL,
           let preview = NSImage(contentsOf: previewURL) {
            await MainActor.run { image = preview }
        }
        let url = content.pdfFileURL
        let pageIndex = content.pageIndex
        let rendered = await MacPDFRenderer.renderPage(url: url, pageIndex: pageIndex, scale: 2)
        await MainActor.run {
            if let rendered { image = rendered }
            else if image == nil { failed = true }
        }
    }
}

private struct MacDocShapePreview: View {
    let content: ShapeContent

    var body: some View {
        GeometryReader { geo in
            let path = ShapeKindPath.path(for: content.shapeKind, in: CGRect(origin: .zero, size: geo.size))
            let strokeColor = MacElementPalette.color(fromHex: content.strokeColorHex)
            let fillColor = content.fillColorHex.map {
                MacElementPalette.color(fromHex: $0).opacity(content.fillOpacity)
            }
            ZStack {
                path.fill(fillColor ?? .clear)
                path.stroke(strokeColor, style: strokeStyle)
                if let label = content.containedText, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
    }

    private var strokeStyle: StrokeStyle {
        let width = max(1, content.strokeWidth)
        switch content.strokeStyle {
        case .dashed: return StrokeStyle(lineWidth: width, dash: [6, 4])
        case .dotted: return StrokeStyle(lineWidth: width, dash: [2, 3])
        case .none:   return StrokeStyle(lineWidth: 0)
        default:      return StrokeStyle(lineWidth: width)
        }
    }
}
