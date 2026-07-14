import XCTest
import SwiftData
@testable import CeciliasNotes

/// Regression suite for the post-dictation summary commit — the
/// "post diction and summary" window where device crashes were
/// reported. `MeetingSummarizer.canRun` is always false in the
/// simulator, so without driving `commitSummary` directly this
/// entire write path (attributed-string archiving, geometry math,
/// SwiftData save, notification fan-out) ships untested.
///
/// The summary is now a SEPARATE text element placed above the audio
/// pill (order: summary → pill → transcript), not prepended into the
/// transcript. These tests lock in the ordering AND the geometry
/// clamps that keep the write off the poisoned-geometry crash path.
@MainActor
final class MeetingSummaryCommitTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeNotebookWithTranscript(
        transcriptY: Double = 0.1,
        transcriptHeight: Double = 0.1,
        transcript: String = "we agreed to ship the beta on friday and cecilia owns the release notes"
    ) throws -> (notebookId: UUID, pageId: UUID, transcriptId: UUID) {
        let storage = StorageService.shared
        let notebook = try storage.createNotebook(
            title: "Summary Test",
            subjectId: nil,
            coverColorHex: "#000000",
            coverTexture: .linen,
            pageSize: .a4,
            template: .blank
        )
        let page = try XCTUnwrap(storage.fetchPages(in: notebook).first)

        let element = PageElement(
            id: UUID(),
            pageId: page.id,
            notebookId: notebook.id,
            kind: .text,
            normalizedX: 0.1,
            normalizedY: transcriptY,
            normalizedWidth: 0.8,
            normalizedHeight: transcriptHeight,
            zIndex: 1
        )
        element.textContent = TextContent(text: transcript, source: .dictated)
        storage.context.insert(element)
        try storage.context.save()
        return (notebook.id, page.id, element.id)
    }

    /// Adds an audio pill above the transcript (as `finalizeDictation`
    /// does at stop) so the ordering can be exercised.
    private func addPill(notebookId: UUID, pageId: UUID, y: Double, height: Double = 0.04) throws -> UUID {
        let storage = StorageService.shared
        let pill = PageElement(
            id: UUID(),
            pageId: pageId,
            notebookId: notebookId,
            kind: .audio,
            normalizedX: 0.1,
            normalizedY: y,
            normalizedWidth: 0.8,
            normalizedHeight: height,
            zIndex: 2
        )
        pill.audioContent = AudioContent(id: UUID(), filename: "a.m4a", durationSeconds: 3)
        storage.context.insert(pill)
        try storage.context.save()
        return pill.id
    }

    private func fetchElement(_ id: UUID) throws -> PageElement {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == id }
        )
        return try XCTUnwrap(StorageService.shared.context.fetch(descriptor).first)
    }

    private func elementsOnPage(_ pageId: UUID) -> [PageElement] {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pageId && $0.deletedAt == nil }
        )
        return (try? StorageService.shared.context.fetch(descriptor)) ?? []
    }

    // MARK: - Happy path

    func test_commitSummary_insertsSeparateElement_andPreservesTranscript() throws {
        let ids = try makeNotebookWithTranscript()
        let summary = "Beta ships friday. Cecilia owns release notes."

        MeetingSummaryCommit.commitSummary(
            summary, transcriptElementId: ids.transcriptId, notebookId: ids.notebookId
        )

        // Transcript element is untouched (verbatim, still .dictated).
        let transcript = try fetchElement(ids.transcriptId)
        let tContent = try XCTUnwrap(transcript.textContent)
        XCTAssertEqual(tContent.text, "we agreed to ship the beta on friday and cecilia owns the release notes")
        XCTAssertEqual(tContent.source, .dictated)

        // A NEW summary element exists, is .ai, and carries the summary.
        let summaryEls = elementsOnPage(ids.pageId)
            .filter { $0.id != ids.transcriptId && $0.kind == .text }
        XCTAssertEqual(summaryEls.count, 1, "Exactly one summary element must be created")
        let summaryEl = try XCTUnwrap(summaryEls.first)
        let sContent = try XCTUnwrap(summaryEl.textContent)
        XCTAssertEqual(sContent.source, .ai)
        XCTAssertTrue(sContent.text.contains(summary))

        // Its archived attributed string decodes and leads with the eyebrow.
        let data = try XCTUnwrap(sContent.attributedTextData)
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
        )
        XCTAssertTrue(decoded.string.hasPrefix("SUMMARY\n"))
        XCTAssertTrue(decoded.string.contains(summary))
    }

    func test_commitSummary_ordersSummaryAbovePillAboveTranscript() throws {
        let ids = try makeNotebookWithTranscript(transcriptY: 0.12)
        // Pill sits just above the transcript, as at stop.
        let pillId = try addPill(notebookId: ids.notebookId, pageId: ids.pageId, y: 0.06)

        MeetingSummaryCommit.commitSummary(
            "Recap.", transcriptElementId: ids.transcriptId, notebookId: ids.notebookId
        )

        let transcript = try fetchElement(ids.transcriptId)
        let pill = try fetchElement(pillId)
        let summaryEl = try XCTUnwrap(
            elementsOnPage(ids.pageId).first { $0.id != ids.transcriptId && $0.kind == .text }
        )

        XCTAssertLessThan(summaryEl.normalizedY, pill.normalizedY,
                          "Summary must sit above the audio pill")
        XCTAssertLessThan(pill.normalizedY, transcript.normalizedY,
                          "Audio pill must sit above the transcript")
    }

    func test_commitSummary_allGeometryStaysWithinPageBounds() throws {
        let ids = try makeNotebookWithTranscript(transcriptY: 0.1, transcriptHeight: 0.05)
        _ = try addPill(notebookId: ids.notebookId, pageId: ids.pageId, y: 0.05)
        let longSummary = Array(repeating: "a decision was made about the roadmap.", count: 20)
            .joined(separator: " ")

        MeetingSummaryCommit.commitSummary(
            longSummary, transcriptElementId: ids.transcriptId, notebookId: ids.notebookId
        )

        for el in elementsOnPage(ids.pageId) {
            XCTAssertTrue(el.normalizedY.isFinite && el.normalizedHeight.isFinite,
                          "No element may carry non-finite geometry")
            XCTAssertGreaterThanOrEqual(el.normalizedY, 0)
            XCTAssertGreaterThan(el.normalizedHeight, 0)
            XCTAssertLessThanOrEqual(el.normalizedY, 0.92 + 0.0001)
        }
    }

    // MARK: - The geometry trap: transcript parked near the page bottom

    func test_commitSummary_transcriptNearBottom_neverWritesInvalidGeometry() throws {
        // A transcript at 0.95 leaves almost no room; the shift + clamp
        // must never push anything to a negative or non-finite value.
        let ids = try makeNotebookWithTranscript(transcriptY: 0.95, transcriptHeight: 0.04)

        MeetingSummaryCommit.commitSummary(
            "Short summary.", transcriptElementId: ids.transcriptId, notebookId: ids.notebookId
        )

        for el in elementsOnPage(ids.pageId) {
            XCTAssertTrue(el.normalizedY.isFinite)
            XCTAssertGreaterThanOrEqual(el.normalizedY, 0)
            XCTAssertLessThanOrEqual(el.normalizedY, 0.92 + 0.0001)
            XCTAssertGreaterThan(el.normalizedHeight, 0)
        }
        // The summary still commits — geometry safety must not cost
        // the user their summary.
        let summaryEls = elementsOnPage(ids.pageId)
            .filter { $0.id != ids.transcriptId && $0.kind == .text }
        XCTAssertEqual(summaryEls.count, 1)
    }

    // MARK: - Missing rows degrade to no-ops

    func test_commitSummary_missingElement_isQuietNoOp() throws {
        MeetingSummaryCommit.commitSummary(
            "Orphan summary.", transcriptElementId: UUID(), notebookId: UUID()
        )
        let descriptor = FetchDescriptor<PageElement>()
        let all = (try? StorageService.shared.context.fetch(descriptor)) ?? []
        XCTAssertTrue(all.allSatisfy { $0.textContent?.text.contains("Orphan") != true })
    }

    // MARK: - Pre-styled transcript is left alone

    func test_commitSummary_leavesExistingAttributedTextUntouched() throws {
        let ids = try makeNotebookWithTranscript()
        let transcript = try fetchElement(ids.transcriptId)
        let content = try XCTUnwrap(transcript.textContent)

        let styled = NSAttributedString(
            string: content.text,
            attributes: RichTextController.defaultAttributes(ink: .label)
        )
        let originalData = try NSKeyedArchiver.archivedData(
            withRootObject: styled, requiringSecureCoding: true
        )
        content.attributedTextData = originalData
        try StorageService.shared.context.save()

        MeetingSummaryCommit.commitSummary(
            "Recap.", transcriptElementId: ids.transcriptId, notebookId: ids.notebookId
        )

        // Transcript's own attributed payload is unchanged (the summary
        // lives in its own element now).
        let updated = try XCTUnwrap(try fetchElement(ids.transcriptId).textContent)
        XCTAssertEqual(updated.attributedTextData, originalData,
                       "Transcript attributed data must be untouched by the summary commit")
    }
}
