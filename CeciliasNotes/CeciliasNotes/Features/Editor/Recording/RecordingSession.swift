import AVFoundation
import Combine
import Foundation
import SwiftData
import SwiftUI
import UIKit

/// App-wide owner of "is there a recording happening?" state. Reads
/// flow through the singleton from three UI surfaces:
///   • `FloatingRecordingControls` (in-editor overlay).
///   • `RecordingPill` (app-root overlay, visible while the user is
///     elsewhere in the app).
///   • Inline `AudioElementView` strips during Voice Note recording.
///
/// Writes flow through `startVoiceNote(...)`, `startDictation(...)`,
/// and `stop()`. Both flows route to the same `AudioContent` data
/// model under the hood — the difference is UI surface + page side-
/// effects, not the schema.
///
/// Voice Note: inline audio strip pulses on the current page; no
/// new page, no transcript display, transcription happens silently
/// post-record (gated by Settings → autoTranscribe).
///
/// Dictation: a fresh page is created; transcript streams live into
/// a `TextContent` element on that page; overflow at sentence
/// boundaries creates continuation pages anchored back to the
/// recording via `TextContent.anchorAudioId`. On stop, the audio
/// strip is committed above the first transcript element (paired-
/// block layout per architecture §9).
@MainActor
final class RecordingSession: ObservableObject {

    static let shared = RecordingSession()

    @Published private(set) var state: State = .idle
    /// Elapsed time since the recording started. Republished at
    /// ~10 Hz by an internal timer so the floating controls + pill
    /// can update their timers without each subscribing directly to
    /// the underlying recorder.
    @Published private(set) var elapsedSeconds: Double = 0
    /// One-shot banner content surfaced when a recording is cut
    /// short by an AVAudioSession interruption (phone call, Siri,
    /// etc.). Editor surfaces this through the existing media-error
    /// channel; cleared on next recording start.
    @Published var interruptionMessage: String?

    // MARK: - State

    enum State: Equatable {
        case idle
        case voiceNote(VoiceNoteContext)
        case dictation(DictationContext)

        var isRecording: Bool {
            if case .idle = self { return false }
            return true
        }

        /// The notebook id the active recording belongs to, if any.
        /// Used by `RecordingPill` to navigate back to the right
        /// notebook when the user taps the pill from outside the
        /// editor.
        var notebookId: UUID? {
            switch self {
            case .idle: return nil
            case .voiceNote(let ctx): return ctx.notebookId
            case .dictation(let ctx): return ctx.notebookId
            }
        }

        var startTime: Date? {
            switch self {
            case .idle: return nil
            case .voiceNote(let ctx): return ctx.startTime
            case .dictation(let ctx): return ctx.startTime
            }
        }
    }

    struct VoiceNoteContext: Equatable {
        let audioElementId: UUID      // PageElement.id of the inline pill
        let audioContentId: UUID      // AudioContent.id (matches m4a filename stem)
        let startTime: Date
        let pageId: UUID
        let notebookId: UUID
    }

    struct DictationContext: Equatable {
        let audioContentId: UUID      // AudioContent.id (matches m4a filename stem)
        let originalPageId: UUID      // first dictation page — where the audio strip lands on stop
        var currentPageId: UUID       // updated as continuation pages are created
        let notebookId: UUID
        let startTime: Date
        /// First entry is the original page's TextContent; appends
        /// land as continuation pages are created. Used on stop to
        /// place the audio strip above the first element and to
        /// rewrite back-links if needed.
        var textElementIds: [UUID]
    }

    // MARK: - Recorders

    /// Owned by the session for the duration of an active recording;
    /// nil while `state == .idle`. Voice Note uses `AudioRecorder`
    /// (the simpler post-record transcription pipeline); Dictation
    /// uses `LectureRecorder` (live-streaming transcription via
    /// SFSpeechAudioBufferRecognitionRequest with rotation).
    private var audioRecorder: AudioRecorder?
    private var dictationRecorder: LectureRecorder?
    private var pendingRecordingURL: URL?

    /// Subscribers for `LectureRecorder.$liveTranscript` (Dictation
    /// only) and the elapsed-timer.
    private var cancellables: Set<AnyCancellable> = []
    private var elapsedTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?

    // MARK: - Init

    private init() {
        registerInterruptionObserver()
    }

    deinit {
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Voice Note flow

    /// Start a Voice Note recording on the given page. Creates the
    /// inline audio PageElement immediately (in `.recording`
    /// rendering state — see `AudioElementView`) so the user sees
    /// the pulsing pill from the first frame. The audio file is
    /// written to `MediaStorage.url(for: .audio, id: audioContentId)`
    /// as the recorder runs; on stop, the element transitions to
    /// the standard play/pause/progress strip via
    /// `AudioElementCommit.finalizeVoiceNote(...)`.
    func startVoiceNote(
        on pageId: UUID,
        notebookId: UUID,
        pageSize: CGSize
    ) async {
        guard case .idle = state else { return }
        interruptionMessage = nil

        let recorder = AudioRecorder()
        do {
            try await recorder.requestPermission()
        } catch {
            interruptionMessage = "Microphone access denied."
            return
        }

        let contentId = UUID()
        MediaStorage.ensureDirectoriesExist()
        let fileURL = MediaStorage.url(for: .audio, id: contentId)
        do {
            try await recorder.start(outputURL: fileURL)
        } catch {
            interruptionMessage = "Couldn't start recording."
            return
        }

        let elementId = AudioElementCommit.createRecordingPlaceholder(
            contentId: contentId,
            pageId: pageId,
            notebookId: notebookId,
            pageSize: pageSize
        )

        audioRecorder = recorder
        pendingRecordingURL = fileURL
        state = .voiceNote(VoiceNoteContext(
            audioElementId: elementId,
            audioContentId: contentId,
            startTime: Date(),
            pageId: pageId,
            notebookId: notebookId
        ))
        startElapsedTimer()
    }

    // MARK: - Dictation flow

    /// Start a Dictation recording. Inserts a fresh `Page` after
    /// the user's current page, navigates the editor to it (via
    /// the `pendingScrollPageIndex` hook on `EditorViewModel`),
    /// creates an initial `TextContent` element at the top of that
    /// new page, and starts the live-transcription recorder
    /// streaming text into it.
    ///
    /// `EditorViewModel` callbacks: `createPageAfterCurrent` and
    /// `selectPage` (provided as closures so this session stays
    /// view-model-agnostic and the same wire-up can be reused if
    /// the editor's API shape changes).
    func startDictation(
        notebookId: UUID,
        fromPageId: UUID,
        pageSize: CGSize,
        createNewPage: () -> Page?,
        navigateToPage: (UUID) -> Void
    ) async {
        #if DEBUG
        print("[Dictation] RecordingSession.startDictation entered, state=\(state)")
        #endif
        if case .idle = state {
            // Normal path — proceed.
        } else {
            // Defensive recovery: if a prior recording left the
            // state machine non-idle (a stop path failed half-way,
            // an interruption never re-armed the state, etc.),
            // hard-reset and retry once. Better than silently
            // refusing every subsequent dictation attempt for the
            // rest of the session.
            #if DEBUG
            print("[Dictation] state not idle (\(state)) — forcing resetSession() before retry")
            #endif
            resetSession()
            guard case .idle = state else {
                #if DEBUG
                print("[Dictation] ABORT — resetSession() did not land in .idle (state=\(state))")
                #endif
                return
            }
        }
        interruptionMessage = nil

        guard let newPage = createNewPage() else {
            #if DEBUG
            print("[Dictation] ABORT — createNewPage returned nil")
            #endif
            interruptionMessage = "Couldn't create a new page for dictation."
            return
        }
        #if DEBUG
        print("[Dictation] new page created id=\(newPage.id) number=\(newPage.pageNumber)")
        #endif

        let recorder = LectureRecorder()
        do {
            try await recorder.start(pageId: newPage.id, notebookId: notebookId)
            #if DEBUG
            print("[Dictation] LectureRecorder.start succeeded")
            #endif
        } catch {
            #if DEBUG
            print("[Dictation] ABORT — LectureRecorder.start threw: \(error)")
            #endif
            interruptionMessage = "Couldn't start dictation."
            return
        }

        // Create the initial transcript text element at the top of
        // the new page. The element starts empty; the recorder's
        // `@Published liveTranscript` streams text in via the
        // sink below.
        let firstTextId = DictationFlowCommit.createInitialTextElement(
            pageId: newPage.id,
            notebookId: notebookId,
            pageSize: pageSize
        )
        #if DEBUG
        print("[Dictation] initial text element id=\(firstTextId)")
        #endif

        let contentId = UUID()
        dictationRecorder = recorder
        state = .dictation(DictationContext(
            audioContentId: contentId,
            originalPageId: newPage.id,
            currentPageId: newPage.id,
            notebookId: notebookId,
            startTime: Date(),
            textElementIds: [firstTextId]
        ))

        navigateToPage(newPage.id)
        startElapsedTimer()
        subscribeLiveTranscript(recorder)
        #if DEBUG
        print("[Dictation] startDictation completed successfully, state=\(state)")
        #endif
    }

    private func subscribeLiveTranscript(_ recorder: LectureRecorder) {
        recorder.$liveTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                self?.handleLiveTranscript(transcript)
            }
            .store(in: &cancellables)
    }

    /// Stream the live transcript into the active dictation's
    /// current TextContent. Heuristic overflow check: when the
    /// running transcript on the current page exceeds
    /// `charsPerPage`, find the last sentence boundary within
    /// the buffer and split — earlier portion stays on the
    /// current TextContent, remainder seeds a new TextContent on
    /// a new page.
    private func handleLiveTranscript(_ transcript: String) {
        guard case .dictation(var ctx) = state else { return }
        guard let currentTextId = ctx.textElementIds.last else { return }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        DictationFlowCommit.updateText(elementId: currentTextId, text: trimmed)

        // Approximate overflow: bytes-per-page heuristic at body
        // text size on a typical iPad page. Cheap; the architecture
        // doc acknowledges this as a v1 trade-off in §9. Real
        // TextKit measurement is a follow-up if users hit it.
        let charsPerPage = 1200
        guard trimmed.count > charsPerPage else { return }

        guard let split = sentenceBoundarySplit(trimmed, before: charsPerPage)
        else { return }

        // Commit the head text to the current element, then create
        // a new page + TextContent for the remainder. Update state
        // before the recorder writes more so subsequent
        // `handleLiveTranscript` calls land on the new element.
        DictationFlowCommit.updateText(elementId: currentTextId, text: split.head)
        guard let next = DictationFlowCommit.createContinuationPage(
            afterPageId: ctx.currentPageId,
            notebookId: ctx.notebookId,
            anchorAudioId: ctx.audioContentId,
            initialText: split.tail
        ) else { return }

        ctx.currentPageId = next.pageId
        ctx.textElementIds.append(next.textElementId)
        state = .dictation(ctx)

        // Sentence-boundary split was destructive on the recorder's
        // live transcript — we no longer need history past the
        // tail. `LectureRecorder.committedTranscript` keeps the
        // full transcript internally so the final m4a-level
        // refinement still has the entire text.
        dictationRecorder?.liveTranscript = split.tail
    }

    /// Split `text` at the last sentence boundary before `cutoff`.
    /// If no sentence-ending punctuation is found within the window,
    /// hard-break at `cutoff` rather than block continuation.
    private func sentenceBoundarySplit(
        _ text: String,
        before cutoff: Int
    ) -> (head: String, tail: String)? {
        let bounded = text.prefix(cutoff)
        let pattern = "[.!?]\\s+"
        let range = bounded.range(
            of: pattern,
            options: [.regularExpression, .backwards]
        )
        if let range {
            // Include the punctuation in the head; tail starts at
            // the first non-whitespace character after.
            let head = String(text[..<range.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty else { return nil }
            return (head, tail)
        }
        // No sentence boundary — hard break at cutoff.
        let head = String(text.prefix(cutoff))
        let tail = String(text.dropFirst(cutoff))
        return (head, tail)
    }

    // MARK: - Stop

    /// Finalize whichever recording is active. Voice Note: the
    /// inline placeholder transitions to its ready state; the
    /// audio file is sealed. Dictation: AudioContent is committed
    /// with the full transcript + audio strip element placed above
    /// the first transcript text element (paired-block layout).
    func stop() async {
        switch state {
        case .idle:
            return
        case .voiceNote(let ctx):
            await stopVoiceNote(ctx)
        case .dictation(let ctx):
            await stopDictation(ctx)
        }
    }

    private func stopVoiceNote(_ ctx: VoiceNoteContext) async {
        guard let recorder = audioRecorder else { resetSession(); return }
        let result: (duration: Double, fileSizeBytes: Int64)
        do {
            result = try await recorder.stop()
        } catch {
            resetSession()
            return
        }

        AudioElementCommit.finalizeVoiceNote(
            elementId: ctx.audioElementId,
            contentId: ctx.audioContentId,
            durationSeconds: result.duration
        )

        // Post-record transcription, gated by the existing
        // `ink.transcription.auto` setting (architecture intent:
        // dictation always transcribes, voice notes are user-
        // configurable).
        let autoTranscribe = UserDefaults.standard
            .object(forKey: "ink.transcription.auto") as? Bool ?? true
        if autoTranscribe, let url = pendingRecordingURL {
            let contentId = ctx.audioContentId
            Task.detached(priority: .utility) {
                await SpeechTranscriber.shared.transcribe(
                    url: url, annotationId: contentId
                )
            }
        }

        resetSession()
    }

    private func stopDictation(_ ctx: DictationContext) async {
        guard let recorder = dictationRecorder else { resetSession(); return }
        guard let result = await recorder.stop() else {
            resetSession()
            return
        }

        // Adopt the lecture file into the unified audio/ tree so
        // AudioContent.fileURL resolves; commit the strip above the
        // first text element on the original dictation page.
        let contentId = ctx.audioContentId
        let originalPageId = ctx.originalPageId
        let notebookId = ctx.notebookId
        let textElementIds = ctx.textElementIds
        let transcript = result.transcript
        let durationSeconds = result.durationSeconds
        let sourceURL = result.audioURL

        Task { @MainActor in
            let adopted = await MediaStorage.adoptAudio(at: sourceURL, id: contentId)
            guard adopted != nil else { return }
            DictationFlowCommit.finalizeDictation(
                contentId: contentId,
                originalPageId: originalPageId,
                notebookId: notebookId,
                textElementIds: textElementIds,
                transcript: transcript,
                durationSeconds: durationSeconds
            )
        }

        resetSession()
    }

    private func resetSession() {
        stopElapsedTimer()
        cancellables.removeAll()
        audioRecorder = nil
        dictationRecorder = nil
        pendingRecordingURL = nil
        state = .idle
        elapsedSeconds = 0
    }

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        stopElapsedTimer()
        let start = state.startTime ?? Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - AVAudioSession interruption handling

    private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .began:
                    // Pause cleanly. v1 doesn't auto-resume — too
                    // many edge cases (call dropped, Siri returning
                    // mid-sentence) for the trade-off to be worth
                    // it on a single-tester build.
                    if self.state.isRecording {
                        self.interruptionMessage =
                            "Recording stopped due to interruption. Audio saved."
                        await self.stop()
                    }
                case .ended:
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}
