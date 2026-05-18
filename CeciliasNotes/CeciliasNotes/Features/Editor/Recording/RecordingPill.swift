import SwiftUI

/// App-root persistent pill shown while `RecordingSession.shared`
/// has an active recording. Modelled on the iOS Phone app's
/// ongoing-call indicator: top-of-screen pill, always on top of
/// nav and sheets, tap-to-return to where the recording is
/// happening.
///
/// Visibility rule: shown whenever a recording is in flight. The
/// editor's own `FloatingRecordingControls` is the more prominent
/// surface when the user is in the editor — this pill is the
/// secondary surface for everywhere else (library, settings,
/// modal sheets). Showing both is intentional — overlap is brief
/// and harmless; the pill reinforces "recording is live."
///
/// Tap routing: posts `.recordingPillReturnTapped` with the
/// active notebook id. `LibraryViewModel` listens and sets
/// `openNotebookId` on the deep-link router so the editor
/// re-presents. If the editor is already on screen this is a
/// no-op.
struct RecordingPill: View {

    @ObservedObject var session: RecordingSession = .shared
    @Environment(\.theme) private var theme

    var body: some View {
        if session.state.isRecording {
            VStack {
                pillBody
                    .padding(.top, 4)
                    .padding(.horizontal, 16)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: session.state.isRecording)
        }
    }

    private var pillBody: some View {
        HStack(spacing: 10) {
            Button {
                if let notebookId = session.state.notebookId {
                    NotificationCenter.default.post(
                        name: .recordingPillReturnTapped,
                        object: nil,
                        userInfo: ["notebookId": notebookId]
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    RecordingPulseDot()
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(formatElapsed(session.elapsedSeconds))
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return to recording")

            Button {
                Task { await session.stop() }
                HapticManager.shared.destructiveConfirmed()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
            .padding(.trailing, 8)
        }
        .background(
            Capsule()
                .fill(Color.red.opacity(0.95))
        )
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
        .frame(maxWidth: 320)
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Notification.Name {
    /// Posted when the user taps the body of `RecordingPill`
    /// while outside the editor. `userInfo["notebookId"]` carries
    /// the notebook the recording belongs to; `LibraryViewModel`
    /// observes and drives navigation back.
    static let recordingPillReturnTapped = Notification.Name("recordingPillReturnTapped")
}
