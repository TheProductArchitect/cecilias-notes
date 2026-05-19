import Accelerate
import AVFoundation
import Foundation

// MARK: - AudioRecorderError

enum AudioRecorderError: Error, LocalizedError {
    case permissionDenied
    case engineFailed(Error)
    case notRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:    return "Microphone access denied. Enable it in Settings."
        case .engineFailed(let e): return "Audio engine error: \(e.localizedDescription)"
        case .notRecording:        return "No active recording."
        }
    }
}

// MARK: - AudioRecorder

/// Records microphone input to M4A/AAC using AVAudioEngine + AVAudioFile.
/// A PCM tap on the input node provides real-time RMS levels for the live waveform
/// and feeds PCM buffers to SpeechTranscriber for live transcription.
///
/// **On-device only.** Zero network traffic.
actor AudioRecorder {

    // MARK: - Public

    /// Emits RMS amplitude values (0…1) during recording for the live waveform.
    private(set) var levelStream: AsyncStream<Float>?
    private var levelContinuation: AsyncStream<Float>.Continuation?

    // MARK: - Private

    private var engine:      AVAudioEngine?
    private var audioFile:   AVAudioFile?
    private var startTime:   Date?
    private var outputURL:   URL?

    private static let tapBufferSize: AVAudioFrameCount = 4_096

    #if DEBUG
    deinit {
        print("[AudioLife] AudioRecorder deinit \(ObjectIdentifier(self)) engine=\(engine == nil ? "nil" : "live")")
    }
    #endif

    // MARK: - Permission

    func requestPermission() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw AudioRecorderError.permissionDenied }
    }

    // MARK: - Recording lifecycle

    func start(outputURL: URL) async throws {
        #if DEBUG
        print("[Audio] 1. start() called, outputURL=\(outputURL.lastPathComponent)")
        print("[AudioLife] start() entry on actor AudioRecorder, recorder=\(ObjectIdentifier(self))")
        #endif
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #if DEBUG
        print("[Audio] 2. AVAudioSession active, category=\(session.category.rawValue) sampleRate=\(session.sampleRate)")
        #endif

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        #if DEBUG
        print("[Audio] 3. inputNode native format: sr=\(nativeFormat.sampleRate) channels=\(nativeFormat.channelCount)")
        #endif

        // AAC settings — must match the input node's actual channel
        // count + sample rate, OR the encoder rejects the
        // (sample rate, channel count, bit rate) combination at
        // file-write time with `kAudioConverterEncodeBitRate 'fmt?'`
        // and the recording silently fails (no waveform, no
        // transcription). Letting the encoder pick its own bit
        // rate via `AVEncoderAudioQualityKey` avoids that whole
        // class of mismatch.
        let aacSettings: [String: Any] = [
            AVFormatIDKey:            Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:          nativeFormat.sampleRate,
            AVNumberOfChannelsKey:    Int(nativeFormat.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: outputURL, settings: aacSettings)

        // Level stream
        let (stream, continuation) = AsyncStream<Float>.makeStream()
        levelStream       = stream
        levelContinuation = continuation

        // Capture continuation separately so we can yield without an actor hop.
        let cont = levelContinuation

        // Defensive tap teardown before re-installing — a previous
        // session that didn't `stop()` cleanly (force-quit, crash
        // recovery) would leave a tap that throws on re-install.
        inputNode.removeTap(onBus: 0)
        #if DEBUG
        // Tap-fire counter for the diagnostic. First call and every
        // 50th thereafter print so we can confirm the closure is
        // actually being invoked. The #1 print is the critical signal:
        // if it never appears, the mic is not delivering buffers.
        nonisolated(unsafe) var tapFireCount = 0
        #endif
        inputNode.installTap(
            onBus:        0,
            bufferSize:   Self.tapBufferSize,
            format:       nativeFormat
        ) { buffer, _ in
            #if DEBUG
            tapFireCount += 1
            if tapFireCount == 1 || tapFireCount % 50 == 0 {
                let rmsValue = Self.rms(buffer: buffer)
                print("[Audio] tap fired #\(tapFireCount), samples=\(buffer.frameLength), rms=\(String(format: "%.4f", rmsValue))")
                cont?.yield(rmsValue)
            } else {
                cont?.yield(Self.rms(buffer: buffer))
            }
            #else
            // RMS — yields directly, no actor hop needed for AsyncStream.
            cont?.yield(Self.rms(buffer: buffer))
            #endif

            // File write — synchronous. The tap is serial so no concurrent access.
            try? file.write(from: buffer)
        }
        #if DEBUG
        print("[Audio] 4. tap installed, bufferSize=\(Self.tapBufferSize)")
        print("[Audio] 4a. inputNode numberOfInputs=\(inputNode.numberOfInputs) outputFormat(bus0)=\(inputNode.outputFormat(forBus: 0))")
        #endif

        // `reset()` clears any stale node state from a previous
        // session (e.g. cached buffers, half-initialised connections)
        // so the imminent `start()` runs against a clean engine.
        eng.reset()
        // Explicit do/catch — the previous `try?` swallowed the
        // error and left the recorder in a half-started state
        // (file open, tap installed, engine NOT running), which
        // manifests as the "no waveform, no transcript" bug because
        // no audio ever flows.
        do {
            try eng.start()
            #if DEBUG
            print("[Audio] 5. engine.start() OK, isRunning=\(eng.isRunning)")
            // Verify the engine stays running for at least a beat —
            // some session-state misconfigurations let `start()`
            // succeed but the engine pauses itself a few ms later.
            // The delayed check lets us see whether the engine is
            // still live by the time we'd expect the first tap fire.
            Task { [weak eng] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let eng else { return }
                print("[Audio] 5b. engine.isRunning after 500ms = \(eng.isRunning)")
            }
            print("[Audio] 5a. AudioRecorder uses POST-RECORDING file transcription, " +
                  "not live SpeechTranscriber.startLive(). For quick-record, transcription " +
                  "fires from EditorViewModel.stopRecording after the m4a file is saved " +
                  "(see `SpeechTranscriber.transcribe(url:annotationId:)`).")
            #endif
        } catch {
            #if DEBUG
            print("[AudioRecorder] engine.start() failed: \(error)")
            #endif
            // Roll back the partial state so the recorder is in a
            // known-stopped condition. The thrown error surfaces
            // to the caller, which shows the error banner.
            inputNode.removeTap(onBus: 0)
            levelContinuation?.finish()
            levelContinuation = nil
            levelStream       = nil
            throw AudioRecorderError.engineFailed(error)
        }

        engine    = eng
        audioFile = file
        startTime = Date()
        self.outputURL = outputURL
        #if DEBUG
        print("[AudioLife] start() exit — engine instance \(ObjectIdentifier(eng)) retained on actor")
        #endif
    }

    func stop() async throws -> (duration: Double, fileSizeBytes: Int64) {
        #if DEBUG
        let stack = Thread.callStackSymbols.prefix(8).joined(separator: "\n  ")
        print("[AudioLife] stop() called on actor AudioRecorder \(ObjectIdentifier(self))")
        print("[AudioLife]   call stack:\n  \(stack)")
        #endif
        guard let eng = engine, let start = startTime, let url = outputURL
        else {
            #if DEBUG
            print("[AudioLife] stop() guard tripped — engine=\(engine == nil ? "nil" : "live") startTime=\(startTime == nil ? "nil" : "live") outputURL=\(outputURL == nil ? "nil" : "live")")
            #endif
            throw AudioRecorderError.notRecording
        }
        #if DEBUG
        print("[AudioLife] tap removed, engine stopping (engine instance \(ObjectIdentifier(eng)) isRunning=\(eng.isRunning))")
        #endif

        eng.inputNode.removeTap(onBus: 0)
        eng.stop()
        engine    = nil
        audioFile = nil   // closing the AVAudioFile flushes and finalises it

        levelContinuation?.finish()
        levelContinuation = nil

        let duration = Date().timeIntervalSince(start)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        startTime  = nil
        outputURL  = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #if DEBUG
            print("[Audio] session deactivated on stop")
            #endif
        } catch {
            #if DEBUG
            print("[Audio] failed to deactivate session on stop: \(error)")
            #endif
        }
        return (duration: duration, fileSizeBytes: fileSize)
    }

    // MARK: - RMS via vDSP

    static func rms(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, frameCount)
        return min(rms * 10, 1.0)
    }
}
