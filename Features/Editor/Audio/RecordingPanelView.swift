import Speech
import SwiftUI

// MARK: - RecordingPanelView

/// Bottom overlay (180pt tall) that hosts the entire record / stop / processing flow.
/// Presented as a ZStack layer in EditorView — NOT a sheet.
struct RecordingPanelView: View {

    @ObservedObject var viewModel: EditorViewModel

    // MARK: - State

    @State private var elapsedSeconds:    Double  = 0
    @State private var liveLevels:        [Float] = []
    @State private var elapsedTimer:      Timer?
    @State private var transcribeEnabled: Bool    = false

    private let panelHeight: CGFloat = 180

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            panel
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear { checkTranscriptionAvailability() }
        .task(id: viewModel.isRecordingPanelVisible) {
            if viewModel.isRecordingPanelVisible {
                await collectLevels()
            }
        }
    }

    // MARK: - Panel layout

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.recordingState {
        case .idle:       idleContent
        case .recording:  recordingContent
        case .processing: processingContent
        }
    }

    private var panel: some View {
        VStack(spacing: Ink.Spacing.md) {
            stateContent
        }
        .padding(.horizontal, Ink.Spacing.lg)
        .padding(.top, Ink.Spacing.lg)
        .padding(.bottom, Ink.Spacing.xl)
        .frame(maxWidth: .infinity)
        .frame(height: panelHeight)
        .background(
            RoundedRectangle(cornerRadius: Ink.Radius.lg, style: .continuous)
                .fill(Color.inkBackgroundElevated)
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: -2)
        )
    }

    // MARK: - Idle state

    private var idleContent: some View {
        VStack(spacing: Ink.Spacing.sm) {
            Text("Record Audio")
                .font(.inkHeadline)
                .foregroundColor(.inkTextPrimary)

            HStack(spacing: Ink.Spacing.lg) {
                if transcribeEnabled {
                    Toggle(isOn: $viewModel.isTranscriptionEnabled) {
                        Text("Transcribe")
                            .font(.inkBody)
                            .foregroundColor(.inkTextSecondary)
                    }
                    .toggleStyle(.switch)
                    .tint(.inkAccentPrimary)
                }

                Spacer()

                Button {
                    viewModel.isShowingAudioFilePicker = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.inkTextSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                Button {
                    Task { await viewModel.startRecording() }
                } label: {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 56, height: 56)
                        .overlay(
                            Image(systemName: "mic.fill")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundColor(.white)
                        )
                }
                .buttonStyle(.plain)
            }

            Button { dismiss() } label: {
                Text("Cancel")
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextTertiary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Recording state

    private var recordingContent: some View {
        VStack(spacing: Ink.Spacing.sm) {
            HStack {
                Text(formatElapsed(elapsedSeconds))
                    .font(.inkMono)
                    .foregroundColor(.inkTextPrimary)
                    .monospacedDigit()

                Spacer()

                Button {
                    Task { await viewModel.stopRecording() }
                } label: {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "stop.fill")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.white)
                        )
                }
                .buttonStyle(.plain)
            }

            WaveformView(mode: .live(levels: liveLevels))
                .frame(height: 60)
        }
        .onAppear { startElapsedTimer() }
        .onDisappear { stopElapsedTimer() }
    }

    // MARK: - Processing state

    private var processingContent: some View {
        VStack(spacing: Ink.Spacing.md) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.inkAccentPrimary)

            Text("Processing…")
                .font(.inkBody)
                .foregroundColor(.inkTextSecondary)
        }
    }

    // MARK: - Level collection

    private func collectLevels() async {
        liveLevels = []
        for await level in await viewModel.audioLevelStream() {
            liveLevels.append(level)
            if liveLevels.count > 200 { liveLevels.removeFirst() }
        }
    }

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        elapsedSeconds = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            elapsedSeconds += 0.1
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer   = nil
        elapsedSeconds = 0
    }

    private func formatElapsed(_ t: Double) -> String {
        let minutes = Int(t) / 60
        let seconds = Int(t) % 60
        let tenths  = Int(t * 10) % 10
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    // MARK: - Helpers

    private func dismiss() {
        withAnimation(.inkSpring(InkSpring.smooth)) {
            viewModel.isRecordingPanelVisible = false
        }
    }

    private func checkTranscriptionAvailability() {
        let currentLocale = SFSpeechRecognizer(locale: .current)?.supportsOnDeviceRecognition == true
        let enUSLocale    = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition == true
        transcribeEnabled = currentLocale || enUSLocale
    }
}
