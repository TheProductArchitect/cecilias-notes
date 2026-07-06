import SwiftUI

/// Mac lecture overlay — long-form recording + live transcript via
/// the shared `LectureRecorder`. Keyboard-first: Return stops, Esc cancels.
struct MacLectureRecordingView: View {
    let page: Page
    let notebook: Notebook
    @ObservedObject var recorder: LectureRecorder
    let onFinished: () -> Void
    let onCancel: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("lecture")
                    .font(.system(size: 8, weight: .regular))
                    .tracking(0.12)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.recessiveTertiary)
                Spacer()
                Text(formatElapsed(recorder.elapsedSeconds))
                    .font(.system(size: 11).italic())
                    .foregroundStyle(theme.recessiveSecondary)
            }

            TextField("title", text: $recorder.title)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .heavy))

            ScrollView {
                Text(recorder.liveTranscript.isEmpty ? "listening…" : recorder.liveTranscript)
                    .font(.system(size: 13).italic())
                    .foregroundStyle(
                        recorder.liveTranscript.isEmpty
                            ? theme.recessiveQuaternary
                            : theme.foreground
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 160)

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button(recorder.isPaused ? "Resume" : "Pause") {
                    if recorder.isPaused { recorder.resume() }
                    else { recorder.pause() }
                }
                Button("Stop & Save") {
                    Task { @MainActor in await stopAndCommit() }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .frame(width: 420, height: 360)
        .background(theme.surfaceElevated)
    }

    private func stopAndCommit() async {
        guard let result = await recorder.stop() else {
            onCancel()
            return
        }
        let pageSize = page.pageSize.pointSize
        _ = AudioElementCommit.commit(
            contentId: result.recordId,
            pageId: page.id,
            notebookId: notebook.id,
            pageSize: pageSize,
            durationSeconds: result.durationSeconds,
            transcript: result.transcript
        )
        if !result.transcript.isEmpty {
            _ = TextElementCommit.create(
                text: result.transcript,
                source: .typed,
                pageId: page.id,
                notebookId: notebook.id,
                normalizedRect: CGRect(x: 0.08, y: 0.22, width: 0.84, height: 0.45)
            )
        }
        onFinished()
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
