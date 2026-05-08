import Accelerate
import AVFoundation
import Foundation
import Speech

// MARK: - SpeechTranscriber

/// On-device speech recognition. Zero network calls — always.
///
/// - `requiresOnDeviceRecognition = true` on every request.
/// - If the recognizer does not support on-device recognition the transcription
///   is skipped silently; `isTranscribed` stays `false`.
actor SpeechTranscriber {

    static let shared = SpeechTranscriber()

    // MARK: - Live transcription

    private var liveRequest:      SFSpeechAudioBufferRecognitionRequest?
    private var liveContinuation: AsyncStream<String>.Continuation?

    /// Returns an `AsyncStream<String>` of partial hypotheses emitted as the user speaks.
    /// Append PCM buffers via `appendBuffer(_:)`. Call `finishLive()` when recording stops.
    func startLive() async -> AsyncStream<String> {
        guard await requestSpeechPermission(),
              let recognizer = makeSupportedRecognizer()
        else { return AsyncStream { $0.finish() } }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults   = true
        request.requiresOnDeviceRecognition  = true     // CRITICAL: no network
        request.taskHint                     = Self.currentTaskHint()
        liveRequest = request

        let (stream, continuation) = AsyncStream<String>.makeStream()
        liveContinuation = continuation

        recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { await self.yieldLive(result.bestTranscription.formattedString) }
            }
            if error != nil || result?.isFinal == true {
                Task { await self.finishLive() }
            }
        }
        return stream
    }

    private func yieldLive(_ text: String) {
        liveContinuation?.yield(text)
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        liveRequest?.append(buffer)
    }

    func finishLive() {
        liveRequest?.endAudio()
        liveRequest      = nil
        liveContinuation?.finish()
        liveContinuation = nil
    }

    // MARK: - Post-recording file transcription

    /// Transcribes an M4A file then persists the result and amplitude data.
    /// Takes annotation `id` (not the model) to avoid cross-actor SwiftData access.
    /// All StorageService calls are dispatched back to the main actor.
    func transcribe(url: URL, annotationId: UUID) async {
        // 1. Amplitude extraction — no speech permission needed
        let amplitudes = await extractAmplitudes(from: url)
        if !amplitudes.isEmpty {
            let data = try? JSONEncoder().encode(amplitudes)
            await MainActor.run {
                if let annotation = StorageService.shared.fetchAudioAnnotation(id: annotationId) {
                    try? StorageService.shared.updateAmplitudeData(annotation, amplitudeData: data)
                }
            }
        }

        // 2. Speech recognition — on-device only
        guard await requestSpeechPermission(),
              let recognizer = makeSupportedRecognizer()
        else { return }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults  = false
        request.requiresOnDeviceRecognition = true      // CRITICAL: no network
        request.taskHint                    = Self.currentTaskHint()

        let transcriptionResult: (text: String, segments: [TranscriptionSegment])? =
            await withCheckedContinuation { cont in
                recognizer.recognitionTask(with: request) { result, error in
                    guard let result, result.isFinal else {
                        if error != nil { cont.resume(returning: nil) }
                        return
                    }
                    let text = result.bestTranscription.formattedString
                    let segs = result.bestTranscription.segments.map {
                        TranscriptionSegment(
                            word:       $0.substring,
                            startTime:  $0.timestamp,
                            endTime:    $0.timestamp + $0.duration,
                            confidence: $0.confidence
                        )
                    }
                    cont.resume(returning: (text: text, segments: segs))
                }
            }

        guard let result = transcriptionResult else { return }

        await MainActor.run {
            if let annotation = StorageService.shared.fetchAudioAnnotation(id: annotationId) {
                try? StorageService.shared.updateTranscription(
                    annotation,
                    text: result.text,
                    segments: result.segments
                )
            }
        }
    }

    // MARK: - Helpers

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    private func makeSupportedRecognizer() -> SFSpeechRecognizer? {
        // 1. User-chosen locale from Settings (Audio & Transcription).
        let chosen = UserDefaults.standard.string(forKey: "ink.transcription.locale") ?? ""
        if !chosen.isEmpty,
           let r = SFSpeechRecognizer(locale: Locale(identifier: chosen)),
           r.supportsOnDeviceRecognition {
            return r
        }
        // 2. System current locale.
        if let r = SFSpeechRecognizer(locale: .current), r.supportsOnDeviceRecognition {
            return r
        }
        // 3. Fallback to en-US.
        if let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
           r.supportsOnDeviceRecognition {
            return r
        }
        return nil
    }

    /// Reads the user's `ink.transcription.quality` setting and maps it to
    /// `SFSpeechRecognitionTaskHint`. Default is `.dictation`.
    private static func currentTaskHint() -> SFSpeechRecognitionTaskHint {
        let raw = UserDefaults.standard.string(forKey: "ink.transcription.quality") ?? "fast"
        return raw == "fast" ? .search : .dictation
    }

    // MARK: - Amplitude extraction

    private func extractAmplitudes(from url: URL) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        guard let tracks = try? await asset.load(.tracks),
              let track = tracks.first(where: { $0.mediaType == .audio })
        else { return [] }

        let settings: [String: Any] = [
            AVFormatIDKey:              Int(kAudioFormatLinearPCM),
            AVSampleRateKey:            44_100,
            AVNumberOfChannelsKey:      1,
            AVLinearPCMBitDepthKey:     32,
            AVLinearPCMIsFloatKey:      true,
            AVLinearPCMIsBigEndianKey:  false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.startReading()

        let windowSize = 44_100 / 20   // 50ms at 44.1kHz
        var buffer:     [Float] = []
        var amplitudes: [Float] = []

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer(),
                  let blockBuffer  = CMSampleBufferGetDataBuffer(sampleBuffer)
            else { break }

            let length = CMBlockBufferGetDataLength(blockBuffer)
            var raw    = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &raw)

            let samples: [Float] = raw.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return [] }
                let floatPtr = base.assumingMemoryBound(to: Float.self)
                return Array(UnsafeBufferPointer(start: floatPtr, count: length / MemoryLayout<Float>.size))
            }
            buffer.append(contentsOf: samples)

            while buffer.count >= windowSize {
                let window = Array(buffer.prefix(windowSize))
                buffer.removeFirst(windowSize)
                var rms: Float = 0
                vDSP_rmsqv(window, 1, &rms, vDSP_Length(windowSize))
                amplitudes.append(min(rms * 10, 1.0))
            }
        }
        return amplitudes
    }
}
