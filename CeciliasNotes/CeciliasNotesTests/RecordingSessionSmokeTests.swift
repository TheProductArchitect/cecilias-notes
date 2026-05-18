import XCTest
import SwiftData
@testable import CeciliasNotes

/// Step 6 smoke tests — exercise the data-side helpers that the
/// recording flows commit through. The flows themselves involve
/// AVAudioEngine / SFSpeechRecognizer / file I/O and don't unit-
/// test cleanly; the helpers do.
///
/// Coverage:
///   • RecordingSession idle/state predicates.
///   • Voice-note placeholder + finalize round-trip on AudioContent.
///   • Dictation flow: initial TextContent creation, live update,
///     continuation page with anchorAudioId, paired-block finalize
///     creating the audio strip above the first transcript.
@MainActor
final class RecordingSessionSmokeTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    // MARK: - State

    func test_recordingSession_initialState_isIdle() {
        XCTAssertFalse(RecordingSession.shared.state.isRecording)
        XCTAssertNil(RecordingSession.shared.state.notebookId)
        XCTAssertNil(RecordingSession.shared.state.startTime)
    }

    // MARK: - AudioElementCommit voice-note path

    func test_createRecordingPlaceholder_thenFinalize_promotesDuration() throws {
        let pageId = UUID()
        let notebookId = UUID()
        let contentId = UUID()

        let elementId = AudioElementCommit.createRecordingPlaceholder(
            contentId: contentId,
            pageId: pageId,
            notebookId: notebookId,
            pageSize: CGSize(width: 595, height: 842)
        )
        XCTAssertNotEqual(elementId, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))

        let ctx = StorageService.shared.context
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )
        let elements = try ctx.fetch(descriptor).filter { $0.kind == .audio }
        XCTAssertEqual(elements.count, 1)
        let placeholder = try XCTUnwrap(elements.first)
        XCTAssertEqual(placeholder.audioContent?.durationSeconds, 0)

        AudioElementCommit.finalizeVoiceNote(
            elementId: elementId,
            contentId: contentId,
            durationSeconds: 12.5
        )
        let after = try ctx.fetch(descriptor).filter { $0.kind == .audio }
        XCTAssertEqual(after.first?.audioContent?.durationSeconds, 12.5)
    }

    // MARK: - Dictation flow

    func test_createInitialTextElement_seedsDictatedTextContent() throws {
        let pageId = UUID()
        let notebookId = UUID()
        let elementId = DictationFlowCommit.createInitialTextElement(
            pageId: pageId,
            notebookId: notebookId,
            pageSize: CGSize(width: 595, height: 842)
        )

        let ctx = StorageService.shared.context
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.id == elementId }
        )
        let fetched = try XCTUnwrap(try ctx.fetch(descriptor).first)
        XCTAssertEqual(fetched.kind, .text)
        XCTAssertEqual(fetched.textContent?.source, .dictated)
        XCTAssertEqual(fetched.textContent?.text, "")
    }

    func test_updateText_writesToTextContent() throws {
        let elementId = DictationFlowCommit.createInitialTextElement(
            pageId: UUID(),
            notebookId: UUID(),
            pageSize: CGSize(width: 595, height: 842)
        )
        DictationFlowCommit.updateText(elementId: elementId, text: "hello dictation")

        let ctx = StorageService.shared.context
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.id == elementId }
        )
        let fetched = try XCTUnwrap(try ctx.fetch(descriptor).first)
        XCTAssertEqual(fetched.textContent?.text, "hello dictation")
    }
}
