import AVFoundation
import SwiftUI

// MARK: - AudioPlayerView

/// 320×280pt popover. Plays an audio annotation with waveform scrubbing,
/// word-level transcript highlight, and speed controls.
struct AudioPlayerView: View {

    let annotation: AudioAnnotation
    @ObservedObject var viewModel: EditorViewModel

    @StateObject private var player = AudioPlayerController()

    private let popoverWidth:  CGFloat = 320
    private let popoverHeight: CGFloat = 280

    var body: some View {
        VStack(spacing: Ink.Spacing.md) {
            header
            waveformSection
            transportControls
            if annotation.isTranscribed, let text = annotation.transcription {
                transcriptSection(text: text)
            }
        }
        .padding(Ink.Spacing.lg)
        .frame(width: popoverWidth, height: popoverHeight)
        .background(Color.inkBackgroundElevated)
        .onAppear { player.load(annotation: annotation, viewModel: viewModel) }
        .onDisappear { player.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.inkAccentPrimary)

            Text(formattedDate)
                .font(.inkSubhead)
                .foregroundColor(.inkTextPrimary)

            Spacer()

            Text(formatDuration(annotation.durationSeconds))
                .font(.inkMono)
                .foregroundColor(.inkTextSecondary)
                .monospacedDigit()
        }
    }

    // MARK: - Waveform

    private var waveformSection: some View {
        let amplitudes = player.amplitudes
        let playhead   = player.duration > 0 ? player.currentTime / player.duration : 0

        return WaveformView(mode: .static(amplitudes: amplitudes, playhead: playhead))
            .frame(height: 60)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = max(0, min(1, value.location.x / popoverWidth))
                        player.seek(to: ratio * player.duration)
                    }
            )
    }

    // MARK: - Transport controls

    private var transportControls: some View {
        HStack(spacing: Ink.Spacing.lg) {
            // Time display
            Text(formatDuration(player.currentTime))
                .font(.inkMono)
                .foregroundColor(.inkTextSecondary)
                .monospacedDigit()
                .frame(width: 52, alignment: .leading)

            Spacer()

            // Play / Pause
            Button {
                player.isPlaying ? player.pause() : player.play()
            } label: {
                Circle()
                    .fill(Color.inkAccentPrimary)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white)
                    )
            }
            .buttonStyle(.plain)

            Spacer()

            // Speed picker
            Menu {
                ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                    Button {
                        player.setRate(Float(rate))
                    } label: {
                        let label = rate == 1.0 ? "Normal" : "\(rate)×"
                        if abs(player.rate - Float(rate)) < 0.01 {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            } label: {
                Text(player.rate == 1.0 ? "1×" : String(format: "%.1g×", player.rate))
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextSecondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    // MARK: - Transcript

    private func transcriptSection(text: String) -> some View {
        let segments = player.segments

        return ScrollView {
            FlowLayout(text: text, segments: segments, currentTime: player.currentTime)
        }
        .frame(maxHeight: 80)
    }

    // MARK: - Helpers

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: annotation.recordedAt)
    }

    private func formatDuration(_ t: Double) -> String {
        let minutes = Int(t) / 60
        let seconds = Int(t) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - FlowLayout (word-highlight transcript)

private struct FlowLayout: View {
    let text:        String
    let segments:    [TranscriptionSegment]
    let currentTime: Double

    var body: some View {
        // Simple word-by-word text with highlight on the active word
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        let attrString: AttributedString = words.enumerated().reduce(AttributedString()) { acc, pair in
            let (i, word) = pair
            var attr = AttributedString(word + (i < words.count - 1 ? " " : ""))
            if let seg = segments.first(where: { $0.word == word }),
               currentTime >= seg.startTime && currentTime < seg.endTime {
                attr.backgroundColor = Color.inkAccentPrimary.opacity(0.25)
            }
            return acc + attr
        }
        return Text(attrString)
            .font(.inkFootnote)
            .foregroundColor(.inkTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Ink.Spacing.xs)
    }
}

// MARK: - AudioPlayerController

@MainActor
final class AudioPlayerController: ObservableObject {

    @Published var isPlaying:   Bool   = false
    @Published var currentTime: Double = 0
    @Published var duration:    Double = 0
    @Published var rate:        Float  = 1.0
    @Published var amplitudes:  [Float] = []
    @Published var segments:    [TranscriptionSegment] = []

    private var avPlayer:      AVAudioPlayer?
    private var progressTimer: Timer?
    private weak var viewModel: EditorViewModel?

    func load(annotation: AudioAnnotation, viewModel: EditorViewModel) {
        self.viewModel = viewModel
        let url = viewModel.audioURL(for: annotation)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.enableRate = true
        player.prepareToPlay()
        avPlayer = player
        duration = player.duration

        // Load amplitude data
        if let data = annotation.amplitudeData,
           let amps = try? JSONDecoder().decode([Float].self, from: data) {
            amplitudes = amps
        }

        // Load transcription segments
        if let data = annotation.transcriptionSegments,
           let segs = try? JSONDecoder().decode([TranscriptionSegment].self, from: data) {
            segments = segs
        }
    }

    func play() {
        guard let player = avPlayer else { return }
        player.rate = rate
        player.play()
        isPlaying = true
        startProgressTimer()
    }

    func pause() {
        avPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func stop() {
        avPlayer?.stop()
        isPlaying = false
        stopProgressTimer()
        viewModel?.playingAnnotationId = nil
    }

    func seek(to time: Double) {
        avPlayer?.currentTime = time
        currentTime = time
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying { avPlayer?.rate = newRate }
    }

    // MARK: - Progress

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.avPlayer else { return }
            self.currentTime = player.currentTime
            if !player.isPlaying {
                self.isPlaying = false
                self.stopProgressTimer()
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
