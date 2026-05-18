import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AudioFilePicker

/// Presents a UIDocumentPickerViewController for audio files.
/// Selected files are copied into the notebook's audio directory and inserted as annotations.
struct AudioFilePicker: UIViewControllerRepresentable {

    let viewModel: EditorViewModel
    let onDismiss: () -> Void

    private static let supportedTypes: [UTType] = [
        .audio, .mp3,
        UTType(filenameExtension: "m4a") ?? .audio,
        UTType(filenameExtension: "wav") ?? .audio,
        UTType(filenameExtension: "aac") ?? .audio,
    ]

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel, onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = Array(Set(Self.supportedTypes))
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIDocumentPickerDelegate {

        let viewModel: EditorViewModel
        let onDismiss: () -> Void

        init(viewModel: EditorViewModel, onDismiss: @escaping () -> Void) {
            self.viewModel = viewModel
            self.onDismiss = onDismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onDismiss(); return }
            Task {
                await handlePickedAudioFile(url)
                onDismiss()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss()
        }

        // MARK: - File handling

        private func handlePickedAudioFile(_ sourceURL: URL) async {
            guard sourceURL.startAccessingSecurityScopedResource() else { return }
            defer { sourceURL.stopAccessingSecurityScopedResource() }

            await MainActor.run { viewModel.recordingState = .processing }

            let annotationId = UUID()
            // Imported audio files land in the unified `MediaStorage.audio/`
            // tree alongside fresh recordings. See
            // `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.B.
            let destURL = MediaStorage.url(for: .audio, id: annotationId)

            do {
                MediaStorage.ensureDirectoriesExist()

                // If not M4A, transcode via AVAssetExportSession
                if sourceURL.pathExtension.lowercased() == "m4a" {
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                } else {
                    try await transcode(from: sourceURL, to: destURL)
                }

                let duration = try await audioDuration(at: destURL)
                let pinPoint = CGPoint(x: 0.1, y: 0.1)

                // Insert on the main actor and surface only the
                // record id (Sendable UUID) — `AudioRecord` is a
                // SwiftData persistent model and not Sendable, so we
                // can't return it across the actor boundary. Phase
                // 5A+5C Step 3: `fileName` / `fileSizeBytes` no
                // longer stored on the record.
                // Step 5: V6 commit path. `insertAudioFile` creates
                // a `PageElement(.audio)` + `AudioContent` via the
                // shared `AudioElementCommit` helper. `pinPoint` is
                // no longer plumbed through — the commit helper
                // applies a top-left default; the user can drag the
                // strip after insert via cursor mode.
                await MainActor.run {
                    viewModel.insertAudioFile(
                        recordId: annotationId,
                        duration: duration
                    )
                    viewModel.recordingState = .idle
                }

                // Background transcription writes the result onto
                // the AudioContent row keyed by `annotationId` via
                // `AudioElementCommit.updateTranscript` (called
                // inside SpeechTranscriber).
                let shouldTranscribe = await MainActor.run { viewModel.isTranscriptionEnabled }
                if shouldTranscribe {
                    let capturedURL = destURL
                    Task.detached(priority: .utility) {
                        await SpeechTranscriber.shared.transcribe(url: capturedURL, annotationId: annotationId)
                    }
                }
            } catch {
                await MainActor.run {
                    viewModel.mediaError = "Could not import audio: \(AppError.humanize(error))"
                    viewModel.recordingState = .idle
                }
            }
        }

        // MARK: - Transcode to M4A

        private func transcode(from sourceURL: URL, to destURL: URL) async throws {
            let asset    = AVURLAsset(url: sourceURL)
            let session  = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
            guard let session else { throw CocoaError(.fileWriteUnknown) }
            session.outputURL      = destURL
            session.outputFileType = .m4a
            await session.export()
            if let error = session.error { throw error }
        }

        // MARK: - Duration

        private func audioDuration(at url: URL) async throws -> Double {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        }
    }
}
