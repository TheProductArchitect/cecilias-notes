import SwiftUI

/// Full-screen recording surface for lecture mode. Takes over from
/// the editor while a recording is active and slides back down when
/// the user stops — the underlying editor is preserved exactly as
/// it was. Layout per Pass A spec:
///
///   • Title field (22pt 800 lowercase, inline editor style)
///   • HH:MM:SS timer (SF Pro heavy, 48pt)
///   • 40-bar real-time waveform
///   • Auto-scrolling live transcript
///   • 1.5pt black rule
///   • Pause / Stop / (reserved Pass B) controls
///   • Ghost letter behind everything
///
/// Background colour follows system theme — no special recording-
/// mode chrome. The recording state itself is the signal that the
/// app is in a different mode.
struct LectureRecordingView: View {
    @ObservedObject var recorder: LectureRecorder
    /// Called when the user confirms "end lecture?" — receives the
    /// saved record so the host editor can insert the post-stop
    /// placeholder TextBlock and route search index re-indexing.
    let onStop: (LectureRecord?) -> Void

    @State private var showStopConfirm = false
    @State private var levelSamples: [Float] = Array(repeating: 0, count: 40)
    @State private var sampleTimer: Timer?
    @FocusState private var titleFocused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            // Ghost letter — first letter of title, "L" fallback.
            GhostLetter(
                character: ghostCharacter,
                size: 260,
                onDarkBackground: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: 60, y: 60)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                contentColumn
                Rectangle()
                    .fill(Color.inkTextPrimary)
                    .frame(height: 1.5)
                controlsRow
            }
        }
        .onAppear { startSamplingLevels() }
        .onDisappear { sampleTimer?.invalidate() }
        .alert("end lecture?", isPresented: $showStopConfirm) {
            Button("keep recording", role: .cancel) {}
            Button("end", role: .destructive) {
                Task {
                    let record = await recorder.stop()
                    onStop(record)
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Title + timer + waveform + transcript

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            titleField
                .padding(.horizontal, 32)
                .padding(.top, 32)

            timerLabel
                .frame(maxWidth: .infinity)

            waveform
                .frame(height: 64)
                .padding(.horizontal, 32)

            transcriptArea
                .padding(.horizontal, 32)

            Spacer(minLength: 16)
        }
    }

    private var titleField: some View {
        TextField("lecture title", text: $recorder.title)
            .font(.system(size: 22, weight: .heavy))
            .tracking(-0.5)
            .foregroundStyle(Color.inkTextPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($titleFocused)
            .submitLabel(.done)
    }

    private var timerLabel: some View {
        Text(formattedElapsed)
            .font(.system(size: 48, weight: .heavy))
            .tracking(-1)
            .foregroundStyle(Color.inkTextPrimary)
            .monospacedDigit()
    }

    private var formattedElapsed: String {
        let total = Int(recorder.elapsedSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // MARK: Waveform

    /// 40 bars. Each frame shifts the older samples left and pushes
    /// a fresh `recorder.audioLevel` value onto the right edge, so
    /// the visualisation scrolls right-to-left. Drawing happens in
    /// a SwiftUI Canvas — no third-party charting, no UIKit bridge.
    private var waveform: some View {
        Canvas { ctx, size in
            let count = levelSamples.count
            guard count > 0 else { return }
            let barW = size.width / CGFloat(count) * 0.6
            let gap  = size.width / CGFloat(count) * 0.4
            let midY = size.height / 2
            for i in 0..<count {
                let level = CGFloat(levelSamples[i])
                let h = max(2, level * size.height * 0.9)
                let x = CGFloat(i) * (barW + gap)
                let rect = CGRect(
                    x: x,
                    y: midY - h / 2,
                    width: barW,
                    height: h
                )
                let path = Path(roundedRect: rect, cornerRadius: barW / 2)
                ctx.fill(
                    path,
                    with: .color(recorder.isPaused
                        ? Color.inkRecessiveTertiary
                        : Color.brandAccent)
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func startSamplingLevels() {
        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                levelSamples.removeFirst()
                levelSamples.append(recorder.isPaused ? 0 : recorder.audioLevel)
            }
        }
    }

    // MARK: Transcript

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if recorder.liveTranscript.isEmpty {
                        Text("listening…")
                            .font(.system(size: 15).italic())
                            .foregroundStyle(Color.inkRecessiveTertiary)
                    } else {
                        Text(recorder.liveTranscript)
                            .font(.system(size: 15))
                            .lineSpacing(15 * 0.4)        // 1.4× line spacing
                            .foregroundStyle(Color.inkTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("transcript-tail")
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 240)
            .onChange(of: recorder.liveTranscript) { _, _ in
                withAnimation(.linear(duration: 0.15)) {
                    proxy.scrollTo("transcript-tail", anchor: .bottom)
                }
            }
        }
    }

    // MARK: Controls

    private var controlsRow: some View {
        HStack(spacing: 0) {
            // Slot 1 — Pause / Resume
            Button {
                if recorder.isPaused {
                    recorder.resume()
                } else {
                    recorder.pause()
                }
            } label: {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.inkTextPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isPaused ? "Resume" : "Pause")
            .frame(maxWidth: .infinity)

            // Slot 2 — Stop (brand accent, confirms first)
            Button {
                showStopConfirm = true
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.brandAccent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End lecture")
            .frame(maxWidth: .infinity)

            // Slot 3 — reserved for Pass B (summary regenerate /
            // expand transcript controls). Empty placeholder so the
            // layout doesn't shift when Pass B lands.
            Color.clear
                .frame(width: 44, height: 44)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 18)
    }

    private var ghostCharacter: Character {
        let trimmed = recorder.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed.first ?? "l"
    }
}
