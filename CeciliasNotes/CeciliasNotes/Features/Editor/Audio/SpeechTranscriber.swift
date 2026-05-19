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
    private var liveTask:         SFSpeechRecognitionTask?
    private var liveContinuation: AsyncStream<String>.Continuation?

    /// Returns an `AsyncStream<String>` of partial hypotheses emitted as the user speaks.
    /// Append PCM buffers via `appendBuffer(_:)`. Call `finishLive()` when recording stops.
    func startLive() async -> AsyncStream<String> {
        #if DEBUG
        print("[Audio] 6. SpeechTranscriber.startLive() called")
        #endif
        // Unconditional cleanup of any prior session. A leftover
        // `SFSpeechRecognitionTask` holds the recogniser and blocks
        // a new one from connecting — the `handwritingd`-daemon
        // invalidations seen in the console are exactly this
        // contention. Cancel + nil the previous task BEFORE
        // making any new request, even if the task appears finished.
        liveTask?.cancel()
        liveTask = nil
        liveRequest?.endAudio()
        liveRequest = nil
        liveContinuation?.finish()
        liveContinuation = nil

        let permission = await requestSpeechPermission()
        #if DEBUG
        print("[Audio] 7. speech permission granted=\(permission)")
        #endif
        guard permission, let recognizer = makeSupportedRecognizer() else {
            #if DEBUG
            print("[Audio] 7b. no supported recognizer — bailing. permission=\(permission)")
            #endif
            return AsyncStream { $0.finish() }
        }
        #if DEBUG
        print("[Audio] 8. recognizer locale=\(recognizer.locale.identifier) isAvailable=\(recognizer.isAvailable) supportsOnDevice=\(recognizer.supportsOnDeviceRecognition)")
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults   = true
        request.requiresOnDeviceRecognition  = true     // CRITICAL: no network
        request.taskHint                     = Self.currentTaskHint()
        liveRequest = request

        let (stream, continuation) = AsyncStream<String>.makeStream()
        liveContinuation = continuation

        #if DEBUG
        nonisolated(unsafe) var resultCount = 0
        #endif
        liveTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            #if DEBUG
            if let error {
                print("[Audio] recognitionTask error: \(error.localizedDescription)")
            }
            if let result {
                resultCount += 1
                let isFinal = result.isFinal
                let text = result.bestTranscription.formattedString
                if resultCount == 1 || resultCount % 10 == 0 || isFinal {
                    print("[Audio] result #\(resultCount) isFinal=\(isFinal) len=\(text.count) text=\"\(text.prefix(60))\"")
                }
            }
            #endif
            if let result {
                let text = result.bestTranscription.formattedString
                Task { await self.yieldLive(text) }
            }
            if error != nil || result?.isFinal == true {
                Task { await self.finishLive() }
            }
        }
        #if DEBUG
        print("[Audio] 9. recognitionTask started")
        #endif
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
        liveTask?.cancel()
        liveTask         = nil
        liveRequest      = nil
        liveContinuation?.finish()
        liveContinuation = nil
    }

    // MARK: - Post-recording file transcription

    /// Run on-device speech recognition over an M4A file and return
    /// the result without persisting anything. Used by the
    /// transcript-only recording path (Settings: "Save audio clips"
    /// off, "Generate transcripts" on) which discards the audio file
    /// after extracting the transcript.
    func transcribeFile(url: URL) async -> (text: String, segments: [TranscriptionSegment])? {
        guard await requestSpeechPermission(),
              let recognizer = makeSupportedRecognizer()
        else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults  = false
        request.requiresOnDeviceRecognition = true
        request.taskHint                    = Self.currentTaskHint()

        return await withCheckedContinuation { cont in
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
    }

    /// Transcribes an M4A file and writes the transcript onto the
    /// V6 `AudioContent` row keyed by `annotationId`.
    ///
    /// Step 5: dropped the amplitude-extraction write — the V5
    /// `AudioRecord.amplitudes` field is gone and the new
    /// `AudioElementView` strip uses a time-based progress bar
    /// rather than a waveform. Amplitude data can come back when a
    /// real waveform widget ships.
    func transcribe(url: URL, annotationId: UUID) async {
        // Speech recognition — on-device only
        let permission = await requestSpeechPermission()
        guard permission, let recognizer = makeSupportedRecognizer() else { return }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults  = false
        request.requiresOnDeviceRecognition = true      // CRITICAL: no network
        request.taskHint                    = Self.currentTaskHint()

        typealias RecogResult = (text: String, timingMap: TimingMap?)
        let recognitionResult: RecogResult? = await withCheckedContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                if error != nil {
                    cont.resume(returning: nil)
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                let segs = result.bestTranscription.segments
                let words: [TimingMap.Word] = segs.map { seg in
                    TimingMap.Word(
                        text:      seg.substring,
                        startTime: seg.timestamp,
                        endTime:   seg.timestamp + seg.duration,
                        charStart: seg.substringRange.location,
                        charLength: seg.substringRange.length
                    )
                }
                let totalDuration = segs.last.map { $0.timestamp + $0.duration } ?? 0
                let timing = words.isEmpty ? nil : TimingMap(
                    words: words,
                    totalDuration: totalDuration,
                    version: 1
                )
                cont.resume(returning: (text: text, timingMap: timing))
            }
        }
        guard let r = recognitionResult, !r.text.isEmpty else { return }

        await MainActor.run {
            AudioElementCommit.updateTranscript(
                contentId: annotationId,
                transcript: r.text,
                timingMap: r.timingMap
            )
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
