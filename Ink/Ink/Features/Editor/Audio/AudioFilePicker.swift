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
            let destURL = await MainActor.run {
                viewModel.audioDirURL().appendingPathComponent(annotationId.uuidString + ".m4a")
            }

            do {
                try FileManager.default.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                // If not M4A, transcode via AVAssetExportSession
                if sourceURL.pathExtension.lowercased() == "m4a" {
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                } else {
                    try await transcode(from: sourceURL, to: destURL)
                }

                let duration = try await audioDuration(at: destURL)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
                let pinPoint = CGPoint(x: 0.1, y: 0.1)

                // Insert on the main actor and surface only the
                // notebook-id (Sendable UUID) — `AudioAnnotation` is a
                // SwiftData persistent model and not Sendable, so we
                // can't return it across the actor boundary.
                let inserted: UUID? = await MainActor.run {
                    viewModel.insertAudioFile(
                        annotationId: annotationId,
                        fileName: annotationId.uuidString + ".m4a",
                        duration: duration,
                        fileSizeBytes: fileSize,
                        at: pinPoint
                    )?.id
                }

                await MainActor.run {
                    viewModel.recordingState = .idle
                }
                guard let insertedId = inserted else { return }

                // Background transcription
                let shouldTranscribe = await MainActor.run { viewModel.isTranscriptionEnabled }
                if shouldTranscribe {
                    let capturedURL = destURL
                    let capturedId  = insertedId
                    Task.detached(priority: .utility) { [weak viewModel] in
                        await SpeechTranscriber.shared.transcribe(url: capturedURL, annotationId: capturedId)
                        await MainActor.run { [weak viewModel] in
                            viewModel?.refreshCurrentPageAudioAnnotations()
                        }
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
