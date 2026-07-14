import SwiftData
import SwiftUI
import UIKit

/// Renders one V6 `PageElement` of kind `.audio` as a compact play
/// strip per architecture §9: ~50pt tall, play/pause + elapsed-of-
/// total time label + thin progress bar.
///
/// First interactive PageElement-backed view — the playback state
/// lives on `AudioPlaybackController` (one per view instance) rather
/// than on the element/content models, which stay pure data.
///
/// Layout deviations from the image/PDF chrome:
///   • Strip height locked at 50pt; only width is resizable.
///   • Corner handles drive width-only resize (height stays fixed).
///   • Pinch is disabled — keeps interaction surface clean given
///     play/pause + seek live on the strip body.
///   • Rotation supported via the toolbar rotate button (90°
///     steps) — rare but free given the shared chrome pattern.
struct AudioElementView: View {

    @Bindable var element: PageElement
    @Bindable var content: AudioContent
    let pageSize: CGSize
    /// When false (drawing tools active) play / context-menu delete
    /// still work, but tap-to-select chrome and the floating toolbar
    /// are hidden so handwriting isn't fighting selection gestures.
    let allowsSelection: Bool
    @Binding var isSelected: Bool
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: ResizeDelta? = nil
    @State private var isRecordingActive = false
    @State private var shareItem: ShareTextItem?

    private static let stripHeight: CGFloat = 50
    private static let handleSize: CGFloat = 10
    private static let toolbarGap: CGFloat = 8
    private static let minNormalizedWidth: Double = 0.10

    private struct ResizeDelta: Equatable {
        var corner: Corner
        var translation: CGSize
    }
    private enum Corner: Equatable { case left, right }

    var body: some View {
        // Audio strip is X-locked to horizontal center of the page —
        // the only free axis is Y. The drag gesture ignores horizontal
        // translation and the stored `normalizedX` is overridden here
        // so legacy rows that drifted off-center snap back in.
        let stripWidth = element.normalizedWidth * pageSize.width
        let centeredX = max(0, (pageSize.width - stripWidth) / 2)
        let base = CGRect(
            x: centeredX,
            y: element.normalizedY * pageSize.height,
            width: stripWidth,
            height: Self.stripHeight
        )
        let displayed = displayedRect(base: base)

        ZStack(alignment: .topLeading) {
            // Gestures BEFORE `.position(...)` per the Step 7.2
            // canonical pattern. Audio strip didn't have an
            // explicit `.contentShape` previously — the strip()
            // view's interior controls (play/pause/seek) own the
            // foreground hit-tests; we add an explicit shape so
            // the outer body tap-to-select fires reliably across
            // the strip's full rect (not only where the play
            // button happens to sit).
            AudioElementStripContent(
                elementId: element.id,
                content: content,
                hasTranscript: hasTranscript,
                isRecordingActive: $isRecordingActive,
                onCopy: copyTranscript,
                onShare: shareTranscript,
                onDelete: onDelete
            )
                .rotationEffect(.radians(element.rotation))
                .frame(width: displayed.width, height: displayed.height)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        guard allowsSelection else { return }
                        if !isSelected && !isRecordingActive { isSelected = true }
                    }
                )
                .gesture(allowsSelection && isSelected && !isRecordingActive ? bodyDragGesture : nil)
                .position(x: displayed.midX, y: displayed.midY)

            if allowsSelection && isSelected && !isRecordingActive {
                selectionChrome(rect: displayed)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .sheet(item: $shareItem) { item in
            ShareTextActivityView(text: item.text)
        }
    }

    private var trimmedTranscript: String {
        content.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTranscript: Bool { !trimmedTranscript.isEmpty }

    private func copyTranscript() {
        guard hasTranscript else { return }
        PlatformClipboard.copy(trimmedTranscript)
        HapticManager.shared.toolSwitched()
    }

    private func shareTranscript() {
        guard hasTranscript else { return }
        shareItem = ShareTextItem(text: trimmedTranscript)
    }

    // MARK: - Selection chrome (width-only resize + rotate + delete)

    private func displayedRect(base: CGRect) -> CGRect {
        if let r = resizeDelta {
            return resizedRect(base: base, corner: r.corner, translation: r.translation)
        }
        let cx = base.midX + dragOffset.width
        let cy = base.midY + dragOffset.height
        return CGRect(
            x: cx - base.width / 2,
            y: cy - base.height / 2,
            width: base.width,
            height: base.height
        )
    }

    /// Width-only resize. Left handle anchors the right edge; right
    /// handle anchors the left edge. Height stays fixed at the
    /// strip's natural 50pt.
    private func resizedRect(base: CGRect, corner: Corner, translation: CGSize) -> CGRect {
        let minW = CGFloat(Self.minNormalizedWidth) * pageSize.width
        switch corner {
        case .left:
            let proposedW = max(minW, base.width - translation.width)
            return CGRect(
                x: base.maxX - proposedW,
                y: base.minY,
                width: proposedW,
                height: base.height
            )
        case .right:
            let proposedW = max(minW, base.width + translation.width)
            return CGRect(
                x: base.minX,
                y: base.minY,
                width: proposedW,
                height: base.height
            )
        }
    }

    @ViewBuilder
    private func selectionChrome(rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                theme.accent,
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)

        widthHandle(.left,  at: CGPoint(x: rect.minX, y: rect.midY))
        widthHandle(.right, at: CGPoint(x: rect.maxX, y: rect.midY))

        floatingToolbar()
            .position(
                x: rect.midX,
                y: max(14, rect.minY - Self.toolbarGap - 14)
            )
            .zIndex(10)
            .allowsHitTesting(true)
    }

    private func widthHandle(_ corner: Corner, at point: CGPoint) -> some View {
        Capsule()
            .fill(theme.accent)
            .frame(width: 4, height: 18)
            .contentShape(Rectangle().inset(by: -8))
            .position(point)
            .gesture(resizeGesture(for: corner))
    }

    private func floatingToolbar() -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.foreground)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .gesture(bodyDragGesture)

            Button {
                rotate90()
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hasTranscript {
                Button {
                    copyTranscript()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.foreground)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy transcript")

                Button {
                    shareTranscript()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.foreground)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share transcript")
            }

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete recording")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Gestures

    private var bodyDragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                dragOffset = CGSize(width: 0, height: value.translation.height)
            }
            .onEnded { value in
                let dyNorm = value.translation.height / pageSize.height
                let maxY = max(0, 1 - element.normalizedHeight)
                let centeredNormX = max(0, (1.0 - element.normalizedWidth) / 2.0)
                element.normalizedX = centeredNormX
                element.normalizedY = max(0, min(maxY, element.normalizedY + Double(dyNorm)))
                element.updatedAt   = Date()
                dragOffset = .zero
            }
    }

    private func resizeGesture(for corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                resizeDelta = ResizeDelta(corner: corner, translation: value.translation)
            }
            .onEnded { value in
                let base = CGRect(
                    x: element.normalizedX * pageSize.width,
                    y: element.normalizedY * pageSize.height,
                    width: element.normalizedWidth * pageSize.width,
                    height: Self.stripHeight
                )
                let new = resizedRect(base: base, corner: corner, translation: value.translation)
                let normX = Double(new.minX) / Double(pageSize.width)
                let normW = Double(new.width) / Double(pageSize.width)
                element.normalizedWidth = max(0.05, min(1, normW))
                element.normalizedX     = max(0, min(1 - element.normalizedWidth, normX))
                element.normalizedHeight = Double(Self.stripHeight) / Double(pageSize.height)
                element.updatedAt        = Date()
                resizeDelta = nil
            }
    }

    private func rotate90() {
        let next = element.rotation + .pi / 2
        let twoPi = 2 * Double.pi
        element.rotation = next.truncatingRemainder(dividingBy: twoPi)
        element.updatedAt = Date()
    }

    private func clampNorm(_ v: Double) -> Double { max(0, min(1, v)) }
}

// MARK: - Playback strip (isolated from parent layout chrome)

/// Owns `AudioPlaybackController` + recording-session ticks so
/// 10 Hz `currentTime` updates don't invalidate the overlay shell.
private struct AudioElementStripContent: View {

    let elementId: UUID
    @Bindable var content: AudioContent
    let hasTranscript: Bool
    @Binding var isRecordingActive: Bool
    let onCopy: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @StateObject private var player = AudioPlaybackController()
    @ObservedObject private var recordingSession = RecordingSession.shared
    @State private var seekDragSeconds: Double? = nil

    private var isRecording: Bool {
        switch recordingSession.state {
        case .voiceNote(let ctx):  return ctx.audioElementId == elementId
        case .dictation(let ctx):  return ctx.audioElementId == elementId
        case .idle:                return false
        }
    }

    var body: some View {
        Group {
            if isRecording {
                recordingStrip
            } else {
                readyStrip
            }
        }
        .onAppear {
            #if DEBUG
            dlog("[AudioPlayback] AudioElementStripContent.onAppear — elementId=\(elementId.uuidString.prefix(8)) contentId=\(content.id.uuidString.prefix(8)) isRecording=\(isRecording)")
            #endif
            isRecordingActive = isRecording
            guard !isRecording else { return }
            let url = content.fileURL
            #if DEBUG
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: url.path)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
            let ubi = UbiquitousFileStatus.currentState(at: url)
            dlog("[AudioPlayback] file check — url=\(url.lastPathComponent) exists=\(exists) size=\(size) ubi=\(ubi) durationSecondsOnContent=\(content.durationSeconds)")
            #endif
            if case .downloading = UbiquitousFileStatus.currentState(at: url) {
                _ = UbiquitousFileStatus.requestDownload(at: url)
            }
            player.load(url: url)
        }
        .onDisappear { player.pause() }
        .onChange(of: isRecording) { _, nowRecording in
            isRecordingActive = nowRecording
            guard !nowRecording else { return }
            player.load(url: content.resolvedFileURL() ?? content.fileURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioSeekRequested)) { note in
            guard let id   = note.userInfo?[AudioSeekKey.contentId] as? UUID,
                  let time = note.userInfo?[AudioSeekKey.time] as? Double,
                  id == content.id
            else { return }
            player.seek(to: time)
        }
    }

    private var readyStrip: some View {
        HStack(spacing: 10) {
            playPauseButton
            timeLabel
            progressTrack
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
                )
        )
        .contextMenu {
            if hasTranscript {
                Button {
                    onCopy()
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                Button {
                    onShare()
                } label: {
                    Label("Share Transcript…", systemImage: "square.and.arrow.up")
                }
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Recording", systemImage: "trash")
            }
        }
        .accessibilityLabel(A11y.audioLabel(
            duration: content.durationSeconds,
            hasTranscription: hasTranscript
        ))
        .accessibilityHint(A11y.audioHint)
    }

    private var recordingStrip: some View {
        HStack(spacing: 10) {
            RecordingPulseDot()
                .frame(width: 12, height: 12)
                .padding(.leading, 4)
            Text(format(recordingSession.elapsedSeconds))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                Task { await RecordingSession.shared.stop() }
                HapticManager.shared.destructiveConfirmed()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(theme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.5), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording in progress")
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(theme.accentMuted))
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.6)
                .onEnded { _ in
                    #if DEBUG
                    dlog("[AudioPlayback] DEBUG long-press direct-play requested for elementId=\(elementId)")
                    #endif
                    player.debugPlayDirectly(url: content.resolvedFileURL() ?? content.fileURL)
                }
        )
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    private var timeLabel: some View {
        let totalDuration = player.duration > 0 ? player.duration : content.durationSeconds
        return Text("\(format(player.currentTime)) / \(format(totalDuration))")
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(theme.foregroundMuted)
            .lineLimit(1)
    }

    private var progressTrack: some View {
        GeometryReader { geo in
            let totalDuration = player.duration > 0 ? player.duration : max(content.durationSeconds, 0.01)
            let active = seekDragSeconds ?? player.currentTime
            let fraction = totalDuration > 0 ? min(1, max(0, active / totalDuration)) : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.borderSubtle)
                    .frame(height: 3)
                Capsule()
                    .fill(theme.accent)
                    .frame(width: geo.size.width * fraction, height: 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(seekGesture(totalDuration: totalDuration, width: geo.size.width))
        }
        .frame(maxHeight: .infinity)
    }

    private func seekGesture(totalDuration: Double, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = min(1, max(0, value.location.x / width))
                seekDragSeconds = fraction * totalDuration
            }
            .onEnded { _ in
                if let target = seekDragSeconds {
                    player.seek(to: target)
                }
                seekDragSeconds = nil
            }
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let minutes = s / 60
        let secs = s % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

private struct ShareTextItem: Identifiable {
    let id = UUID()
    let text: String
}

private struct ShareTextActivityView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Self-contained pulsing red dot. Used by the Voice Note inline
/// strip during recording — same metaphor as the floating
/// controls' dot.
struct RecordingPulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing: Bool = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .scaleEffect(reduceMotion ? 1.0 : (pulsing ? 1.15 : 0.85))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { if !reduceMotion { pulsing = true } }
            .onDisappear { pulsing = false }
    }
}
