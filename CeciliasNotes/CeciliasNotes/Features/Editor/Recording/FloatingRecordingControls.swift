import SwiftUI

/// Editor-overlay cluster shown while `RecordingSession.shared`
/// has an active recording. Architecture §6.5 / §9: floats above
/// page content at viewport-fixed coordinates (doesn't scale with
/// zoom or move with scroll), positioned at the right edge so the
/// user can keep working / annotating on the page while keeping the
/// stop control reachable.
///
/// Two stacked pills:
///   • Timer pill — pulsing red dot + monospaced MM:SS elapsed.
///   • Stop button — large accent circle with stop icon.
///
/// Both Voice Note and Dictation render the same controls — the
/// session's `state` determines what `stop()` does behind the
/// scenes (voice note finalizes inline strip vs dictation commits
/// the paired audio + transcript block).
struct FloatingRecordingControls: View {

    @ObservedObject var session: RecordingSession = .shared
    @Environment(\.theme) private var theme
    // Bound directly to the persisted preference (not a one-shot
    // @State) so the chip always reflects — and remembers — the last
    // choice across dictations and stays in sync with Settings.
    @AppStorage(DictationSummaryPreference.key) private var summaryOn: Bool = true

    var body: some View {
        if session.state.isRecording {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    timerPill
                    if session.state.isDictation && MeetingSummarizer.canRun {
                        summaryChip
                    }
                    stopButton
                }
                .padding(.trailing, 20)
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: session.state.isRecording)
        }
    }

    // MARK: - Summary chip (dictation only)

    /// Floating "flag" that lets the user choose whether this
    /// dictation gets an AI summary on stop — without leaving the
    /// page. Reflects and writes `DictationSummaryPreference` (also
    /// in Settings → Audio & Transcription), so the choice sticks as
    /// the new default. Only shown when Apple Intelligence can run.
    private var summaryChip: some View {
        Button {
            // @AppStorage write IS the persistence — toggling stores
            // the new value under DictationSummaryPreference.key.
            summaryOn.toggle()
            HapticManager.shared.toolSwitched()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: summaryOn ? "sparkles" : "sparkles.slash")
                    .font(.system(size: 12, weight: .semibold))
                Text(summaryOn ? "Summary on" : "Summary off")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(summaryOn ? theme.accent : theme.foregroundMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(theme.borderSubtle, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summaryOn ? "Summary on. Tap to turn off." : "Summary off. Tap to turn on.")
    }

    // MARK: - Timer pill

    private var timerPill: some View {
        // Tap the timer to jump back to the page the recording is
        // writing to. Useful for dictation: the user may have
        // scrolled away while the recorder rolled onto a
        // continuation page, and the live transcript ends up out of
        // sight. Stays a button even when the active page is the
        // current one (no-op then) so the affordance is stable.
        Button {
            if let pageId = session.state.pageId {
                NotificationCenter.default.post(
                    name: .recordingScrollToActivePage,
                    object: nil,
                    userInfo: ["pageId": pageId]
                )
                HapticManager.shared.toolSwitched()
            }
        } label: {
            HStack(spacing: 8) {
                recordingDot
                Text(formatElapsed(session.elapsedSeconds))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.foreground)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule()
                    .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to active recording page")
    }

    private var recordingDot: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            // Pulse — universal recording metaphor per architecture
            // §17 ("Recording-state red is hardcoded Color.red").
            .opacity(0.95)
            .scaleEffect(pulsing ? 1.15 : 0.95)
            .animation(
                .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
            .onDisappear { pulsing = false }
    }

    @State private var pulsing: Bool = false

    // MARK: - Stop button

    private var stopButton: some View {
        Button {
            Task { await session.stop() }
            HapticManager.shared.destructiveConfirmed()
        } label: {
            ZStack {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 52, height: 52)
                Image(systemName: "stop.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
    }

    // MARK: - Helpers

    private func formatElapsed(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
