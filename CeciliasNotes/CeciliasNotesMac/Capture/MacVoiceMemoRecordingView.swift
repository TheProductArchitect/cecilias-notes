import SwiftUI

/// Short voice memo — records to an inline audio strip on the page.
struct MacVoiceMemoRecordingView: View {
    let page: Page
    let notebook: Notebook
    let onFinished: () -> Void
    let onCancel: () -> Void
    @Environment(\.theme) private var theme

    @State private var recorder: AudioRecorder?
    @State private var contentId = UUID()
    @State private var elapsedSeconds: Double = 0
    @State private var elapsedTimer: Timer?
    @State private var recordingAnchor: Date?
    @State private var errorMessage: String?
    @State private var isPreparing = false
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("voice memo")
                    .font(.system(size: 8, weight: .regular))
                    .tracking(0.12)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.recessiveTertiary)
                Spacer()
                if isRecording {
                    MacRecordingPulseDot()
                        .frame(width: 10, height: 10)
                    Text(formatElapsed(elapsedSeconds))
                        .font(.system(size: 11).italic())
                        .foregroundStyle(theme.recessiveSecondary)
                }
            }

            if isRecording {
                Text("recording on this page — stop to save the clip.")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(theme.recessiveQuaternary)
            } else if isPreparing {
                Text("preparing microphone…")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(theme.recessiveQuaternary)
            } else {
                Text("tap start, then speak. your clip saves to this page.")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(theme.recessiveQuaternary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.danger)
            }

            HStack {
                Button("Cancel", role: .cancel) { cancelRecording() }
                Spacer()
                if isRecording {
                    Button("Stop & Save") {
                        Task { @MainActor in await stopAndCommit() }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Button(isPreparing ? "Preparing…" : "Start Recording") {
                        Task { @MainActor in await startRecordingFlow() }
                    }
                    .disabled(isPreparing)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(24)
        .frame(width: 360, height: 180)
        .background(theme.surfaceElevated)
        .onDisappear {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }
    }

    private func startRecordingFlow() async {
        guard recorder == nil, !isPreparing else { return }
        isPreparing = true
        errorMessage = nil
        contentId = UUID()
        MediaStorage.ensureDirectoriesExist()
        let fileURL = MediaStorage.url(for: .audio, id: contentId)
        let audioRecorder = AudioRecorder()
        do {
            try await audioRecorder.requestPermission()
            // Let AppKit finish dismissing the permission sheet before
            // Core Audio IPC runs — avoids a wedged main runloop.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 250_000_000)
            try await audioRecorder.start(outputURL: fileURL)
        } catch {
            errorMessage = error.localizedDescription
            isPreparing = false
            return
        }
        recorder = audioRecorder
        isPreparing = false
        isRecording = true
        elapsedSeconds = 0
        recordingAnchor = Date()
        startElapsedTimer()
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let anchor = recordingAnchor ?? Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            let elapsed = Date().timeIntervalSince(anchor)
            Task { @MainActor in
                elapsedSeconds = elapsed
            }
        }
    }

    private func cancelRecording() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingAnchor = nil
        Task { @MainActor in
            if let recorder { _ = try? await recorder.stop() }
            self.recorder = nil
            isRecording = false
            isPreparing = false
            onCancel()
        }
    }

    private func stopAndCommit() async {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingAnchor = nil
        guard let recorder else {
            onCancel()
            return
        }
        defer {
            self.recorder = nil
            isRecording = false
        }
        do {
            let result = try await recorder.stop()
            let pageSize = page.pageSize.pointSize
            guard let element = AudioElementCommit.commit(
                contentId: contentId,
                pageId: page.id,
                notebookId: notebook.id,
                pageSize: pageSize,
                durationSeconds: result.duration,
                transcript: ""
            ) else {
                errorMessage = "Couldn't save recording."
                return
            }
            _ = element
            let url = MediaStorage.url(for: .audio, id: contentId)
            Task.detached(priority: .utility) {
                if let result = await SpeechTranscriber.shared.transcribeFile(url: url),
                   !result.text.isEmpty {
                    await MainActor.run {
                        AudioElementCommit.updateTranscript(contentId: contentId, transcript: result.text)
                    }
                }
            }
            onFinished()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct MacRecordingPulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .scaleEffect(reduceMotion ? 1.0 : (pulsing ? 1.15 : 0.85))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { if !reduceMotion { pulsing = true } }
    }
}
