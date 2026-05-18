import XCTest
import SwiftData
@testable import CeciliasNotes

/// Step 5 smoke tests for the V6 audio element. Verifies:
///   • PageElement(kind: .audio) + AudioContent round-trip
///     through SwiftData with filename + duration + transcript.
///   • AudioContent.fileURL resolves through MediaStorage.
///   • TextContent.anchorAudioId field is queryable (used by
///     Step 6 dictation flow for multi-page continuation).
///   • Soft-delete hides from the overlay query.
@MainActor
final class AudioElementSmokeTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    func test_audioElement_insertAndFetch_preservesContent() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let notebookId = UUID()
        let contentId = UUID()

        let element = PageElement(
            pageId: pageId,
            notebookId: notebookId,
            kind: .audio,
            normalizedX: 0.05,
            normalizedY: 0.05,
            normalizedWidth: 0.5,
            normalizedHeight: 0.05
        )
        let content = AudioContent(
            id: contentId,
            filename: "\(contentId.uuidString).m4a",
            durationSeconds: 42.5,
            transcript: "step 5 lives"
        )
        element.audioContent = content
        ctx.insert(element)
        try ctx.save()

        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )
        let fetched = try ctx.fetch(descriptor).filter { $0.kind == .audio }
        XCTAssertEqual(fetched.count, 1)
        let row = try XCTUnwrap(fetched.first)
        XCTAssertEqual(row.audioContent?.transcript, "step 5 lives")
        XCTAssertEqual(row.audioContent?.durationSeconds, 42.5)
        XCTAssertEqual(row.audioContent?.filename, "\(contentId.uuidString).m4a")
    }

    func test_audioContent_fileURL_matchesMediaStorageConvention() {
        let id = UUID()
        let content = AudioContent(id: id, filename: "\(id.uuidString).m4a")
        XCTAssertEqual(content.fileURL, MediaStorage.url(for: .audio, id: id))
    }

    func test_textContent_anchorAudioId_isQueryable() throws {
        let ctx = container.mainContext
        let audioId = UUID()
        let text = TextContent(
            text: "continuation transcript",
            source: .dictated,
            anchorAudioId: audioId
        )
        ctx.insert(text)
        try ctx.save()

        let descriptor = FetchDescriptor<TextContent>(
            predicate: #Predicate { $0.anchorAudioId == audioId }
        )
        let fetched = try ctx.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.text, "continuation transcript")
    }

    func test_audioElement_softDelete_hidesFromOverlayQuery() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let element = PageElement(
            pageId: pageId,
            notebookId: UUID(),
            kind: .audio
        )
        element.audioContent = AudioContent(filename: "x.m4a", durationSeconds: 1)
        ctx.insert(element)
        try ctx.save()

        let pid = pageId
        let before = try ctx.fetch(FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )).filter { $0.kind == .audio }
        XCTAssertEqual(before.count, 1)

        element.deletedAt = Date()
        try ctx.save()

        let after = try ctx.fetch(FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )).filter { $0.kind == .audio }
        XCTAssertEqual(after.count, 0)
    }
}
