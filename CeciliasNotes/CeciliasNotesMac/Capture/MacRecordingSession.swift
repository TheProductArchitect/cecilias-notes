import Combine
import Foundation
import SwiftData
import SwiftUI

/// Mac recording coordinator — voice memo + live transcription.
@MainActor
final class MacRecordingSession: ObservableObject {
    static let shared = MacRecordingSession()

    enum Mode: Equatable {
        case idle
        case voiceMemo(VoiceMemoContext)
        case transcription(TranscriptionContext)

        var isActive: Bool {
            if case .idle = self { return false }
            return true
        }

        var isTranscribing: Bool {
            if case .transcription = self { return true }
            return false
        }

        var notebookId: UUID? {
            switch self {
            case .idle: return nil
            case .voiceMemo(let ctx): return ctx.notebookId
            case .transcription(let ctx): return ctx.notebookId
            }
        }

        var pageId: UUID? {
            switch self {
            case .idle: return nil
            case .voiceMemo(let ctx): return ctx.pageId
            case .transcription(let ctx): return ctx.pageId
            }
        }

        var textElementId: UUID? {
            if case .transcription(let ctx) = self { return ctx.textElementId }
            return nil
        }
    }

    struct VoiceMemoContext: Equatable {
        let audioElementId: UUID
        let audioContentId: UUID
        let pageId: UUID
        let notebookId: UUID
        let startTime: Date
    }

    struct TranscriptionContext: Equatable {
        let audioContentId: UUID
        let pageId: UUID
        let notebookId: UUID
        /// Current live-write target — moves to the continuation
        /// block after a page-overflow split.
        let textElementId: UUID
        /// The block the transcription STARTED in — stable across
        /// splits. The meeting summary is inserted above this one.
        let firstTextElementId: UUID
        let startTime: Date
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var liveTranscript: String = ""
    @Published var lastErrorMessage: String?

    private var audioRecorder: AudioRecorder?
    private var lectureRecorder: LectureRecorder?
    private var cancellables = Set<AnyCancellable>()
    private var elapsedTimer: Timer?

    /// UTF-16 length of the transcript already frozen into earlier
    /// blocks by overflow splits. `liveTranscript` is cumulative
    /// (committed + partial), so after a split only the tail beyond
    /// this offset belongs to the current target block — writing the
    /// full transcript again would duplicate everything already on
    /// the previous page.
    private var transcriptConsumedUTF16 = 0

    private init() {}

    func startVoiceMemo(page: Page, notebook: Notebook) async {
        guard case .idle = mode else { return }
        lastErrorMessage = nil
        let recorder = AudioRecorder()
        do {
            try await recorder.requestPermission()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 200_000_000)
            let contentId = UUID()
            MediaStorage.ensureDirectoriesExist()
            let fileURL = MediaStorage.url(for: .audio, id: contentId)
            try await recorder.start(outputURL: fileURL)
            let elementId = AudioElementCommit.createRecordingPlaceholder(
                contentId: contentId,
                pageId: page.id,
                notebookId: notebook.id,
                pageSize: page.pageSize.pointSize
            )
            audioRecorder = recorder
            mode = .voiceMemo(VoiceMemoContext(
                audioElementId: elementId,
                audioContentId: contentId,
                pageId: page.id,
                notebookId: notebook.id,
                startTime: Date()
            ))
            startElapsedTimer()
            postScroll(to: page.id)
        } catch {
            lastErrorMessage = "Could not start voice note — check microphone access."
            reset()
        }
    }

    /// Live speech-to-text — streams words into an in-page text block.
    @discardableResult
    func startTranscription(page: Page, notebook: Notebook) async -> UUID? {
        guard case .idle = mode else { return nil }
        lastErrorMessage = nil

        let storage = StorageService.shared
        let anchor = MacDictationFlowCommit.resolveTranscriptionAnchor(
            startingPage: page,
            notebook: notebook,
            storage: storage
        )

        let recorder = LectureRecorder()
        do {
            try await recorder.start(pageId: anchor.page.id, notebookId: notebook.id)
        } catch {
            lastErrorMessage = transcriptionStartErrorMessage(error)
            #if DEBUG
            print("[Transcription] LectureRecorder.start failed: \(error)")
            #endif
            return nil
        }

        let textElementId = MacDictationFlowCommit.createInitialTextElement(
            pageId: anchor.page.id,
            notebookId: notebook.id,
            pageSize: anchor.page.pageSize.pointSize,
            normalizedY: anchor.normalizedY
        )

        lectureRecorder = recorder
        mode = .transcription(TranscriptionContext(
            audioContentId: UUID(),
            pageId: anchor.page.id,
            notebookId: notebook.id,
            textElementId: textElementId,
            firstTextElementId: textElementId,
            startTime: Date()
        ))
        liveTranscript = ""
        transcriptConsumedUTF16 = 0
        subscribeLiveTranscript(recorder)
        startElapsedTimer()

        NotificationCenter.default.post(
            name: .macTranscriptionStarted,
            object: nil,
            userInfo: [
                MacHandoff.pageIdKey: anchor.page.id,
                MacTranscriptionKeys.elementId: textElementId,
            ]
        )
        postScroll(to: anchor.page.id, elementId: textElementId)
        return textElementId
    }

    /// Move live transcript updates to a continuation block after an
    /// overflow split. `consumedUTF16` is how much of the *current
    /// target's* text stayed behind on the previous block; it extends
    /// the session-wide consumed prefix.
    func retargetTranscription(to elementId: UUID, consumedUTF16: Int) {
        guard case .transcription(let ctx) = mode else { return }
        transcriptConsumedUTF16 += max(0, consumedUTF16)
        mode = .transcription(TranscriptionContext(
            audioContentId: ctx.audioContentId,
            pageId: ctx.pageId,
            notebookId: ctx.notebookId,
            textElementId: elementId,
            firstTextElementId: ctx.firstTextElementId,
            startTime: ctx.startTime
        ))
    }

    /// Retarget live transcription only when the split block is the
    /// current write target — no-op for manual typing splits.
    func retargetIfWriting(from elementId: UUID, to continuationId: UUID, consumedUTF16: Int) {
        guard case .transcription(let ctx) = mode, ctx.textElementId == elementId else { return }
        retargetTranscription(to: continuationId, consumedUTF16: consumedUTF16)
    }

    /// The tail of `transcript` not yet frozen into earlier blocks.
    private func unconsumedTail(of transcript: String) -> String {
        guard transcriptConsumedUTF16 > 0 else { return transcript }
        let ns = transcript as NSString
        guard transcriptConsumedUTF16 < ns.length else { return "" }
        return ns.substring(from: transcriptConsumedUTF16)
    }

    func stop() async {
        switch mode {
        case .idle:
            return
        case .voiceMemo(let ctx):
            await stopVoiceMemo(ctx)
        case .transcription(let ctx):
            await stopTranscription(ctx)
        }
        reset()
    }

    private func stopVoiceMemo(_ ctx: VoiceMemoContext) async {
        guard let recorder = audioRecorder else { return }
        guard let result = try? await recorder.stop() else { return }

        let saveAudio = UserDefaults.standard
            .object(forKey: "ceciliasnotes.audio.saveClips") as? Bool ?? true
        let autoTranscribe = UserDefaults.standard
            .object(forKey: "ceciliasnotes.transcription.auto") as? Bool ?? true
        let url = MediaStorage.url(for: .audio, id: ctx.audioContentId)

        guard saveAudio || autoTranscribe else {
            AudioElementCommit.discardRecordingPlaceholder(elementId: ctx.audioElementId)
            try? FileManager.default.removeItem(at: url)
            return
        }

        guard saveAudio else {
            AudioElementCommit.discardRecordingPlaceholder(elementId: ctx.audioElementId)
            let pageId = ctx.pageId
            Task(priority: .utility) {
                let transcript = await SpeechTranscriber.shared.transcribeFile(url: url)
                try? FileManager.default.removeItem(at: url)
                guard let text = transcript?.text, !text.isEmpty else { return }
                await MainActor.run {
                    guard let page = StorageService.shared.fetchPage(id: pageId) else { return }
                    _ = try? StorageService.shared.createTextBlock(on: page, content: text)
                }
            }
            return
        }

        AudioElementCommit.finalizeVoiceNote(
            elementId: ctx.audioElementId,
            contentId: ctx.audioContentId,
            durationSeconds: result.duration
        )

        if autoTranscribe {
            let contentId = ctx.audioContentId
            Task.detached(priority: .utility) {
                await SpeechTranscriber.shared.transcribe(url: url, annotationId: contentId)
            }
        }
    }

    private func stopTranscription(_ ctx: TranscriptionContext) async {
        guard let recorder = lectureRecorder else { return }
        guard let result = await recorder.stop() else { return }
        let storage = StorageService.shared

        let fullTranscript = result.transcript.isEmpty ? liveTranscript : result.transcript
        let finalText = unconsumedTail(of: fullTranscript)
        if !finalText.isEmpty {
            MacDictationFlowCommit.finalizeTextElement(elementId: ctx.textElementId, text: finalText)
        }

        // Finalizing can split once more — the live target in `mode` is
        // authoritative for where the transcript actually ended.
        let finalElementId = mode.textElementId ?? ctx.textElementId
        let textElement: PageElement? = {
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> { $0.id == finalElementId }
            )
            return try? storage.context.fetch(descriptor).first
        }()

        // After overflow splits the last block lives on a later page —
        // anchor the audio strip there, not on the page dictation started.
        let anchorPageId = textElement?.pageId ?? ctx.pageId
        let pageSize = storage.fetchPage(id: anchorPageId)?.pageSize.pointSize ?? PageSize.a4.pointSize

        let saveAudio = UserDefaults.standard
            .object(forKey: "ceciliasnotes.audio.saveClips") as? Bool ?? true

        var targetPageId = anchorPageId
        if saveAudio {
            let adopted = await MediaStorage.adoptAudio(at: result.audioURL, id: result.recordId)
            guard adopted != nil else {
                lastErrorMessage = "Recording couldn't be saved. Please check storage and try again."
                try? FileManager.default.removeItem(at: result.audioURL)
                return
            }

            let marginX = MacDocPageLayout.normalizedHorizontalMargin(pageWidth: pageSize.width)
            let contentWidth = MacDocPageLayout.normalizedContentWidth(pageWidth: pageSize.width)
            // Order (summary → audio → transcript): the audio pill sits
            // directly ABOVE the transcript, not after it. Placing it
            // after the transcript pushed the pill far down a long
            // transcript ("text and audio pill are far away"); the
            // reflow packs strictly by normalizedY, so a Y just above
            // the transcript's puts the pill adjacent to the transcript
            // top. The summary lands above the pill (it inserts above
            // the page's topmost element — see MacMeetingSummary).
            let audioY: Double
            if let textElement {
                audioY = max(
                    MacDocPageLayout.normalizedTopMargin(pageHeight: pageSize.height),
                    textElement.normalizedY - 0.001
                )
            } else {
                audioY = MacDocPageLayout.normalizedTopMargin(pageHeight: pageSize.height)
            }

            _ = AudioElementCommit.commit(
                contentId: result.recordId,
                pageId: targetPageId,
                notebookId: ctx.notebookId,
                pageSize: pageSize,
                durationSeconds: result.durationSeconds,
                transcript: "",
                normalizedY: audioY,
                normalizedX: marginX,
                normalizedWidth: contentWidth
            )
        } else {
            try? FileManager.default.removeItem(at: result.audioURL)
        }

        for pageId in Set([ctx.pageId, anchorPageId, targetPageId]) {
            MacPageElementReflow.packVerticalLayout(pageId: pageId)
        }
        NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        postScroll(to: targetPageId)

        // Meeting-assistant tail, in order: (1) restructure the
        // transcript in place — paragraphs, topic headings, speaker
        // labels, words verbatim — then (2) distill the summary and
        // place it above the transcript. Restructuring only applies
        // when the transcript stayed in one block; re-splitting
        // already-overflowed pages around reformatted text isn't
        // worth a mis-seamed transcript. Both steps no-op quietly
        // when Apple Intelligence isn't available.
        let firstElementId = ctx.firstTextElementId
        let notebookId = ctx.notebookId
        let startPageId = ctx.pageId
        let singleBlock = transcriptConsumedUTF16 == 0
        Task { @MainActor in
            if singleBlock,
               let structured = await TranscriptStructurer.structureIfFaithful(fullTranscript) {
                MacDictationFlowCommit.applyTextUpdate(elementId: firstElementId, text: structured)
                MacPageElementReflow.packVerticalLayout(pageId: startPageId)
                NotificationCenter.default.post(name: .textElementsChanged, object: nil)
            }
            MacMeetingSummary.generateIfWorthwhile(
                transcript: fullTranscript,
                firstElementId: firstElementId,
                notebookId: notebookId
            )
        }
    }

    private func subscribeLiveTranscript(_ recorder: LectureRecorder) {
        recorder.$liveTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                guard let self,
                      case .transcription(let ctx) = self.mode else { return }
                self.liveTranscript = transcript
                let tail = self.unconsumedTail(of: transcript)
                // An empty tail after a split means the recognizer
                // revised the transcript shorter than the frozen
                // prefix — don't blank the continuation block over it.
                guard !tail.isEmpty || self.transcriptConsumedUTF16 == 0 else { return }
                MacDictationFlowCommit.updateText(elementId: ctx.textElementId, text: tail)
            }
            .store(in: &cancellables)
    }

    private func postScroll(to pageId: UUID, elementId: UUID? = nil) {
        var userInfo: [AnyHashable: Any] = [MacHandoff.pageIdKey: pageId]
        if let elementId {
            userInfo[MacTranscriptionKeys.elementId] = elementId
        }
        NotificationCenter.default.post(
            name: .macScrollToRecordingPage,
            object: nil,
            userInfo: userInfo
        )
    }

    private func transcriptionStartErrorMessage(_ error: Error) -> String {
        if let lectureError = error as? LectureRecorderError {
            switch lectureError {
            case .microphoneDenied:
                return "Microphone access is required for transcription."
            }
        }
        return "Could not start transcription. Check microphone and speech recognition permissions."
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let start = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
    }

    private func reset() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        cancellables.removeAll()
        audioRecorder = nil
        lectureRecorder = nil
        mode = .idle
        elapsedSeconds = 0
        liveTranscript = ""
        transcriptConsumedUTF16 = 0
    }
}
