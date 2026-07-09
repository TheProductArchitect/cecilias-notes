import XCTest
import SwiftData
@testable import CeciliasNotes

/// Regression suite for the post-dictation summary commit — the
/// "post diction and summary" window where device crashes were
/// reported. `MeetingSummarizer.canRun` is always false in the
/// simulator, so without driving `prependSummary` directly this
/// entire write path (attributed-string archiving, geometry math,
/// SwiftData save, notification fan-out) ships untested.
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

    private func makeNotebookPageElement(
        normalizedY: Double = 0.1,
        normalizedHeight: Double = 0.1,
        transcript: String = "we agreed to ship the beta on friday and cecilia owns the release notes"
    ) throws -> (notebookId: UUID, pageId: UUID, elementId: UUID) {
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
            normalizedY: normalizedY,
            normalizedWidth: 0.8,
            normalizedHeight: normalizedHeight,
            zIndex: 1
        )
        element.textContent = TextContent(text: transcript, source: .dictated)
        storage.context.insert(element)
        try storage.context.save()
        return (notebook.id, page.id, element.id)
    }

    private func fetchElement(_ id: UUID) throws -> PageElement {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == id }
        )
        return try XCTUnwrap(StorageService.shared.context.fetch(descriptor).first)
    }

    // MARK: - Happy path

    func test_prependSummary_putsSummaryAboveTranscript_andArchivesAttributed() throws {
        let ids = try makeNotebookPageElement()
        let summary = "Beta ships friday. Cecilia owns release notes."

        MeetingSummaryCommit.prependSummary(
            summary, toElementId: ids.elementId, notebookId: ids.notebookId
        )

        let element = try fetchElement(ids.elementId)
        let content = try XCTUnwrap(element.textContent)
        XCTAssertTrue(content.text.hasPrefix("Summary\n\(summary)\n\n"),
                      "Summary must be prepended above the transcript")
        XCTAssertTrue(content.text.hasSuffix("owns the release notes"),
                      "Transcript must be preserved verbatim below the summary")

        // The archived attributed string must decode and mirror the
        // plain text's structure — a decode failure here is exactly
        // the poisoned-block state a device crash would leave behind.
        let data = try XCTUnwrap(content.attributedTextData)
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
        )
        XCTAssertTrue(decoded.string.hasPrefix("SUMMARY\n"))
        XCTAssertTrue(decoded.string.contains(summary))
    }

    func test_prependSummary_growsElement_withinPageBounds() throws {
        let ids = try makeNotebookPageElement(normalizedY: 0.1, normalizedHeight: 0.05)
        let longSummary = Array(repeating: "a decision was made about the roadmap.", count: 20)
            .joined(separator: " ")

        MeetingSummaryCommit.prependSummary(
            longSummary, toElementId: ids.elementId, notebookId: ids.notebookId
        )

        let element = try fetchElement(ids.elementId)
        XCTAssertGreaterThanOrEqual(element.normalizedHeight, 0.05,
                                    "Element must not shrink")
        XCTAssertLessThanOrEqual(element.normalizedHeight, 0.92 - element.normalizedY + 0.0001,
                                 "Element must stay within the page")
        XCTAssertGreaterThan(element.normalizedHeight, 0,
                             "Geometry must never go non-positive")
        XCTAssertTrue(element.normalizedHeight.isFinite)
    }

    // MARK: - The geometry trap: element parked near the page bottom

    func test_prependSummary_elementBelowPageCap_neverWritesNegativeHeight() throws {
        // normalizedY = 0.95 puts the cap (0.92 - y) at -0.03: the
        // pre-guard code assigned min(-0.03, …) — a NEGATIVE height
        // that every subsequent render of the element inherits.
        let ids = try makeNotebookPageElement(normalizedY: 0.95, normalizedHeight: 0.04)

        MeetingSummaryCommit.prependSummary(
            "Short summary.", toElementId: ids.elementId, notebookId: ids.notebookId
        )

        let element = try fetchElement(ids.elementId)
        XCTAssertEqual(element.normalizedHeight, 0.04, accuracy: 0.0001,
                       "Height must be left alone when the cap is below the current height")
        XCTAssertGreaterThan(element.normalizedHeight, 0)

        // The text itself must still commit — geometry safety must
        // not cost the user their summary.
        let content = try XCTUnwrap(element.textContent)
        XCTAssertTrue(content.text.hasPrefix("Summary\n"))
    }

    // MARK: - Missing rows degrade to no-ops

    func test_prependSummary_missingElement_isQuietNoOp() throws {
        MeetingSummaryCommit.prependSummary(
            "Orphan summary.", toElementId: UUID(), notebookId: UUID()
        )
        // Passes by not crashing and not inserting anything.
        let descriptor = FetchDescriptor<PageElement>()
        let all = (try? StorageService.shared.context.fetch(descriptor)) ?? []
        XCTAssertTrue(all.allSatisfy { $0.textContent?.text.contains("Orphan") != true })
    }

    // MARK: - Pre-styled block round-trip

    func test_prependSummary_preservesExistingAttributedText() throws {
        let ids = try makeNotebookPageElement()
        let element = try fetchElement(ids.elementId)
        let content = try XCTUnwrap(element.textContent)

        // Simulate the structurer having already written attributed
        // data for the block (the structure → summary sequence).
        let styled = NSAttributedString(
            string: content.text,
            attributes: RichTextController.defaultAttributes(ink: .label)
        )
        content.attributedTextData = try NSKeyedArchiver.archivedData(
            withRootObject: styled, requiringSecureCoding: true
        )
        try StorageService.shared.context.save()

        MeetingSummaryCommit.prependSummary(
            "Recap.", toElementId: ids.elementId, notebookId: ids.notebookId
        )

        let updated = try XCTUnwrap(try fetchElement(ids.elementId).textContent)
        let data = try XCTUnwrap(updated.attributedTextData)
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
        )
        XCTAssertTrue(decoded.string.hasPrefix("SUMMARY\nRecap.\n\n"))
        XCTAssertTrue(decoded.string.hasSuffix("owns the release notes"),
                      "Pre-styled transcript must survive the prepend")
    }
}
