import AVFoundation
import PDFKit
import PencilKit
import SwiftData
import SwiftUI

enum MacElementPalette {
    static func stickyColor(_ variant: String) -> Color {
        switch variant {
        case "pink":  return Color(red: 1.00, green: 0.75, blue: 0.85)
        case "blue":  return Color(red: 0.70, green: 0.85, blue: 1.00)
        case "green": return Color(red: 0.75, green: 0.95, blue: 0.70)
        default:      return Color(red: 1.00, green: 0.92, blue: 0.50)
        }
    }

    static func highlightColor(_ variant: String) -> Color {
        switch variant {
        case "pink":  return Color(red: 1.00, green: 0.70, blue: 0.85)
        case "blue":  return Color(red: 0.70, green: 0.85, blue: 1.00)
        case "green": return Color(red: 0.75, green: 0.95, blue: 0.70)
        default:      return Color(red: 1.00, green: 0.95, blue: 0.40)
        }
    }

    static func color(fromHex hex: String) -> Color {
        Color(hex: hex.isEmpty ? "#333333" : hex)
    }
}

struct MacElementView: View {
    @Bindable var element: PageElement
    let pageSize: CGSize
    let pdfParents: [UUID: PageElement]
    var isSelected: Bool = false
    var isEditingText: Bool = false
    var editingTextController: MacTextEditingController?
    var onSelect: ((UUID) -> Void)?
    var onEditText: ((PageElement) -> Void)?
    var onEndTextEditing: (() -> Void)?
    var onEditSticky: ((PageElement) -> Void)?
    @EnvironmentObject private var storageService: StorageService

    private var frame: CGRect {
        CGRect(
            x: element.normalizedX * pageSize.width,
            y: element.normalizedY * pageSize.height,
            width: max(1, element.normalizedWidth * pageSize.width),
            height: max(1, element.normalizedHeight * pageSize.height)
        )
    }

    var body: some View {
        if element.kind == .highlight,
           let content = element.highlightContent,
           let parent = pdfParents[content.pdfPageContentId] {
            MacHighlightView(content: content, parent: parent, pageSize: pageSize)
        } else {
            elementBody
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .macElementTransform(
                    element: element,
                    pageSize: pageSize,
                    isSelected: isSelected && !isEditingText,
                    context: storageService.context
                )
                .rotationEffect(.radians(element.rotation))
                .overlay {
                    if showsSelectionChrome {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.accentColor, lineWidth: 2)
                    }
                }
                .offset(x: frame.minX, y: frame.minY)
                .zIndex(isEditingText ? 100 : Double(element.zIndex))
                .onTapGesture {
                    guard !isEditingText else { return }
                    onSelect?(element.id)
                    if element.kind == .text {
                        onEditText?(element)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(elementAccessibilityLabel)
                .accessibilityAddTraits(isEditingText ? [] : .isButton)
        }
    }

    /// Text blocks stay chrome-free (Google Docs–style). Other elements keep a
    /// selection outline when selected but not being edited.
    private var showsSelectionChrome: Bool {
        guard isSelected, !isEditingText else { return false }
        return element.kind != .text
    }

    private var elementAccessibilityLabel: String {
        switch element.kind {
        case .text:
            let t = element.textContent?.text ?? ""
            return t.isEmpty ? "Text box" : "Text, \(t.prefix(80))"
        case .image:
            return A11y.mediaLabel(caption: nil)
        case .stickyNote:
            return "Sticky note, \(element.stickyNoteContent?.text.prefix(60) ?? "")"
        case .audio:
            let d = element.audioContent?.durationSeconds ?? 0
            let hasT = !(element.audioContent?.transcript.isEmpty ?? true)
            return A11y.audioLabel(duration: d, hasTranscription: hasT)
        case .shape:
            return "Shape, \(element.shapeContent?.shapeKind.rawValue ?? "figure")"
        case .pdfPage:
            return "PDF page"
        default:
            return "Page element"
        }
    }

    @ViewBuilder
    private var elementBody: some View {
        Group {
            switch element.kind {
            case .text:
                MacTextElementView(
                    element: element,
                    frame: frame,
                    pagePixelHeight: pageSize.height,
                    isSelected: isSelected,
                    isEditing: isEditingText,
                    editingController: editingTextController,
                    onBeginEdit: { onEditText?(element) }
                )
            case .image:
                MacImageElementView(
                    element: element,
                    frame: frame,
                    isSelected: isSelected
                )
            case .stickyNote:
                MacStickyNoteView(element: element, frame: frame, onEdit: {
                    onEditSticky?(element)
                })
            case .pdfPage:
                MacPDFElementView(element: element, frame: frame)
            case .shape:
                MacShapeElementView(element: element, frame: frame)
            case .audio:
                MacAudioElementView(element: element, frame: frame)
            case .stroke, .highlight:
                EmptyView()
            }
        }
    }
}

private struct MacTextElementView: View {
    @Bindable var element: PageElement
    let frame: CGRect
    let pagePixelHeight: CGFloat
    let isSelected: Bool
    let isEditing: Bool
    var editingController: MacTextEditingController?
    let onBeginEdit: () -> Void
    @EnvironmentObject private var storageService: StorageService

    var body: some View {
        Group {
            if isEditing, let controller = editingController {
                MacInlineTextEditor(
                    element: element,
                    width: frame.width,
                    height: max(28, frame.height),
                    pagePixelHeight: pagePixelHeight,
                    editingController: controller,
                    modelContext: storageService.context
                )
                .frame(width: frame.width, height: max(28, frame.height), alignment: .topLeading)
            } else if let content = element.textContent {
                if let attr = attributedContent(content) {
                    Text(attr)
                        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                } else if !content.text.isEmpty {
                    Text(content.text)
                        .font(textFont(content.size))
                        .foregroundStyle(.primary)
                        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing { onBeginEdit() }
        }
        .accessibilityHint(isEditing ? "Editing text" : "Click to edit text")
    }

    private func attributedContent(_ content: TextContent) -> AttributedString? {
        let ns = MacRichTextCodec.decode(from: content)
        guard ns.length > 0 else { return nil }
        return AttributedString(ns)
    }

    private func textFont(_ size: TextSize) -> Font {
        switch size {
        case .heading: return .system(size: 22, weight: .semibold)
        case .small:   return .system(size: 13)
        default:      return .system(size: 15)
        }
    }
}

private struct MacImageElementView: View {
    @Bindable var element: PageElement
    let frame: CGRect
    let isSelected: Bool

    @EnvironmentObject private var storageService: StorageService
    @State private var isCropping = false
    @State private var ocrStatus: String?

    var body: some View {
        Group {
            if let content = element.imageContent {
                imageBody(content: content)
            }
        }
        .sheet(isPresented: $isCropping) {
            if let content = element.imageContent {
                MacImageCropSheet(
                    content: content,
                    onDone: { isCropping = false },
                    onCancel: { isCropping = false }
                )
                .environmentObject(storageService)
            }
        }
        .alert("Image Text", isPresented: Binding(
            get: { ocrStatus != nil },
            set: { if !$0 { ocrStatus = nil } }
        )) {
            Button("Copy") {
                if let ocrStatus { PlatformClipboard.copy(ocrStatus) }
                ocrStatus = nil
            }
            Button("OK", role: .cancel) { ocrStatus = nil }
        } message: {
            Text(ocrStatus ?? "")
        }
    }

    @ViewBuilder
    private func imageBody(content: ImageContent) -> some View {
        let url = MediaStorage.url(for: .images, id: content.id, fileExtension: content.fileFormat)
        let raw = content.imageData.flatMap { PlatformImageFactory.from(data: $0) }
            ?? NSImage(contentsOf: url)
        if let raw {
            let image = MacImageCropMath.applyCrop(to: raw, content: content)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: frame.width, height: frame.height)
                .contextMenu {
                    Button("Crop Image…") { isCropping = true }
                    Button("Copy Text from Image") { Task { await copyTextFromImage(content) } }
                    Button("Rotate 90°") { rotate90() }
                }
        } else {
            MacPlaceholder(label: "Image unavailable", frame: frame)
        }
    }

    private func rotate90() {
        element.rotation += .pi / 2
        element.updatedAt = Date()
        try? storageService.context.save()
    }

    private func copyTextFromImage(_ content: ImageContent) async {
        let data = content.imageData ?? (try? Data(contentsOf: content.fileURL))
        guard let data, let text = await ImageTextRecognitionService.recognise(data: data) else {
            await MainActor.run { ocrStatus = "No text found in image." }
            return
        }
        await MainActor.run {
            PlatformClipboard.copy(text)
            ocrStatus = text
        }
    }
}

private struct MacStickyNoteView: View {
    @Bindable var element: PageElement
    let frame: CGRect
    var onEdit: (() -> Void)?

    var body: some View {
        if let noteText = element.stickyNoteContent?.text {
            Text(noteText.isEmpty ? "Sticky note" : noteText)
                .padding(8)
                .background(MacElementPalette.stickyColor(element.stickyNoteContent?.colorVariant ?? "yellow"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onEdit?() }
                .accessibilityHint("Double tap to edit")
        }
    }
}

struct MacPDFElementView: View {
    let element: PageElement
    let frame: CGRect

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: frame.width, height: frame.height)
            } else if failed {
                MacPlaceholder(label: "PDF unavailable", frame: frame)
            } else {
                ProgressView()
                    .frame(width: frame.width, height: frame.height)
            }
        }
        .task(id: element.id) {
            await loadPDF()
        }
    }

    private func loadPDF() async {
        guard let content = element.pdfPageContent else {
            failed = true
            return
        }
        if let previewURL = content.previewImageURL,
           let preview = NSImage(contentsOf: previewURL) {
            image = preview
        }
        let url = content.pdfFileURL
        let pageIndex = content.pageIndex
        let rendered = await MacPDFRenderer.renderPage(url: url, pageIndex: pageIndex, scale: 2)
        await MainActor.run {
            if let rendered {
                image = rendered
                failed = false
            } else if image == nil {
                failed = true
            }
        }
    }
}

enum MacPDFRenderer {
    static func renderPage(url: URL, pageIndex: Int, scale: CGFloat) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url),
                  pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            return page.thumbnail(of: pixelSize, for: .mediaBox)
        }.value
    }
}

private struct MacShapeElementView: View {
    let element: PageElement
    let frame: CGRect

    var body: some View {
        if let content = element.shapeContent {
            let path = ShapeKindPath.path(for: content.shapeKind, in: CGRect(origin: .zero, size: frame.size))
            let strokeColor = MacElementPalette.color(fromHex: content.strokeColorHex)
            let fillColor = content.fillColorHex.map { MacElementPalette.color(fromHex: $0).opacity(content.fillOpacity) }
            ZStack {
                path.fill(fillColor ?? .clear)
                path.stroke(strokeColor, style: strokeStyle(content))
                if let label = content.containedText, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .frame(width: frame.width, height: frame.height)
                }
            }
            .frame(width: frame.width, height: frame.height)
        }
    }

    private func strokeStyle(_ content: ShapeContent) -> StrokeStyle {
        let width = max(1, content.strokeWidth)
        switch content.strokeStyle {
        case .dashed: return StrokeStyle(lineWidth: width, dash: [6, 4])
        case .dotted: return StrokeStyle(lineWidth: width, dash: [2, 3])
        case .none:   return StrokeStyle(lineWidth: 0)
        default:      return StrokeStyle(lineWidth: width)
        }
    }
}

private struct MacAudioElementView: View {
    let element: PageElement
    let frame: CGRect
    @StateObject private var player = MacAudioPlayer()
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storageService: StorageService

    var body: some View {
        if let content = element.audioContent {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        player.toggle(content: content)
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause audio" : "Play audio")
                    .accessibilityHint("Double-tap to toggle playback")

                    Text("\(format(player.currentTime)) / \(format(player.duration > 0 ? player.duration : content.durationSeconds))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.foregroundMuted)

                    Spacer(minLength: 0)
                }

                progressTrack(content: content)

                if !content.transcript.isEmpty {
                    Text(content.transcript)
                        .font(.caption2)
                        .foregroundStyle(theme.recessiveSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            GeometryReader { geo in
                                Color.clear
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onEnded { value in
                                                seekTranscript(
                                                    at: value.location,
                                                    content: content,
                                                    width: geo.size.width
                                                )
                                            }
                                    )
                            }
                        }
                }
            }
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: frame.width, height: frame.height)
            .contextMenu {
                if !content.transcript.isEmpty {
                    Button("Copy Transcript") {
                        PlatformClipboard.copy(content.transcript)
                    }
                }
                Button("Delete Recording", role: .destructive) {
                    MacElementEditing.softDelete(element, context: storageService.context)
                    NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
                }
            }
            .onAppear { player.load(content: content) }
            .onDisappear { player.pause() }
            .onReceive(NotificationCenter.default.publisher(for: .audioSeekRequested)) { note in
                guard let id = note.userInfo?[AudioSeekKey.contentId] as? UUID,
                      let time = note.userInfo?[AudioSeekKey.time] as? Double,
                      id == content.id else { return }
                player.seek(to: time)
            }
        }
    }

    @ViewBuilder
    private func progressTrack(content: AudioContent) -> some View {
        GeometryReader { geo in
            let total = player.duration > 0 ? player.duration : max(content.durationSeconds, 0.01)
            let active = player.scrubPreview ?? player.currentTime
            let fraction = min(1, max(0, active / total))

            ZStack(alignment: .leading) {
                Capsule().fill(theme.borderSubtle).frame(height: 3)
                Capsule()
                    .fill(theme.accent)
                    .frame(width: geo.size.width * fraction, height: 3)
            }
            .frame(maxHeight: .infinity)
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

    private func seekTranscript(at location: CGPoint, content: AudioContent, width: CGFloat) {
        let total = player.duration > 0 ? player.duration : content.durationSeconds
        guard total > 0, width > 0 else { return }
        let fraction = min(1, max(0, location.x / width))
        player.seek(to: fraction * total)
    }

    private func format(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

@MainActor
final class MacAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var scrubPreview: Double?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var loadedContentId: UUID?

    func load(content: AudioContent) {
        guard loadedContentId != content.id else { return }
        pause()
        loadedContentId = content.id
        guard let url = content.resolvedFileURL() else { return }
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        duration = content.durationSeconds
        currentTime = 0
        isPlaying = false
        removeTimeObserver()
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds
                if self.duration <= 0, let itemDuration = self.player?.currentItem?.duration.seconds, itemDuration.isFinite {
                    self.duration = itemDuration
                }
            }
        }
    }

    func toggle(content: AudioContent) {
        if player == nil || loadedContentId != content.id {
            load(content: content)
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let cap = duration > 0 ? duration : seconds
        let clamped = min(max(0, seconds), cap)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    private func removeTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }
}

private struct MacHighlightView: View {
    let content: HighlightContent
    let parent: PageElement
    let pageSize: CGSize

    private var rect: CGRect {
        let normX = parent.normalizedX + content.rectOriginX * parent.normalizedWidth
        let normY = parent.normalizedY + content.rectOriginY * parent.normalizedHeight
        let normW = content.rectWidth * parent.normalizedWidth
        let normH = content.rectHeight * parent.normalizedHeight
        return CGRect(
            x: normX * pageSize.width,
            y: normY * pageSize.height,
            width: normW * pageSize.width,
            height: normH * pageSize.height
        )
    }

    var body: some View {
        let color = MacElementPalette.highlightColor(content.colorVariant)
        Group {
            switch content.style {
            case .underline:
                Rectangle()
                    .fill(color)
                    .frame(width: rect.width, height: 2)
                    .position(x: rect.midX, y: rect.maxY - 1)
            case .strikethrough:
                Rectangle()
                    .fill(color)
                    .frame(width: rect.width, height: 2)
                    .position(x: rect.midX, y: rect.midY)
            default:
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.45))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}

struct MacPlaceholder: View {
    let label: String
    let frame: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.15))
            .overlay { Text(label).font(.caption).foregroundStyle(.secondary) }
            .frame(width: frame.width, height: frame.height)
    }
}
