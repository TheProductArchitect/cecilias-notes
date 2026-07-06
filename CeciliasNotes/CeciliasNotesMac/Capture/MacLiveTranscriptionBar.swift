import SwiftUI

/// Meeting-style live transcript panel — docked under the header so
/// words appear immediately while the page block updates in parallel.
struct MacLiveTranscriptionBar: View {
    @ObservedObject var session: MacRecordingSession = .shared
    @Environment(\.theme) private var theme
    @State private var pulsing = false

    var body: some View {
        if session.mode.isTranscribing {
            VStack(alignment: .leading, spacing: 8) {
                headerRow
                transcriptBody
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfaceElevated)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .scaleEffect(pulsing ? 1.15 : 0.92)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }

            Text("live transcription")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.1)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveTertiary)

            Text(formatElapsed(session.elapsedSeconds))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.foregroundMuted)

            Spacer(minLength: 8)

            Button {
                var userInfo: [AnyHashable: Any] = [:]
                if let pageId = session.mode.pageId {
                    userInfo[MacHandoff.pageIdKey] = pageId
                }
                if let elementId = session.mode.textElementId {
                    userInfo[MacTranscriptionKeys.elementId] = elementId
                }
                NotificationCenter.default.post(
                    name: .macScrollToRecordingPage,
                    object: nil,
                    userInfo: userInfo
                )
            } label: {
                Text("show on page")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)

            Button {
                Task { await session.stop() }
            } label: {
                Text("stop")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.accent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private var transcriptBody: some View {
        ScrollView {
            Text(displayTranscript)
                .font(.system(size: 14))
                .foregroundStyle(session.liveTranscript.isEmpty ? theme.recessiveTertiary : theme.foreground)
                .italic(session.liveTranscript.isEmpty)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 140)
    }

    private var displayTranscript: String {
        session.liveTranscript.isEmpty
            ? "Listening… speak naturally and your notes will appear here."
            : session.liveTranscript
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
