/// AudioAnnotationCardView.swift
/// Cecilia's Notes
///
/// Phase 4B: replaces the pin-and-popover audio annotation surface
/// with a full-width on-page card. Two views live here:
///
///   • `AudioAnnotationCardsOverlayView` — per-page overlay that
///     stacks every (non-deleted) `AudioAnnotation` for the page in
///     a vertical run starting at normalised (0.5, 0.05). Mounted in
///     `ContinuousCanvasView` in place of the legacy pin overlay.
///
///   • `AudioAnnotationCardView` — one card. 3pt brand-accent left
///     rule, header with mic + duration + play/pause, scrubable
///     waveform with played-portion highlight, expandable
///     transcript. Long-press → context menu (Delete recording).
///
/// Stored `pageX` / `pageY` on the SwiftData model are intentionally
/// ignored for placement (Phase 4 spec: "no backwards compatibility,
/// start clean"). The card list is rendered in `recordedAt` order
/// from the top of the page; spacing is layout-driven, not stored.

import AVFoundation
import Combine
import SwiftUI

// MARK: - AudioAnnotationCardsOverlayView

struct AudioAnnotationCardsOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel
    let pageId: UUID
    let coordinateSpace: PageCoordinateSpace

    /// Page-side normalised inset. 0.05 left/right + 0.05 top — matches
    /// the spec's "(0.5, 0.05) default position, normalised width 0.9".
    private static let topInset:  Double = 0.05
    private static let sideInset: Double = 0.05
    /// Vertical normalised gap between consecutive cards.
    private static let cardGap:   Double = 0.03

    private var pageSize: CGSize { coordinateSpace.baseSize }

    /// Page-scoped, non-deleted, oldest-first. Phase 5A+5C Step 3:
    /// `AudioRecord` is denormalised by `pageId` (no `Page`
    /// relationship), so we fetch via the storage façade.
    private var annotations: [AudioRecord] {
        StorageService.shared.fetchAudioRecords(forPageId: pageId)
    }

    var body: some View {
        let width  = (1.0 - 2 * Self.sideInset) * Double(pageSize.width)
        let leadingInset = Self.sideInset * Double(pageSize.width)
        let topInsetPx   = Self.topInset * Double(pageSize.height)
        let gap          = Self.cardGap * Double(pageSize.height)

        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(annotations) { annotation in
                    AudioAnnotationCardView(
                        annotation: annotation,
                        viewModel:  viewModel
                    )
                    .frame(width: width, alignment: .topLeading)
                }
            }
            .offset(x: leadingInset, y: topInsetPx)
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
    }
}

// MARK: - AudioAnnotationCardView

struct AudioAnnotationCardView: View {

    /// `@Bindable` (not `let`) so SwiftUI's Observation framework
    /// registers reads against the SwiftData model. Without this, the
    /// async transcript write performed by `SpeechTranscriber` lands on
    /// the same managed object but never triggers a card re-render —
    /// the user sees "transcribing…" forever even after the on-disk
    /// transcript is populated.
    @Bindable var annotation: AudioRecord
    @ObservedObject var viewModel: EditorViewModel
    @Environment(\.theme) private var theme

    @StateObject private var audio = AudioCardController()
    @State private var transcriptExpanded: Bool = false

    // Phase 5A+5C Step 3: amplitudes live on the record as a native
    // `[Float]` — no JSON decode at read time.

    var body: some View {
        #if DEBUG
        // Phase-5-followup diagnostic 3 (audio card "blue line").
        // The 3pt rule on this card is `brandAccent` — when content
        // collapses, what's left looks like a tall blue vertical
        // line. Trace whether header / waveform / transcript
        // branches actually render content vs. degenerate
        // zero-content frames.
        let _ = print("[AudioDiag] body building for recordId=\(annotation.id) duration=\(annotation.durationSeconds) amplitudes.count=\(annotation.amplitudes.count) transcript.count=\(annotation.transcript.count) transcriptExpanded=\(transcriptExpanded)")
        #endif
        return HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(theme.accent)
                .frame(width: 3)
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 10) {
                #if DEBUG
                let _ = print("[AudioDiag]   content VStack rendering for \(annotation.id)")
                #endif
                header
                waveform
                transcriptDisclosure
                if transcriptExpanded { transcriptBody }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Card body tap → expand/collapse transcript. The header
            // and waveform have their own gestures with
            // `.highPriorityGesture` to avoid conflicting with this
            // body-wide tap.
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    transcriptExpanded.toggle()
                }
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                audio.stop()
                viewModel.deleteAudioAnnotation(annotation)
            } label: {
                Label("Delete recording", systemImage: "trash")
            }
        }
        .onDisappear { audio.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.recessiveSecondary)
            Text(formatDuration(annotation.durationSeconds))
                .font(.system(size: 12))
                .foregroundStyle(theme.recessiveSecondary)
                .monospacedDigit()
            Spacer(minLength: 8)
            Button {
                togglePlayback()
            } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audio.isPlaying ? "Pause recording" : "Play recording")
        }
    }

    // MARK: Waveform

    private var waveform: some View {
        // Played-portion ratio. Falls back to 0 when the player
        // hasn't loaded yet (duration == 0).
        let progress: Double = {
            guard audio.duration > 0 else { return 0 }
            return min(1, max(0, audio.currentTime / audio.duration))
        }()
        return GeometryReader { proxy in
            WaveformBars(amplitudes: annotation.amplitudes, progress: progress)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                // Scrub on drag — also fires for a single tap (drag with
                // `minimumDistance: 0` resolves on touch-down).
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard proxy.size.width > 0 else { return }
                            let ratio = min(1, max(0, value.location.x / proxy.size.width))
                            audio.seek(to: ratio)
                        }
                )
        }
        .frame(height: 36)
    }

    // MARK: Transcript

    private var transcriptDisclosure: some View {
        HStack(spacing: 4) {
            Text("transcript")
                .font(.system(size: 11))
                .foregroundStyle(theme.recessiveTertiary)
            Image(systemName: transcriptExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(theme.recessiveTertiary)
            Spacer(minLength: 0)
        }
        .frame(height: 14)
    }

    @ViewBuilder
    private var transcriptBody: some View {
        // Phase 5A+5C Step 3: `transcript` is non-optional String;
        // empty = still transcribing (or recogniser unavailable for
        // the locale).
        let text: String = annotation.transcript.isEmpty
            ? "transcribing…"
            : annotation.transcript
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(theme.foreground)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Helpers

    private func togglePlayback() {
        if audio.isPlaying {
            audio.pause()
        } else {
            let url = viewModel.audioURL(for: annotation)
            audio.playOrResume(url: url)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - WaveformBars

/// Stateless bar-chart renderer. 2pt-wide bars, 1pt gap, height
/// proportional to the amplitude in `[0, 1]`. Bars left of `progress`
/// (a 0…1 ratio) render in `brandAccent`; bars right of the
/// playhead render in `inkRecessiveQuinary`.
private struct WaveformBars: View {
    let amplitudes: [Float]
    let progress: Double
    @Environment(\.theme) private var theme

    private let barWidth:  CGFloat = 2
    private let barGap:    CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let totalBars = max(1, Int(proxy.size.width / (barWidth + barGap)))
            let bars = downsample(amplitudes, target: totalBars)
            let playheadIndex = Int(progress * Double(totalBars))
            HStack(alignment: .center, spacing: barGap) {
                ForEach(0..<bars.count, id: \.self) { i in
                    let h = max(2, CGFloat(bars[i]) * proxy.size.height)
                    Capsule()
                        .fill(i <= playheadIndex
                              ? theme.accent
                              : theme.recessiveQuinary)
                        .frame(width: barWidth, height: h)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }

    /// Even-stride downsample. The capture path produces ~300
    /// amplitudes per recording; the bar count is driven by view
    /// width (typically 100–250 bars on a portrait page). When
    /// amplitudes is empty, returns a flat zero array so the bar
    /// row still draws baseline ticks.
    private func downsample(_ source: [Float], target: Int) -> [Float] {
        guard target > 0 else { return [] }
        guard !source.isEmpty else { return Array(repeating: 0, count: target) }
        if source.count <= target { return source }
        var out = [Float]()
        out.reserveCapacity(target)
        let step = Double(source.count) / Double(target)
        for i in 0..<target {
            let idx = min(source.count - 1, Int(Double(i) * step))
            out.append(source[idx])
        }
        return out
    }
}

// MARK: - AudioCardController

/// Per-card play/pause/seek state. One `AVAudioPlayer` per card,
/// lazily constructed on first `playOrResume`. Updates a 20Hz
/// `Timer` while playing so the waveform playhead and the
/// transcript progress stay in sync.
@MainActor
final class AudioCardController: ObservableObject {

    @Published private(set) var isPlaying:   Bool   = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration:    Double = 0

    private var player: AVAudioPlayer?
    private var timer:  Timer?
    private let delegate = AudioCardDelegate()

    func playOrResume(url: URL) {
        if player == nil || player?.url != url {
            guard FileManager.default.fileExists(atPath: url.path),
                  let p = try? AVAudioPlayer(contentsOf: url) else { return }
            player = p
            duration = p.duration
            p.delegate = delegate
            delegate.onFinish = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isPlaying = false
                    self.currentTime = 0
                    self.player?.currentTime = 0
                    self.stopTimer()
                }
            }
            p.prepareToPlay()
        }
        // A finished file → rewind so a tap always plays from start.
        if let p = player, p.currentTime >= p.duration { p.currentTime = 0 }
        guard player?.play() == true else { return }
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        stopTimer()
    }

    /// `ratio` is 0…1 across the file's full duration.
    func seek(to ratio: Double) {
        guard let p = player else { return }
        let t = max(0, min(p.duration, ratio * p.duration))
        p.currentTime = t
        currentTime = t
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

private final class AudioCardDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
