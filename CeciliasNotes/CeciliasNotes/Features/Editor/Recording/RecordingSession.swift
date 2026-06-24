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

        /// The page id the active recording is currently writing to.
        /// For dictation, this tracks `currentPageId` — updated as
        /// the recorder rolls onto continuation pages — so tapping
        /// "return to recording" lands on the page the live
        /// transcript is actually appearing on, not just the
        /// notebook root.
        var pageId: UUID? {
            switch self {
            case .idle: return nil
            case .voiceNote(let ctx): return ctx.pageId
            case .dictation(let ctx): return ctx.currentPageId
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
        /// First dictation page — where the audio strip lands on stop.
        /// `nil` until the first transcript word arrives and the lazy
        /// page-creation path fires. This recording-first design lets
        /// the floating timer pill come up the instant the user taps
        /// Dictation; the heavy "create new page + navigate + mount
        /// overlays + rebuild canvas hosts" work only runs once the
        /// recogniser has produced content worth committing.
        var originalPageId: UUID?
        /// Updated as continuation pages are created. Same nil-until-
        /// first-word semantics as `originalPageId`.
        var currentPageId: UUID?
        let notebookId: UUID
        let startTime: Date
        /// First entry is the original page's TextContent; appends
        /// land as continuation pages are created. Used on stop to
        /// place the audio strip above the first element. Empty until
        /// the lazy page-creation path fires.
        var textElementIds: [UUID]
    }

    /// Lazy page-creation hooks, captured from `EditorViewModel` at
    /// `startDictation` time and fired on the first non-empty
    /// transcript partial. Cleared in `resetSession`.
    private var dictationCreatePage: (() -> Page?)?
    private var dictationNavigate: ((UUID) -> Void)?
    private var dictationPageSize: CGSize = .zero

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
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?

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
        // Defense in depth — the mic button is hidden on read-only
        // devices, but a deep link or keyboard shortcut could still
        // route here. We refuse cleanly rather than half-start a
        // recording the UI can't surface.
        guard DeviceCapabilities.canRecord else { return }
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
        createNewPage: @escaping () -> Page?,
        navigateToPage: @escaping (UUID) -> Void
    ) async {
        // Read-only devices never start dictation — same defense
        // posture as `startVoiceNote`.
        guard DeviceCapabilities.canRecord else { return }
        #if DEBUG
        dlog("[Dictation] RecordingSession.startDictation entered, state=\(state)")
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
            dlog("[Dictation] state not idle (\(state)) — forcing resetSession() before retry")
            #endif
            resetSession()
            guard case .idle = state else {
                #if DEBUG
                dlog("[Dictation] ABORT — resetSession() did not land in .idle (state=\(state))")
                #endif
                return
            }
        }
        interruptionMessage = nil

        // Recording-first design: the audio engine + recogniser come
        // up immediately and the timer pill renders the next frame.
        // Page creation, navigation, and the initial text element are
        // deferred to `handleLiveTranscript`'s first non-empty
        // partial. The previous "create page first, navigate, mount
        // 14 page hosts, start recording" sequence consolidated tens
        // of SwiftData fetches, SwiftUI rebuilds, and PencilKit canvas
        // mounts into the same render cycle as the recording-state
        // publish — wedging main on multi-page notebooks. Splitting
        // the work along the "user has actually said something" line
        // lets the recording UI come up while the page-mount storm
        // happens later, once the user is already speaking.
        let recorder = LectureRecorder()
        do {
            let nbId = notebookId
            // Use the source page id so the recorder's audio file
            // lands under the right notebook (the recorder only
            // needs the notebook scope; the page id is informational
            // here since the real dictation page hasn't been created
            // yet). The fromPageId is a stable, already-existing page
            // owned by the same notebook.
            let bootstrapPageId = fromPageId
            try await withDictationTimeout(seconds: 8) {
                try await recorder.start(pageId: bootstrapPageId, notebookId: nbId)
            }
            #if DEBUG
            dlog("[Dictation] LectureRecorder.start succeeded")
            #endif
        } catch let error as DictationTimeoutError {
            #if DEBUG
            dlog("[Dictation] ABORT — recorder.start timed out: \(error)")
            #endif
            interruptionMessage = "Dictation took too long to start. Tap the dictation button again in a moment — iCloud may be syncing in the background."
            Task { _ = await recorder.stop() }
            return
        } catch {
            #if DEBUG
            dlog("[Dictation] ABORT — LectureRecorder.start threw: \(error)")
            #endif
            interruptionMessage = "Couldn't start dictation."
            return
        }

        // Store the lazy-create hooks so the first-word handler can
        // fire them off the audio thread → main hop, not on the
        // synchronous tap path.
        dictationCreatePage = createNewPage
        dictationNavigate = navigateToPage
        dictationPageSize = pageSize

        let contentId = UUID()
        dictationRecorder = recorder
        state = .dictation(DictationContext(
            audioContentId: contentId,
            originalPageId: nil,
            currentPageId: nil,
            notebookId: notebookId,
            startTime: Date(),
            textElementIds: []
        ))
        startElapsedTimer()
        subscribeLiveTranscript(recorder)
        #if DEBUG
        dlog("[Dictation] startDictation completed — awaiting first transcript word to materialise page")
        #endif
    }

    /// Fired from `handleLiveTranscript` on the first non-empty
    /// transcript partial. Creates the dictation page, the initial
    /// text element, mutates the state's `originalPageId` /
    /// `currentPageId` / `textElementIds`, and navigates the editor
    /// to the new page. Returns the newly-minted text element id so
    /// the caller can immediately write the transcript into it. Nil
    /// return = lazy creation failed (no closures, no page returned);
    /// caller drops the tick and the next partial retries.
    @discardableResult
    private func materializeDictationPage(ctx: inout DictationContext) -> UUID? {
        guard let createPage = dictationCreatePage,
              let navigate = dictationNavigate else {
            #if DEBUG
            dlog("[Dictation] materialiseDictationPage — no hooks stored, dropping")
            #endif
            return nil
        }
        guard let newPage = createPage() else {
            #if DEBUG
            dlog("[Dictation] materialiseDictationPage — createPage returned nil")
            #endif
            return nil
        }
        let firstTextId = DictationFlowCommit.createInitialTextElement(
            pageId: newPage.id,
            notebookId: ctx.notebookId,
            pageSize: dictationPageSize
        )
        ctx.originalPageId = newPage.id
        ctx.currentPageId = newPage.id
        ctx.textElementIds = [firstTextId]
        navigate(newPage.id)
        #if DEBUG
        dlog("[Dictation] materialiseDictationPage — page=\(newPage.id) elementId=\(firstTextId)")
        #endif
        return firstTextId
    }

    private func subscribeLiveTranscript(_ recorder: LectureRecorder) {
        #if DEBUG
        dlog("[Dictation] subscribeLiveTranscript phase=enter")
        #endif
        recorder.$liveTranscript
            // Drop the initial "" emission so we don't spam an
            // empty `updateText` to SwiftData before the recogniser
            // has produced any real partial. The previous wiring
            // logged `routing 0 chars` on every dictation start —
            // harmless but noisy, and obscured whether real
            // partials were arriving.
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                self?.handleLiveTranscript(transcript)
            }
            .store(in: &cancellables)
        #if DEBUG
        dlog("[Dictation] subscribeLiveTranscript phase=stored")
        #endif
    }

    /// Stream the live transcript into the active dictation's
    /// current TextContent. Heuristic overflow check: when the
    /// running transcript on the current page exceeds
    /// `charsPerPage`, find the last sentence boundary within
    /// the buffer and split — earlier portion stays on the
    /// current TextContent, remainder seeds a new TextContent on
    /// a new page.
    private func handleLiveTranscript(_ transcript: String) {
        guard case .dictation(var ctx) = state else {
            #if DEBUG
            dlog("[Dictation] handleLiveTranscript dropped — state not dictation (\(state))")
            #endif
            return
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Lazy page-creation: the first non-empty partial is what
        // triggers the new page + initial text element. Until then
        // the recorder is rolling but the editor is unchanged — the
        // user sees the timer pill on whatever page they were on.
        if ctx.textElementIds.isEmpty {
            guard !trimmed.isEmpty else { return }
            #if DEBUG
            dlog("[Dictation] handleLiveTranscript first-word — materialising page")
            #endif
            guard materializeDictationPage(ctx: &ctx) != nil else { return }
            state = .dictation(ctx)
        }
        guard let currentTextId = ctx.textElementIds.last else {
            #if DEBUG
            dlog("[Dictation] handleLiveTranscript dropped — no current text element id post-materialise")
            #endif
            return
        }

        #if DEBUG
        dlog("[Dictation] handleLiveTranscript routing \(trimmed.count) chars → textElement=\(currentTextId)")
        #endif
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
        guard let currentPageId = ctx.currentPageId,
              let next = DictationFlowCommit.createContinuationPage(
                afterPageId: currentPageId,
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
        // `ceciliasnotes.transcription.auto` setting (architecture intent:
        // dictation always transcribes, voice notes are user-
        // configurable).
        let autoTranscribe = UserDefaults.standard
            .object(forKey: "ceciliasnotes.transcription.auto") as? Bool ?? true
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

        // No page was materialised — the user tapped stop before
        // the recogniser delivered any content. Discard the empty
        // recording so the directory doesn't accumulate orphaned
        // m4a stubs and skip the commit entirely. The audio file
        // exists on disk under MediaStorage.lectures/<recordId>; the
        // recorder owns its own URL and won't expose it past stop().
        guard let originalPageId = ctx.originalPageId else {
            #if DEBUG
            dlog("[Dictation] stopDictation — no page materialised, discarding empty recording")
            #endif
            try? FileManager.default.removeItem(at: result.audioURL)
            resetSession()
            return
        }

        let contentId = ctx.audioContentId
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
        dictationCreatePage = nil
        dictationNavigate = nil
        dictationPageSize = .zero
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

// MARK: - Dictation timeout helper

/// Thrown when the time-boxed dictation start path exceeds its
/// budget. The caller surfaces a user-visible "try again in a
/// moment" message instead of letting the app sit on a wedged
/// audio engine.
struct DictationTimeoutError: Error {}

/// Race a throwing async operation against a timeout. Returns the
/// op's result if it finishes first, throws `DictationTimeoutError`
/// otherwise. The losing task is cancelled — but a wedged audio
/// engine doesn't honour cooperative cancellation, so the caller
/// must still tear down the partial state on the timeout branch
/// (see `RecordingSession.startDictation`).
@MainActor
private func withDictationTimeout<T: Sendable>(
    seconds: Double,
    op: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DictationTimeoutError()
        }
        guard let result = try await group.next() else {
            throw DictationTimeoutError()
        }
        group.cancelAll()
        return result
    }
}
