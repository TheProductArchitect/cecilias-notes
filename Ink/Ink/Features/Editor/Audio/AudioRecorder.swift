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

    // MARK: - Permission

    func requestPermission() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw AudioRecorderError.permissionDenied }
    }

    // MARK: - Recording lifecycle

    func start(outputURL: URL) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // AVAudioFile with AAC settings — Core Audio handles PCM→AAC conversion.
        let aacSettings: [String: Any] = [
            AVFormatIDKey:         Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:       nativeFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey:   128_000,
        ]
        let file = try AVAudioFile(forWriting: outputURL, settings: aacSettings)

        // Level stream
        let (stream, continuation) = AsyncStream<Float>.makeStream()
        levelStream       = stream
        levelContinuation = continuation

        // Capture continuation separately so we can yield without an actor hop.
        let cont = levelContinuation

        inputNode.installTap(
            onBus:        0,
            bufferSize:   Self.tapBufferSize,
            format:       nativeFormat
        ) { buffer, _ in
            // RMS — yields directly, no actor hop needed for AsyncStream.
            let rms = Self.rms(buffer: buffer)
            cont?.yield(rms)

            // File write — synchronous. The tap is serial so no concurrent access.
            try? file.write(from: buffer)
        }

        try eng.start()

        engine    = eng
        audioFile = file
        startTime = Date()
        self.outputURL = outputURL
    }

    func stop() async throws -> (duration: Double, fileSizeBytes: Int64) {
        guard let eng = engine, let start = startTime, let url = outputURL
        else { throw AudioRecorderError.notRecording }

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

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
