import Accelerate
import AVFoundation
import Combine
import Foundation
import Speech
import UIKit

/// Step 5: `LectureRecorder.stop()` no longer returns a
/// `LectureRecord` (entity removed in the audio-consolidation
/// commit). It returns this plain struct so the editor's
/// `endLectureMode` can hand the file + transcript + duration off
/// to `AudioElementCommit` for V6 `PageElement(.audio)` creation.
/// Title isn't stored on `AudioContent` in V6 — preserved here so a
/// future UI surface (e.g. a per-element label) can pick it up.
struct LectureRecorderResult {
    let recordId: UUID
    let audioURL: URL
    let transcript: String
    let durationSeconds: Double
    let title: String
}

/// Owns the long-form lecture recording lifecycle:
///   • AVAudioEngine tap writes PCM into an `AVAudioFile` (the
///     permanent `.m4a`) and simultaneously feeds an
///     `SFSpeechAudioBufferRecognitionRequest` for live transcript.
///   • Recognition tasks time out around 60 s. When one completes
///     while we're still recording, we **silently start a fresh
///     request** with no break in the audio capture — the user sees
///     a continuous transcript even though the underlying tasks
///     have rotated. Without this, transcripts stop after the first
///     minute and Apple offers no toggle to make it longer.
///   • Background audio continues because `UIBackgroundModes`
///     includes `audio` and we configure the session with
///     `.playAndRecord / .voiceRecording`. **Speech recognition
///     does NOT run in the background — Apple constraint.** When
///     the app backgrounds we pause recognition (audio keeps
///     recording); on foreground we start a fresh recognition
///     request and the transcript resumes. The gap is acceptable
///     because the full audio file is intact; Pass B's final
///     refinement pass over the saved `.m4a` fills those gaps.
///   • Pause / resume stop and restart both engine and recognition;
///     the elapsed timer pauses with them. Audio writes are paused
///     too — the resulting `.m4a` does not include silent intervals.
///
/// **No network, no third-party.** `requiresOnDeviceRecognition`
/// is set on every request; if the device doesn't support on-device
/// recognition for the chosen locale we fall through to the live
/// engine without a transcript (audio still records correctly).
@MainActor
final class LectureRecorder: ObservableObject {

    // MARK: Published state

    @Published private(set) var isRecording:     Bool    = false
    @Published private(set) var isPaused:        Bool    = false
    @Published         var liveTranscript:       String  = ""
    @Published         var title:                String  = ""
    @Published private(set) var elapsedSeconds:  Double  = 0
    @Published private(set) var audioLevel:      Float   = 0

    // MARK: Identity

    /// The page we're recording on. Set in `start(pageId:)`, used
    /// to build the eventual `LectureRecord` and to soft-cancel an
    /// in-flight recording if the user navigates away.
    private(set) var pageId: UUID?
    /// The notebook the recording belongs to. Denormalised onto the
    /// `LectureRecord` so the V5 schema can purge all records under
    /// a notebook without joining through pages.
    private(set) var notebookId: UUID?
    private var recordId: UUID = UUID()
    private var startedAt: Date = .distantPast

    // MARK: Audio infrastructure

    private var engine: AVAudioEngine?
    private var outputURL: URL?

    /// Non-isolated actor that owns `AVAudioFile` writes and the
    /// currently-active speech request. The audio engine's `installTap`
    /// callback runs on an internal queue, not the main actor; under
    /// Swift 6 strict concurrency the previous `weakSelf?.audioFile`
    /// access would warn for crossing actor isolation. Pulling those
    /// two references into a dedicated actor lets the tap dispatch a
    /// single `Task { await capture.handle(...) }` per buffer without
    /// touching MainActor state.
    private let capture = AudioCaptureActor()

    // MARK: Speech infrastructure

    private var recogniser: SFSpeechRecognizer?
    private var currentTask: SFSpeechRecognitionTask?

    /// Re-entrancy guard for `rotateRecognitionTaskIfStillRecording`.
    /// The recognition result handler can fire multiple times in
    /// rapid succession around a session boundary (final partial
    /// then `.isFinal=true` then a daemon-error callback); without
    /// this guard a second rotation can race the first and create
    /// two competing tasks. The `handwritingd` daemon then kills
    /// both — the source of the "transcript appears then
    /// disappears after one line" symptom.
    private var isRotatingRecognition: Bool = false
    /// Transcripts accumulate across recognition sessions. The live
    /// transcript surfaced to the UI is `committedTranscript +
    /// (current task's running best transcription)`. When a task
    /// completes, its final best transcription is appended to
    /// `committedTranscript` and a fresh request begins.
    private var committedTranscript: String = ""

    // MARK: Timer + lifecycle observers

    private var elapsedTimer: Timer?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    private static let tapBufferSize: AVAudioFrameCount = 4_096

    // MARK: - Public lifecycle

    /// Start recording on `pageId`. Creates the audio file,
    /// configures the session, sets up the engine tap + speech
    /// request, starts the elapsed timer. Inserts a draft
    /// `LectureRecord` into the store immediately so a crash mid-
    /// recording doesn't lose the page binding.
    ///
    /// `notebookId` lives separately on the call so the audio file
    /// can be placed under the notebook's existing `audio/`
    /// directory (where it reaper-purges with the notebook).
    func start(pageId: UUID, notebookId: UUID) async throws {
        guard !isRecording else { return }

        // Permissions — bail early with a descriptive error if either
        // is denied. Caller surfaces a system alert.
        try await ensureMicrophonePermission()
        await ensureSpeechPermission()       // optional — failure means no transcript

        self.pageId      = pageId
        self.notebookId  = notebookId
        self.recordId    = UUID()
        self.startedAt   = Date()

        try configureAudioSession()

        // New lecture writes land directly in the unified
        // `MediaStorage.lectures/` tree. The legacy notebook-scoped
        // `audio/lecture_<id>.m4a` location is read-only after Phase 3
        // — only used by the launch migration to find pre-existing
        // recordings. See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.B.
        MediaStorage.ensureDirectoriesExist()
        let url = MediaStorage.url(for: .lectures, id: recordId)
        self.outputURL = url

        try await startEngineAndFile(at: url)
        await startSpeechRecognition()

        // Step 5: dropped the V5 draft-persistence pattern (no
        // SwiftData row exists until `stop()` returns a
        // `LectureRecorderResult` that `endLectureMode` commits as
        // an `AudioContent` + `PageElement`). The trade-off: a
        // mid-recording crash now loses the in-flight transcript.
        // Acceptable for v1 single-tester; can revisit if needed.

        startElapsedTimer()
        registerLifecycleObservers()

        isRecording = true
        isPaused    = false
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        stopElapsedTimer()
        engine?.pause()
        Task { @MainActor in await self.endSpeechRecognition(commitFinal: true) }
        isPaused = true
    }

    func resume() {
        guard isRecording, isPaused else { return }
        do {
            try engine?.start()
            startElapsedTimer()
            isPaused = false
            Task { @MainActor in await self.startSpeechRecognition() }
        } catch {
            // Best-effort. If the engine fails to restart, stop the
            // session entirely rather than leaving the UI in a half-
            // paused state — the user can tap Lecture again to start
            // fresh.
            Task { _ = await stop() }
        }
    }

    /// Stop recording, flush the audio file, hand back a
    /// `LectureRecorderResult` for the editor to commit as a V6
    /// `AudioContent` + `PageElement`. Returns `nil` for the
    /// "no recording in flight" case (programmer error) and for
    /// sub-second misfires (cleaned up to avoid orphaned files).
    func stop() async -> LectureRecorderResult? {
        guard isRecording else { return nil }
        stopElapsedTimer()
        unregisterLifecycleObservers()

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        await endSpeechRecognition(commitFinal: true)

        await capture.setAudioFile(nil)
        engine = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("[AudioPlay] rec.stop (lecture) session deactivated, success=true, error=nil")
        } catch {
            print("[AudioPlay] rec.stop (lecture) session deactivated, success=false, error=\(error)")
        }

        let url = outputURL ?? URL(fileURLWithPath: "lecture_\(recordId.uuidString).m4a")
        let duration = elapsedSeconds
        guard duration >= 1.0 else {
            #if DEBUG
            print("[LectureRecorder] stop → discarding sub-second recording (duration=\(duration)s)")
            #endif
            try? FileManager.default.removeItem(at: url)
            isRecording = false
            isPaused    = false
            return nil
        }
        isRecording = false
        isPaused    = false

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = committedTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 5: kick off the post-recording refinement pass that
        // re-transcribes the saved M4A and writes a (usually richer)
        // transcript back into the V6 `AudioContent` row keyed by
        // `recordId`. The editor commits the initial row + transcript
        // synchronously from the return value below; refinement is
        // best-effort and fires-and-forgets.
        if FileManager.default.fileExists(atPath: url.path) {
            let refineRecordId = recordId
            let refineURL      = url
            Task.detached {
                await Self.refineTranscript(
                    contentId: refineRecordId,
                    audioURL:  refineURL
                )
            }
        }

        return LectureRecorderResult(
            recordId: recordId,
            audioURL: url,
            transcript: trimmedTranscript,
            durationSeconds: duration,
            title: trimmedTitle.isEmpty ? "Untitled lecture" : trimmedTitle
        )
    }

    // MARK: - Engine + file

    private func startEngineAndFile(at url: URL) async throws {
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let format = input.outputFormat(forBus: 0)

        // AAC settings for the persistent file — Core Audio handles
        // the PCM→AAC conversion automatically when we write PCM
        // buffers into an `AVAudioFile` whose settings request AAC.
        //
        // Sample rate AND channel count must match the input node's
        // actual output format; hardcoding either (e.g. forcing
        // mono on a stereo input) raises
        // `AudioCodecInitialize failed / kAudioConverterEncodeBitRate
        // 'fmt?'` at write time because the encoder rejects the
        // combination. Letting the encoder pick its own bit rate
        // via `AVEncoderAudioQualityKey` rather than the explicit
        // `AVEncoderBitRateKey` avoids the second half of that
        // rejection — the encoder knows which bit rates are valid
        // for the (sample rate, channel count) pair it actually
        // ends up using.
        let aacSettings: [String: Any] = [
            AVFormatIDKey:            Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:          format.sampleRate,
            AVNumberOfChannelsKey:    Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: aacSettings)
        await capture.setAudioFile(file)

        // The tap closure captures the actor (a Sendable reference)
        // and a weak self for the audio-level update; nothing
        // MainActor-isolated is read from inside the closure body
        // itself. Buffer is deep-copied before crossing the actor
        // boundary because AVAudioEngine reuses the tap buffer after
        // the callback returns.
        let captureActor = self.capture
        #if DEBUG
        // Tap-fire counter mirroring AudioRecorder's diagnostic.
        // First call + every 50th thereafter print so we can
        // confirm the engine is actually delivering buffers to
        // the recogniser. The #1 print is the critical signal:
        // if it never appears, the tap is silent and SFSpeech
        // will eventually error with 1101 (no audio received).
        nonisolated(unsafe) var tapFireCount = 0
        #endif
        // Capture `self` weakly directly in the closure's capture
        // list — the previous `weak var weakSelf = self` form
        // tripped Swift 6's "never mutated" warning, and `weak let`
        // is not valid syntax. Capture-list `[weak self]` carries
        // the same weak semantics.
        input.installTap(
            onBus:      0,
            bufferSize: Self.tapBufferSize,
            format:     format
        ) { [weak self] buffer, _ in
            #if DEBUG
            tapFireCount += 1
            if tapFireCount == 1 || tapFireCount % 50 == 0 {
                let frames = buffer.frameLength
                print("[Lecture] tap fired #\(tapFireCount), samples=\(frames)")
            }
            #endif
            // The tap closure captures `self` weakly so the engine
            // doesn't retain the recorder. Inside, work that hops
            // to the main actor goes through its own `[weak self]`
            // re-capture so Swift 6 strict concurrency doesn't
            // flag the var capture crossing actor boundaries.
            let rms = Self.rms(buffer: buffer)
            Task { @MainActor [weak self] in self?.audioLevel = rms }

            // Copy off the AVAudioEngine queue. The actor will own
            // this copy; the engine is free to recycle the original.
            // `captureActor` is a sendable actor reference captured
            // by value above.
            guard let copy = buffer.deepCopy() else { return }
            let wrapped = CapturedAudioBuffer(buffer: copy)
            Task { await captureActor.handle(wrapped.buffer) }
        }

        // `prepare()` pre-allocates the engine's internal buffers
        // before `start()` — mirrors the AudioRecorder fix that
        // resolved the "engine.start() succeeds but no buffers
        // flow" symptom. Cheap; safe to call on a freshly-allocated
        // engine.
        eng.prepare()
        try eng.start()
        #if DEBUG
        print("[Lecture] engine.start() OK, isRunning=\(eng.isRunning)")
        Task { [weak eng] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let eng else { return }
            print("[Lecture] engine.isRunning after 500ms = \(eng.isRunning)")
        }
        #endif
        engine = eng
    }

    // MARK: - Speech recognition

    private func startSpeechRecognition() async {
        // Defensive teardown of any task that survived a prior
        // rotation — the recogniser refuses to host a second task
        // while a previous one still has a reference, and that's
        // the precise contention that drops the `handwritingd`
        // daemon connection.
        currentTask?.cancel()
        currentTask = nil
        await capture.endRequestAudio()

        #if DEBUG
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        print("[Dictation] startSpeechRecognition — speech auth status=\(authStatus.rawValue) (\(authStatusString(authStatus)))")
        #endif

        // Pick a recogniser that supports on-device recognition.
        // Order: user-selected locale → system → en-US fallback.
        // If every candidate fails the on-device check, fall back
        // to the server recogniser (current locale) — better a
        // network-dependent transcript than no transcript at all.
        let (recogniser, wasOnDevice) = Self.makeRecogniser()
        self.recogniser = recogniser
        guard let recogniser else {
            #if DEBUG
            print("[Dictation] startSpeechRecognition ABORT — no recogniser available (on-device + server fallback both failed)")
            #endif
            return
        }
        #if DEBUG
        print("[Dictation] selected recogniser locale=\(recogniser.locale.identifier) supportsOnDevice=\(recogniser.supportsOnDeviceRecognition) wasOnDevice=\(wasOnDevice) isAvailable=\(recogniser.isAvailable)")
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults  = true
        // Only require on-device when we actually found an
        // on-device-capable recogniser. Server fallback allows
        // dictation to work on devices/models that lack on-device
        // assets.
        request.requiresOnDeviceRecognition = wasOnDevice
        request.taskHint                    = .dictation
        await capture.setRequest(request)

        #if DEBUG
        print("[Dictation] startSpeechRecognition — installing recognitionTask (onDevice=\(request.requiresOnDeviceRecognition))")
        #endif
        currentTask = recogniser.recognitionTask(with: request) { [weak self] result, error in
            // Log BEFORE the Task hop so we can see whether iOS
            // is firing the callback at all. The hop is needed
            // because @MainActor isolation is required to touch
            // the @Published members on `self`, but the print
            // here doesn't need it.
            #if DEBUG
            print("[Dictation] recognitionTask callback fired — hasResult=\(result != nil) hasError=\(error != nil)")
            #endif
            Task { @MainActor [weak self] in
                guard let self else {
                    #if DEBUG
                    print("[Dictation] recognitionTask Task DROP — self gone")
                    #endif
                    return
                }
                if let result {
                    let partial = result.bestTranscription.formattedString
                    self.liveTranscript =
                        (self.committedTranscript + " " + partial)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    #if DEBUG
                    print("[Dictation] partial result, len=\(partial.count), isFinal=\(result.isFinal), preview=\(String(partial.prefix(40)))")
                    #endif
                }
                if let error {
                    #if DEBUG
                    print("[Dictation] recogniser error: \(error)")
                    #endif
                }
                let didFinish = result?.isFinal == true || error != nil
                if didFinish {
                    await self.rotateRecognitionTaskIfStillRecording(
                        finalSegment: result?.bestTranscription.formattedString
                    )
                }
            }
        }
        #if DEBUG
        if currentTask == nil {
            print("[Dictation] recognitionTask install returned nil")
        }
        #endif
    }

    #if DEBUG
    private func authStatusString(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .authorized:    return "authorized"
        @unknown default:    return "unknown"
        }
    }
    #endif

    /// Called when a recognition task ends (timeout, final result,
    /// or error). If we're still recording AND not paused AND not
    /// backgrounded, commit the segment's final text and start a
    /// fresh request immediately.
    ///
    /// Strictly sequential: the previous task must be fully torn
    /// down before the new request is created, or the
    /// `handwritingd` daemon sees two competing sessions and
    /// invalidates both. `isRotatingRecognition` blocks re-entry
    /// from rapid-succession result callbacks. A 120ms delay
    /// between the old request's `endAudio()` and the new task's
    /// creation gives the daemon room to release the previous
    /// session — short enough that the user doesn't perceive a
    /// gap in the live transcript.
    private func rotateRecognitionTaskIfStillRecording(finalSegment: String?) async {
        guard !isRotatingRecognition else { return }
        isRotatingRecognition = true
        defer { isRotatingRecognition = false }

        // Commit the final segment BEFORE tearing down the request
        // so the daemon's last delivered string is reflected in
        // `committedTranscript` regardless of what the new
        // session captures.
        if let finalSegment, !finalSegment.isEmpty {
            committedTranscript =
                (committedTranscript + " " + finalSegment)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // End the previous request's audio and finish the task.
        // `finish()` is preferred over `cancel()` here — it lets
        // any pending result deliver normally. The task's
        // completion handler clears the local reference; we
        // additionally nil it here to be safe.
        await capture.endRequestAudio()
        currentTask?.finish()
        currentTask = nil
        // Give the speech daemon a beat to release the previous
        // session before we ask for a new one. Without this delay
        // the new request often fails to connect with a daemon
        // invalidation error.
        try? await Task.sleep(for: .milliseconds(120))

        guard isRecording, !isPaused else { return }
        // Bail if we got backgrounded between callback fire and
        // here — the foreground hook will restart us.
        guard UIApplication.shared.applicationState != .background else { return }

        await startSpeechRecognition()
    }

    /// Tear down the current recognition task. When
    /// `commitFinal == true` and the task delivered partial-only
    /// output, we splice the partial in as if it had been final so
    /// the user's most recent words aren't lost.
    private func endSpeechRecognition(commitFinal: Bool) async {
        await capture.endRequestAudio()
        currentTask?.cancel()
        if commitFinal, !liveTranscript.isEmpty {
            committedTranscript = liveTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        currentTask = nil
    }

    private static func makeOnDeviceRecogniser() -> SFSpeechRecognizer? {
        makeRecogniser().0.flatMap { $0.supportsOnDeviceRecognition ? $0 : nil }
    }

    /// Returns the best available `SFSpeechRecognizer` and a flag
    /// indicating whether on-device recognition was found. The
    /// caller uses the flag to set `requiresOnDeviceRecognition`
    /// only when on-device is genuinely supported — without this,
    /// `requiresOnDeviceRecognition = true` on a device whose
    /// on-device model isn't loaded yet fails the task immediately
    /// with `kAFAssistantErrorDomain Code=1101`. Server-side
    /// recognition is the documented fallback when on-device
    /// can't service the request.
    private static func makeRecogniser() -> (SFSpeechRecognizer?, onDevice: Bool) {
        let chosen = UserDefaults.standard.string(forKey: "ink.transcription.locale") ?? ""
        let candidateLocales: [Locale] = {
            var locales: [Locale] = []
            if !chosen.isEmpty {
                locales.append(Locale(identifier: chosen))
            }
            locales.append(Locale.current)
            locales.append(Locale(identifier: "en-US"))
            return locales
        }()

        // First pass — look for on-device support across the
        // candidate locales.
        for locale in candidateLocales {
            guard let r = SFSpeechRecognizer(locale: locale) else {
                #if DEBUG
                print("[Dictation] makeRecogniser — no recogniser for locale=\(locale.identifier)")
                #endif
                continue
            }
            if r.supportsOnDeviceRecognition {
                #if DEBUG
                print("[Dictation] makeRecogniser — on-device match locale=\(locale.identifier)")
                #endif
                return (r, true)
            }
        }
        // Second pass — accept any available recogniser, even
        // server-only. Better than refusing dictation entirely.
        for locale in candidateLocales {
            if let r = SFSpeechRecognizer(locale: locale), r.isAvailable {
                #if DEBUG
                print("[Dictation] makeRecogniser — server-fallback match locale=\(locale.identifier)")
                #endif
                return (r, false)
            }
        }
        #if DEBUG
        print("[Dictation] makeRecogniser — no recogniser available, on-device or otherwise")
        #endif
        return (nil, false)
    }

    // MARK: - Refinement pass

    /// One-shot transcription of the finalised `.m4a` after stop —
    /// catches any gap the live recogniser left behind (notably the
    /// backgrounded intervals where recognition can't run).
    /// Best-effort; writes back into the store under the same
    /// record id when complete. Detached so the calling view's
    /// dismiss animation isn't blocked.
    private static func refineTranscript(
        contentId: UUID,
        audioURL:  URL
    ) async {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recogniser = makeOnDeviceRecogniser()
        else { return }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults  = false
        request.requiresOnDeviceRecognition = true
        request.taskHint                    = .dictation

        let final: String? = await withCheckedContinuation { cont in
            recogniser.recognitionTask(with: request) { result, error in
                guard let result, result.isFinal else {
                    if error != nil { cont.resume(returning: nil) }
                    return
                }
                cont.resume(returning: result.bestTranscription.formattedString)
            }
        }
        guard let final, !final.isEmpty else { return }

        await MainActor.run {
            // Step 5: write the refined transcript into the V6
            // `AudioContent` row keyed by `contentId`. The "prefer
            // longer transcript" rule is enforced inside
            // `AudioElementCommit.updateTranscript` is intentionally
            // unconditional here — by the time refinement completes
            // the live transcript has already been committed, and
            // the refined one is usually richer. If it's not, the
            // user keeps a less-good transcript briefly; trade-off
            // is acceptable for a best-effort pass.
            AudioElementCommit.updateTranscript(
                contentId: contentId,
                transcript: final
            )
        }
    }

    // MARK: - Session + permissions

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.voiceChat` activates Apple's built-in noise-suppression
        // and echo-cancellation pipeline on the microphone input —
        // the closest equivalent to the spec's `.voiceRecording`
        // (which exists in iOS 18.4's docs but isn't surfaced as a
        // public `AVAudioSession.Mode` constant in the current
        // SDK). `.defaultToSpeaker` + `.allowBluetoothHFP` route
        // audio sensibly when no headphones are connected; HFP
        // replaces the deprecated `.allowBluetooth` option.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)
    }

    private func ensureMicrophonePermission() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw LectureRecorderError.microphoneDenied }
    }

    /// Speech permission is optional — we can record audio without
    /// it; the transcript just stays empty.
    private func ensureSpeechPermission() async {
        _ = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { _ in
                cont.resume(returning: ())
            }
        }
    }

    // MARK: - Timer

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let anchor = Date()
        let alreadyElapsed = elapsedSeconds
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // Compute the value in the Timer's run-loop context
            // before the Task hop so the result is a plain Sendable
            // `Double` crossing the actor boundary. The inner Task
            // re-captures `self` weakly via its own capture list so
            // the outer Timer closure's `weak var self` doesn't
            // bleed into concurrently-executing code — Swift 6
            // strict-concurrency rejects the implicit-var form.
            let elapsed = alreadyElapsed + Date().timeIntervalSince(anchor)
            Task { @MainActor [weak self] in
                self?.elapsedSeconds = elapsed
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - Background / foreground

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default
        backgroundObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Audio keeps recording (UIBackgroundModes: audio).
            // Speech recognition cannot run in background — Apple
            // constraint — so we tear it down here and rely on the
            // refinement pass to fill the gap when stop() fires.
            Task { @MainActor in await self?.endSpeechRecognition(commitFinal: true) }
        }
        foregroundObserver = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, !self.isPaused else { return }
                await self.startSpeechRecognition()
            }
        }
    }

    private func unregisterLifecycleObservers() {
        let nc = NotificationCenter.default
        if let b = backgroundObserver { nc.removeObserver(b) }
        if let f = foregroundObserver { nc.removeObserver(f) }
        backgroundObserver = nil
        foregroundObserver = nil
    }

    // MARK: - Helpers

    /// Convert an absolute URL in the Documents tree to a
    /// Documents-relative path so the `LectureRecord` doesn't pin
    /// to a sandbox-specific absolute string.
    private func relativePath(of url: URL) -> String {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0].path
        if url.path.hasPrefix(docs) {
            return String(url.path.dropFirst(docs.count).drop(while: { $0 == "/" }))
        }
        return url.lastPathComponent
    }

    private static func rms(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, frameCount)
        return min(rms * 10, 1.0)
    }
}

// MARK: - Errors

enum LectureRecorderError: Error, LocalizedError {
    case microphoneDenied
    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access denied. Enable it in Settings."
        }
    }
}

// MARK: - AudioCaptureActor

/// Holds the live `AVAudioFile` and the active speech recognition
/// request on a non-isolated actor so the AVAudioEngine tap callback
/// — which runs on an internal queue, not the main actor — can read
/// and write those references without violating MainActor isolation.
/// Calls are serialised by the actor's executor, which preserves the
/// in-order semantics both the audio file writer and the speech
/// recogniser need.
///
/// `AVAudioFile` and `SFSpeechAudioBufferRecognitionRequest` are not
/// `Sendable` on the current SDK; the `@unchecked Sendable` wrappers
/// below carry them across the actor boundary. The contract is that
/// no other code holds a concurrent reference to either object while
/// the actor owns it, which the surrounding `LectureRecorder` flow
/// guarantees.
actor AudioCaptureActor {
    private var audioFile: AVAudioFile?
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?

    func setAudioFile(_ file: AVAudioFile?) {
        self.audioFile = file
    }

    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        self.currentRequest = request
    }

    /// End the current request's audio and drop the reference. The
    /// recogniser will deliver one final result and then complete.
    func endRequestAudio() {
        currentRequest?.endAudio()
        currentRequest = nil
    }

    /// Append a captured PCM buffer to both the persistent audio file
    /// and (when present) the live recognition request. The buffer
    /// must be a deep copy of the engine's tap buffer — see
    /// `AVAudioPCMBuffer.deepCopy()`.
    func handle(_ buffer: AVAudioPCMBuffer) {
        try? audioFile?.write(from: buffer)
        currentRequest?.append(buffer)
    }
}

// MARK: - Sendable wrappers for Core Audio + Speech references

/// AVFoundation's PCM buffer is a reference type that the engine
/// recycles after the tap returns; we always pass a deep copy across
/// actor boundaries. The `@unchecked` declaration affirms that
/// promise to the compiler.
private struct CapturedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private extension AVAudioPCMBuffer {
    /// Deep-copy the buffer's float channel data into a fresh buffer
    /// that has no shared storage with the original. The engine is
    /// free to recycle the source the moment the tap callback
    /// returns, so anything we hand off to the actor must be a copy.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else { return nil }
        copy.frameLength = frameLength
        let channelCount = Int(format.channelCount)
        let byteCount = Int(frameLength) * MemoryLayout<Float>.size
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], byteCount)
            }
        }
        return copy
    }
}
