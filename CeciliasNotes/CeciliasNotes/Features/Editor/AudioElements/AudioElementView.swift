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
    @Binding var isSelected: Bool
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @StateObject private var player = AudioPlaybackController()
    /// Step 6: drives recording-strip re-renders during an active
    /// Voice Note. Cheap for non-recording elements — they re-
    /// evaluate body on session ticks but `isRecording` short-
    /// circuits to false and the rendered output is unchanged.
    @ObservedObject private var recordingSession = RecordingSession.shared

    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: ResizeDelta? = nil
    @State private var seekDragSeconds: Double? = nil

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
        let base = CGRect(
            x: element.normalizedX * pageSize.width,
            y: element.normalizedY * pageSize.height,
            width: element.normalizedWidth * pageSize.width,
            height: Self.stripHeight
        )
        let displayed = displayedRect(base: base)

        ZStack(alignment: .topLeading) {
            // STRUCTURAL FIX — `.offset`, not `.position`. A
            // `.position`'d strip expands to page-sized layout
            // bounds; stacked page-sized element views then break
            // gesture arbitration, and the strip's interior play
            // button never receives the tap (`[AudioPlay] 1. button
            // tap received` never logged on device). `.offset` keeps
            // the strip's layout bounds at `displayed` size so the
            // tap reaches the button inside it. Equivalent placement
            // in this `.topLeading` ZStack: offset by (minX, minY).
            strip(width: displayed.width)
                .rotationEffect(.radians(element.rotation))
                .frame(width: displayed.width, height: displayed.height)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if !isSelected && !isRecording { isSelected = true }
                    }
                )
                .gesture(isSelected && !isRecording ? bodyDragGesture : nil)
                .offset(x: displayed.minX, y: displayed.minY)

            if isSelected && !isRecording {
                selectionChrome(rect: displayed)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onAppear {
            #if DEBUG
            print("[AudioPlayback] AudioElementView.onAppear — elementId=\(element.id.uuidString.prefix(8)) contentId=\(content.id.uuidString.prefix(8)) isRecording=\(isRecording)")
            #endif
            if !isRecording {
                // Step 10: if the audio file is an iCloud stub
                // (the SwiftData record arrived ahead of the bytes
                // on a freshly-restored device), nudge the
                // download. `player.load(url:)` will no-op on a
                // missing file; the user sees the inert strip and
                // can tap play once iCloud lands the file.
                let url = content.fileURL
                #if DEBUG
                let fm = FileManager.default
                let exists = fm.fileExists(atPath: url.path)
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
                let ubi = UbiquitousFileStatus.currentState(at: url)
                print("[AudioPlayback] AudioElementView file check — url=\(url.lastPathComponent) exists=\(exists) size=\(size) ubi=\(ubi) durationSecondsOnContent=\(content.durationSeconds)")
                #endif
                if case .downloading = UbiquitousFileStatus.currentState(at: url) {
                    _ = UbiquitousFileStatus.requestDownload(at: url)
                }
                player.load(url: url)
            }
        }
        .onDisappear { player.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .audioSeekRequested)) { note in
            guard let id   = note.userInfo?[AudioSeekKey.contentId] as? UUID,
                  let time = note.userInfo?[AudioSeekKey.time] as? Double,
                  id == content.id
            else { return }
            player.seek(to: time)
        }
    }

    /// Step 6: a placeholder strip created at the start of a Voice
    /// Note recording carries `durationSeconds = 0` until the
    /// session's stop path writes the captured duration. Use that
    /// signal — plus an active recording session targeting this
    /// element — to render the recording UI (pulsing dot + live
    /// elapsed timer + stop button) instead of the play/seek
    /// surface.
    private var isRecording: Bool {
        guard case .voiceNote(let ctx) = RecordingSession.shared.state else {
            return false
        }
        return ctx.audioElementId == element.id
    }

    // MARK: - Strip body

    @ViewBuilder
    private func strip(width: CGFloat) -> some View {
        if isRecording {
            recordingStrip
        } else {
            readyStrip
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
    }

    // MARK: - Recording strip (Step 6 Voice Note placeholder)

    private var recordingStrip: some View {
        HStack(spacing: 10) {
            RecordingPulseDot()
                .frame(width: 12, height: 12)
                .padding(.leading, 4)
            Text(format(RecordingSession.shared.elapsedSeconds))
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
    }

    private var playPauseButton: some View {
        Button {
            print("[AudioPlay] 1. button tap received, elementId=\(element.id), contentId=\(content.id)")
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(theme.accentMuted))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Long-press → debug bypass that constructs a fresh
        // AVAudioPlayer for this file and calls play() with the
        // minimum possible session setup. If this works but the
        // normal tap doesn't, the regression is in the controller
        // flow rather than the file/session layer.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.6)
                .onEnded { _ in
                    #if DEBUG
                    print("[AudioPlayback] DEBUG long-press direct-play requested for elementId=\(element.id)")
                    #endif
                    player.debugPlayDirectly(url: content.fileURL)
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

        // Two handles — left edge mid + right edge mid — for the
        // width-only resize affordance.
        widthHandle(.left,  at: CGPoint(x: rect.minX, y: rect.midY))
        widthHandle(.right, at: CGPoint(x: rect.maxX, y: rect.midY))

        floatingToolbar()
            .position(
                x: rect.midX,
                y: max(14, rect.minY - Self.toolbarGap - 14)
            )
    }

    private func widthHandle(_ corner: Corner, at point: CGPoint) -> some View {
        // `.offset`, not `.position` — keeps the handle's layout
        // bounds at 4×18 so it doesn't expand page-sized and shadow
        // other gestures. The 4×18 view's natural origin is (0,0);
        // offsetting by `point - (2, 9)` centres it on `point`.
        Capsule()
            .fill(theme.accent)
            .frame(width: 4, height: 18)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(resizeGesture(for: corner))
            .offset(x: point.x - 2, y: point.y - 9)
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

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                dragOffset = value.translation
            }
            .onEnded { value in
                let dxNorm = value.translation.width  / pageSize.width
                let dyNorm = value.translation.height / pageSize.height
                element.normalizedX = clampNorm(element.normalizedX + Double(dxNorm))
                element.normalizedY = clampNorm(element.normalizedY + Double(dyNorm))
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
                element.normalizedX     = clampNorm(Double(new.minX) / Double(pageSize.width))
                element.normalizedWidth = min(1, Double(new.width) / Double(pageSize.width))
                // Height stays fixed — normalize against current pageSize
                // so a future page-size change preserves the visual height.
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

/// Self-contained pulsing red dot. Used by the Voice Note inline
/// strip during recording — same metaphor as the floating
/// controls' dot.
struct RecordingPulseDot: View {
    @State private var pulsing: Bool = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .scaleEffect(pulsing ? 1.15 : 0.85)
            .animation(
                .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
            .onDisappear { pulsing = false }
    }
}
