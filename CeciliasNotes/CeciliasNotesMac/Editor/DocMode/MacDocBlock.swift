import AppKit
import PDFKit
import SwiftData
import SwiftUI

/// Renders one `PageElement` as an inline document block. Text and sticky
/// notes are editable; everything else is read-only with an "iPad" eyebrow
/// where relevant.
struct MacDocBlock: View {
    @Bindable var element: PageElement
    let page: Page
    let notebook: Notebook
    var isFocused: Bool

    @Environment(\.theme) private var theme
    @EnvironmentObject private var storage: StorageService

    var body: some View {
        Group {
            switch element.kind {
            case .text:       textBlock
            case .stickyNote: stickyBlock
            case .image:      imageBlock
            case .stroke:     inkBlock(label: "handwritten on iPad")
            case .shape:      inkBlock(label: "drawn on iPad")
            case .pdfPage:    pdfBlock
            case .audio:      audioBlock
            case .highlight:  highlightBlock
            }
        }
        .contextMenu { blockContextMenu }
    }

    // MARK: - Text (editable rich text — system dictation works here)

    private var textBlock: some View {
        MacDocTextEditor(element: element, isFocused: isFocused)
            .padding(.vertical, 2)
    }

    // MARK: - Sticky note (editable, tinted background)

    private var stickyBlock: some View {
        let tint = stickyTint(element.stickyNoteContent?.colorVariant ?? "yellow")
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 2)
            MacDocStickyEditor(element: element, isFocused: isFocused)
        }
        .padding(12)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Image (inline, right-click delete)

    private var imageBlock: some View {
        let url = element.imageContent.map { MediaStorage.url(for: .images, id: $0.id) }
        return VStack(alignment: .leading, spacing: 4) {
            if let url, let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 480, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                fallback("image unavailable", icon: "photo")
            }
        }
    }

    // MARK: - Ink (strokes / shapes — read only)

    private func inkBlock(label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            eyebrow(label)
            HStack {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.recessiveTertiary)
                Text("\(Int(element.normalizedWidth * 100))% × \(Int(element.normalizedHeight * 100))% region")
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
    }

    // MARK: - PDF page

    private var pdfBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            eyebrow("pdf page")
            HStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.recessiveSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PDF reference")
                        .font(.system(size: 13, weight: .medium))
                    Text("view in canvas mode for full page")
                        .font(.system(size: 10).italic())
                        .foregroundStyle(theme.recessiveTertiary)
                }
                Spacer()
            }
            .padding(12)
            .background(theme.surface.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Audio (mini player + transcript)

    private var audioBlock: some View {
        let audio = element.audioContent
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.recessiveSecondary)
                Text(formatDuration(audio?.durationSeconds ?? 0))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.foregroundMuted)
                Spacer()
            }
            if let transcript = audio?.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.system(size: 13).italic())
                    .foregroundStyle(theme.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("no transcript yet")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(theme.recessiveTertiary)
            }
        }
        .padding(12)
        .background(theme.surface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
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

// MARK: - Editable text via NSTextView (system dictation supported)

private struct MacDocTextEditor: View {
    @Bindable var element: PageElement
    let isFocused: Bool
    @EnvironmentObject private var storage: StorageService
    @State private var attributed: NSAttributedString = .init()
    @Environment(\.theme) private var theme

    var body: some View {
        MacRichTextEditor(
            attributedString: $attributed,
            onPlainTextChange: { plain in
                element.textContent?.text = plain
            },
            onTextViewCreated: { textView in
                if isFocused { textView.window?.makeFirstResponder(textView) }
            }
        )
        .frame(minHeight: 22)
        .onAppear {
            if let content = element.textContent {
                attributed = MacRichTextCodec.decode(from: content)
            }
        }
        .onChange(of: attributed) { _, new in
            guard let content = element.textContent else { return }
            content.attributedTextData = try? NSKeyedArchiver.archivedData(
                withRootObject: new, requiringSecureCoding: false
            )
            content.text = new.string
        }
    }
}

private struct MacDocStickyEditor: View {
    @Bindable var element: PageElement
    let isFocused: Bool
    @State private var text: String = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 14).italic())
            .frame(minHeight: 20)
            .scrollContentBackground(.hidden)
            .onAppear { text = element.stickyNoteContent?.text ?? "" }
            .onChange(of: text) { _, new in
                element.stickyNoteContent?.text = new
            }
    }
}

extension Notification.Name {
    static let macAskAIAboutElement = Notification.Name("app.ceciliasnotes.mac.askAI")
    static let macRequestHandoffToIPad = Notification.Name("app.ceciliasnotes.mac.handoffToIPad")
    static let macStartDictation = Notification.Name("app.ceciliasnotes.mac.startDictation")
}
