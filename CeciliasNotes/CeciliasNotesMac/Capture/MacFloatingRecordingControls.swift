import SwiftUI

/// Right-edge recording cluster — floats above page chrome.
/// Voice-memo uses this fully; live transcription prefers the
/// in-page chrome but still mounts the summary toggle here so it
/// matches iPad's always-reachable "Summary on/off" chip.
struct MacFloatingRecordingControls: View {
    @ObservedObject var session: MacRecordingSession = .shared
    @Environment(\.theme) private var theme
    var topInset: CGFloat = 68
    @State private var pulsing = false
    @AppStorage("ceciliasnotes.dictation.autoSummary") private var summaryOn: Bool = true

    var body: some View {
        if session.mode.isActive {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 12) {
                    if !session.mode.isTranscribing {
                        timerPill
                    }
                    if session.mode.isTranscribing, MeetingSummarizer.canRun {
                        summaryChip
                    }
                    if !session.mode.isTranscribing {
                        stopButton
                    }
                }
                .padding(.trailing, 20)
                .padding(.top, topInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: session.mode.isActive)
            .zIndex(90)
            .allowsHitTesting(true)
        }
    }

    /// Same affordance as iPad `FloatingRecordingControls.summaryChip`
    /// — toggle whether this dictation gets an AI summary on stop.
    private var summaryChip: some View {
        Button {
            summaryOn.toggle()
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
            .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .macSuppressFocusRing()
        .accessibilityLabel(summaryOn ? "Summary on. Click to turn off." : "Summary off. Click to turn on.")
    }

    private var timerPill: some View {
        Button {
            if let pageId = session.mode.pageId {
                NotificationCenter.default.post(
                    name: .macScrollToRecordingPage,
                    object: nil,
                    userInfo: [MacHandoff.pageIdKey: pageId]
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulsing ? 1.15 : 0.9)
                        .animation(
                            .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                            value: pulsing
                        )
                    if session.mode.isTranscribing {
                        Text("transcribing")
                            .font(.system(size: 9, weight: .medium))
                            .tracking(0.08)
                            .textCase(.uppercase)
                            .foregroundStyle(theme.foregroundMuted)
                    }
                    Text(formatElapsed(session.elapsedSeconds))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.foreground)
                }
                if session.mode.isTranscribing, !session.liveTranscript.isEmpty {
                    Text(session.liveTranscript)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foregroundMuted)
                        .lineLimit(3)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .onAppear { pulsing = true }
        .accessibilityLabel("Jump to recording page")
    }

    private var stopButton: some View {
        Button {
            Task { await session.stop() }
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

    private func formatElapsed(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Notification.Name {
    static let macScrollToRecordingPage = Notification.Name("app.ceciliasnotes.mac.scrollToRecordingPage")
}
