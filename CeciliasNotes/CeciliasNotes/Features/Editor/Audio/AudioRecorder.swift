import Accelerate
@preconcurrency import AVFoundation
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
///
/// **Why `@MainActor final class` and not `actor`.** The original
/// implementation was `actor AudioRecorder`, which put
/// `start()` (including `AVAudioSession.setCategory` /
/// `setActive` and `AVAudioEngine.start()`) on a background
/// executor. Empirically that produced an engine which
/// reported `isRunning=true` but never delivered a single
/// buffer to the input tap — the engine then idled itself out
/// after ~500ms. `LectureRecorder` (which uses the same engine
/// + tap pattern and works) is `@MainActor final class`;
/// matching that isolation runs the session setup + engine
/// start on the main thread where AVFoundation's input
/// routing propagates correctly.
@MainActor
final class AudioRecorder {

    // MARK: - Public

    /// Emits RMS amplitude values (0…1) during recording for the live waveform.
    private(set) var levelStream: AsyncStream<Float>?
    private var levelContinuation: AsyncStream<Float>.Continuation?

    // MARK: - Private

    private var engine:      AVAudioEngine?
    private var audioFile:   AVAudioFile?
    private var startTime:   Date?
    private var outputURL:   URL?

    nonisolated private static let tapBufferSize: AVAudioFrameCount = 4_096

    #if DEBUG
    deinit {
        dlog("[AudioLife] AudioRecorder deinit \(ObjectIdentifier(self))")
    }
    #endif

    // MARK: - Permission

    func requestPermission() async throws {
        // Delivered via a system callback that targets the main queue.
        // When the main runloop is busy (CloudKit import, permission
        // sheets, AVAudioEngine IPC), the callback can queue but stall
        // — the await hangs and the app looks frozen. Detach so the
        // callback resolves on a quiet queue. Mirrors LectureRecorder.
        let granted = await Task.detached(priority: .userInitiated) {
            await AVAudioApplication.requestRecordPermission()
        }.value
        guard granted else { throw AudioRecorderError.permissionDenied }
    }

    // MARK: - Recording lifecycle

    func start(outputURL: URL) async throws {
        #if DEBUG
        dlog("[Audio] 1. start() called, outputURL=\(outputURL.lastPathComponent)")
        dlog("[AudioLife] start() entry on actor AudioRecorder, recorder=\(ObjectIdentifier(self))")
        #endif
#if os(iOS)
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            #if DEBUG
            dlog("[Audio] 2. AVAudioSession active, category=\(session.category.rawValue) sampleRate=\(session.sampleRate)")
            #endif
        }.value
#endif

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode

        // Level stream — created on MainActor before the detached hop.
        let (stream, continuation) = AsyncStream<Float>.makeStream()
        levelStream       = stream
        levelContinuation = continuation
        let cont = levelContinuation
        let writeQueue = DispatchQueue(label: "ceciliasnotes.audio.recorder.write", qos: .userInitiated)

        // Nested inside a `@MainActor` method this struct would inherit
        // main-actor isolation; the detached engine-start task must
        // construct it off the main actor.
        nonisolated struct StartPayload: @unchecked Sendable {
            let engine: AVAudioEngine
            let file: AVAudioFile
        }

        // Tap install + prepare + start block on Core Audio IPC. Running
        // this on the main actor wedges the UI after the permission sheet
        // dismisses — the voice-memo sheet looks frozen even though the
        // engine logged `start() OK`. LectureRecorder detaches the same
        // sequence; mirror that here.
        let payload: StartPayload
        do {
            payload = try await Task.detached(priority: .userInitiated) {
                let format = inputNode.inputFormat(forBus: 0)
                #if DEBUG
                dlog("[Audio] 3. inputNode hw format: sr=\(format.sampleRate) channels=\(format.channelCount)")
                #endif
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw AudioRecorderError.engineFailed(
                        NSError(
                            domain: "AudioRecorder",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Microphone route not ready"]
                        )
                    )
                }

                let aacSettings: [String: Any] = [
                    AVFormatIDKey:            Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey:          format.sampleRate,
                    AVNumberOfChannelsKey:    Int(format.channelCount),
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                let file = try AVAudioFile(forWriting: outputURL, settings: aacSettings)

                inputNode.removeTap(onBus: 0)
                #if DEBUG
                nonisolated(unsafe) var tapFireCount = 0
                #endif
                nonisolated(unsafe) var levelPublishCounter = 0
                inputNode.installTap(
                    onBus:        0,
                    bufferSize:   Self.tapBufferSize,
                    format:       format
                ) { buffer, _ in
                    levelPublishCounter += 1
                    if levelPublishCounter % 5 == 0 {
                        #if DEBUG
                        tapFireCount += 1
                        if tapFireCount == 1 || tapFireCount % 10 == 0 {
                            let rmsValue = Self.rms(buffer: buffer)
                            dlog("[Audio] tap fired #\(tapFireCount), samples=\(buffer.frameLength), rms=\(String(format: "%.4f", rmsValue))")
                            cont?.yield(rmsValue)
                        } else {
                            cont?.yield(Self.rms(buffer: buffer))
                        }
                        #else
                        cont?.yield(Self.rms(buffer: buffer))
                        #endif
                    }

                    guard let copy = buffer.deepCopy() else { return }
#if os(macOS)
                    let pcm = AudioPCMGain.boostedCopy(of: copy) ?? copy
#else
                    let pcm = copy
#endif
                    writeQueue.async {
                        try? file.write(from: pcm)
                    }
                }
                #if DEBUG
                dlog("[Audio] 4. tap installed, bufferSize=\(Self.tapBufferSize)")
                dlog("[Audio] 4a. inputNode numberOfInputs=\(inputNode.numberOfInputs) inputFormat(bus0)=\(inputNode.inputFormat(forBus: 0))")
                #endif

                eng.prepare()
                try eng.start()
                #if DEBUG
                dlog("[Audio] 5. engine.start() OK, isRunning=\(eng.isRunning)")
                #endif
                return StartPayload(engine: eng, file: file)
            }.value
        } catch {
            #if DEBUG
            dlog("[AudioRecorder] engine.start() failed: \(error)")
            #endif
            levelContinuation?.finish()
            levelContinuation = nil
            levelStream       = nil
            throw (error as? AudioRecorderError) ?? AudioRecorderError.engineFailed(error)
        }

        #if DEBUG
        Task { [weak eng] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let eng else { return }
            dlog("[Audio] 5b. engine.isRunning after 500ms = \(eng.isRunning)")
        }
        dlog("[Audio] 5a. AudioRecorder uses POST-RECORDING file transcription, " +
              "not live SpeechTranscriber.startLive(). For quick-record, transcription " +
              "fires from EditorViewModel.stopRecording after the m4a file is saved " +
              "(see `SpeechTranscriber.transcribe(url:annotationId:)`).")
        #endif

        engine    = payload.engine
        audioFile = payload.file
        startTime = Date()
        self.outputURL = outputURL
        #if DEBUG
        dlog("[AudioLife] start() exit — engine instance \(ObjectIdentifier(payload.engine)) retained on actor")
        #endif
    }

    func stop() async throws -> (duration: Double, fileSizeBytes: Int64) {
        #if DEBUG
        let stack = Thread.callStackSymbols.prefix(8).joined(separator: "\n  ")
        dlog("[AudioLife] stop() called on actor AudioRecorder \(ObjectIdentifier(self))")
        dlog("[AudioLife]   call stack:\n  \(stack)")
        #endif
        guard let eng = engine, let start = startTime, let url = outputURL
        else {
            #if DEBUG
            dlog("[AudioLife] stop() guard tripped — engine=\(engine == nil ? "nil" : "live") startTime=\(startTime == nil ? "nil" : "live") outputURL=\(outputURL == nil ? "nil" : "live")")
            #endif
            throw AudioRecorderError.notRecording
        }
        #if DEBUG
        dlog("[AudioLife] tap removed, engine stopping (engine instance \(ObjectIdentifier(eng)) isRunning=\(eng.isRunning))")
        #endif

        await Task.detached(priority: .userInitiated) { [eng] in
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }.value
        engine    = nil
        audioFile = nil   // closing the AVAudioFile flushes and finalises it

        levelContinuation?.finish()
        levelContinuation = nil

        let duration = Date().timeIntervalSince(start)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        startTime  = nil
        outputURL  = nil

#if os(iOS)
        await Task.detached(priority: .userInitiated) {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                #if DEBUG
                dlog("[AudioPlay] rec.stop session deactivated, success=true, error=nil")
                #endif
            } catch {
                #if DEBUG
                dlog("[AudioPlay] rec.stop session deactivated, success=false, error=\(error)")
                #endif
            }
        }.value
#endif
        return (duration: duration, fileSizeBytes: fileSize)
    }

    // MARK: - RMS via vDSP

    nonisolated static func rms(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, frameCount)
        return min(rms * 10, 1.0)
    }
}
