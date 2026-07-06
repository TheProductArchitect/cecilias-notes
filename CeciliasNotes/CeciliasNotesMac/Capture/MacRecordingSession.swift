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
        let textElementId: UUID
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

    /// Live speech-to-text for meetings — places text intelligently and
    /// streams partial results to the page + live bar.
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
            startTime: Date()
        ))
        liveTranscript = ""
        subscribeLiveTranscript(recorder, textElementId: textElementId)
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
        AudioElementCommit.finalizeVoiceNote(
            elementId: ctx.audioElementId,
            contentId: ctx.audioContentId,
            durationSeconds: result.duration
        )
        let url = MediaStorage.url(for: .audio, id: ctx.audioContentId)
        Task.detached(priority: .utility) {
            if let transcript = await SpeechTranscriber.shared.transcribeFile(url: url)?.text,
               !transcript.isEmpty {
                await MainActor.run {
                    AudioElementCommit.updateTranscript(contentId: ctx.audioContentId, transcript: transcript)
                }
            }
        }
    }

    private func stopTranscription(_ ctx: TranscriptionContext) async {
        guard let recorder = lectureRecorder else { return }
        guard let result = await recorder.stop() else { return }
        let storage = StorageService.shared
        let pageSize = storage.fetchPage(id: ctx.pageId)?.pageSize.pointSize ?? PageSize.a4.pointSize

        let finalText = result.transcript.isEmpty ? liveTranscript : result.transcript
        if !finalText.isEmpty {
            MacDictationFlowCommit.finalizeTextElement(elementId: ctx.textElementId, text: finalText)
        }

        let textElementId = ctx.textElementId
        let textElement: PageElement? = {
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> { $0.id == textElementId }
            )
            return try? storage.context.fetch(descriptor).first
        }()

        let marginX = MacDocPageLayout.normalizedHorizontalMargin(pageWidth: pageSize.width)
        let contentWidth = MacDocPageLayout.normalizedContentWidth(pageWidth: pageSize.width)
        let audioY: Double
        if let textElement {
            audioY = min(0.92, textElement.normalizedY + textElement.normalizedHeight + 0.02)
        } else {
            audioY = MacDocPageLayout.normalizedTopMargin(pageHeight: pageSize.height)
        }

        _ = AudioElementCommit.commit(
            contentId: result.recordId,
            pageId: ctx.pageId,
            notebookId: ctx.notebookId,
            pageSize: pageSize,
            durationSeconds: result.durationSeconds,
            transcript: "",
            normalizedY: audioY,
            normalizedX: marginX,
            normalizedWidth: contentWidth
        )

        NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        postScroll(to: ctx.pageId)
    }

    private func subscribeLiveTranscript(_ recorder: LectureRecorder, textElementId: UUID) {
        recorder.$liveTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                guard let self else { return }
                self.liveTranscript = transcript
                MacDictationFlowCommit.updateText(elementId: textElementId, text: transcript)
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
    }
}
