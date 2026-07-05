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
    let element: PageElement
    let pageSize: CGSize
    let pdfParents: [UUID: PageElement]
    var isSelected: Bool = false
    var onSelect: ((UUID) -> Void)?
    var onEditText: ((PageElement) -> Void)?

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
                .rotationEffect(.radians(element.rotation))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .frame(width: frame.width, height: frame.height)
                    }
                }
                .position(x: frame.midX, y: frame.midY)
                .onTapGesture {
                    onSelect?(element.id)
                }
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
                    isSelected: isSelected,
                    onEdit: { onEditText?(element) }
                )
            case .image:
                MacImageElementView(element: element, frame: frame)
            case .stickyNote:
                MacStickyNoteView(element: element, frame: frame)
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
    let element: PageElement
    let frame: CGRect
    let isSelected: Bool
    let onEdit: () -> Void

    var body: some View {
        if let text = element.textContent?.text {
            Text(text)
                .font(textFont)
                .foregroundStyle(.primary)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onEdit)
        }
    }

    private var textFont: Font {
        switch element.textContent?.size {
        case .heading: return .system(size: 22, weight: .semibold)
        case .small:   return .system(size: 13)
        default:      return .system(size: 15)
        }
    }
}

private struct MacImageElementView: View {
    let element: PageElement
    let frame: CGRect

    var body: some View {
        if let content = element.imageContent {
            let url = MediaStorage.url(for: .images, id: content.id, fileExtension: content.fileFormat)
            let image = content.imageData.flatMap { PlatformImageFactory.from(data: $0) }
                ?? NSImage(contentsOf: url)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: frame.width, height: frame.height)
            } else {
                MacPlaceholder(label: "Image unavailable", frame: frame)
            }
        }
    }
}

private struct MacStickyNoteView: View {
    let element: PageElement
    let frame: CGRect

    var body: some View {
        if let noteText = element.stickyNoteContent?.text {
            Text(noteText)
                .padding(8)
                .background(MacElementPalette.stickyColor(element.stickyNoteContent?.colorVariant ?? "yellow"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
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
            let image = NSImage(size: pixelSize)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: pixelSize).fill()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.translateBy(x: 0, y: pixelSize.height)
                ctx.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: ctx)
            }
            image.unlockFocus()
            return image
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

    var body: some View {
        if let content = element.audioContent {
            HStack(spacing: 8) {
                Button {
                    player.toggle(content: content)
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatDuration(content.durationSeconds))
                        .font(.caption.monospacedDigit())
                    if !content.transcript.isEmpty {
                        Text(content.transcript)
                            .font(.caption2)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: frame.width, height: frame.height)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

@MainActor
final class MacAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    private var avPlayer: AVPlayer?

    func toggle(content: AudioContent) {
        if isPlaying {
            avPlayer?.pause()
            isPlaying = false
            return
        }
        guard let url = content.resolvedFileURL() else { return }
        avPlayer = AVPlayer(url: url)
        avPlayer?.play()
        isPlaying = true
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
