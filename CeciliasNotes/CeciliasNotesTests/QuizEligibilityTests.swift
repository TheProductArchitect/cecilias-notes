import SwiftData
import XCTest
@testable import CeciliasNotes

/// Integration tests for the quiz-eligibility pre-flight that drives
/// the builder's grey-out + (i) icon UI. Exercises QuizSourceCollector
/// over real SwiftData fixtures since the eligibility code calls it
/// directly. Lower-level than the view-side test (which would need
/// a SwiftUI host) — proves the data path.
@MainActor
final class QuizEligibilityTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    /// A notebook with at least one typed text element shows up as
    /// eligible — contentUnitCount > 0.
    func test_notebookWithTypedText_isEligible() throws {
        let ctx = container.mainContext
        let notebook = makeNotebook(in: ctx, title: "with text")
        let page = makePage(in: ctx, notebook: notebook)
        let element = PageElement(
            pageId: page.id,
            notebookId: notebook.id,
            kind: .text,
            normalizedX: 0.1, normalizedY: 0.1,
            normalizedWidth: 0.5, normalizedHeight: 0.05,
            zIndex: 1
        )
        element.textContent = TextContent(text: "lorem ipsum dolor")
        ctx.insert(element)
        try ctx.save()

        let scope = QuizScope(
            type: .notebook,
            notebookIDs: [notebook.id],
            includeTranscriptions: true
        )
        let count = QuizSourceCollector.contentUnitCount(scope: scope, context: ctx)
        XCTAssertGreaterThan(count, 0, "Expected typed text to register as quiz source")
    }

    /// A notebook whose only content is empty text elements is
    /// ineligible — whitespace-only text strings get filtered out
    /// before counting.
    func test_notebookWithOnlyEmptyText_isIneligible() throws {
        let ctx = container.mainContext
        let notebook = makeNotebook(in: ctx, title: "empty text")
        let page = makePage(in: ctx, notebook: notebook)
        let element = PageElement(
            pageId: page.id,
            notebookId: notebook.id,
            kind: .text,
            normalizedX: 0.1, normalizedY: 0.1,
            normalizedWidth: 0.5, normalizedHeight: 0.05,
            zIndex: 1
        )
        element.textContent = TextContent(text: "   \n  \t  ")
        ctx.insert(element)
        try ctx.save()

        let scope = QuizScope(
            type: .notebook,
            notebookIDs: [notebook.id],
            includeTranscriptions: true
        )
        let count = QuizSourceCollector.contentUnitCount(scope: scope, context: ctx)
        XCTAssertEqual(count, 0, "Whitespace-only text must not count as quiz source")
    }

    /// A subject with two eligible notebooks aggregates their text —
    /// confirms the subject-scope path is wired through.
    func test_subjectAggregatesAcrossNotebooks() throws {
        let ctx = container.mainContext
        let subject = Subject(name: "Maths", colorHex: "#FAFAF8")
        ctx.insert(subject)

        for i in 0..<2 {
            let nb = makeNotebook(in: ctx, title: "nb-\(i)", subjectId: subject.id)
            let page = makePage(in: ctx, notebook: nb)
            let element = PageElement(
                pageId: page.id, notebookId: nb.id,
                kind: .text,
                normalizedX: 0, normalizedY: 0,
                normalizedWidth: 0.5, normalizedHeight: 0.05,
                zIndex: 1
            )
            element.textContent = TextContent(text: "content \(i)")
            ctx.insert(element)
        }
        try ctx.save()

        let scope = QuizScope(
            type: .subject,
            subjectID: subject.id,
            subjectName: "Maths",
            includeTranscriptions: true
        )
        let count = QuizSourceCollector.contentUnitCount(scope: scope, context: ctx)
        XCTAssertEqual(count, 2)
    }

    /// includeTranscriptions=false excludes audio transcripts — guards
    /// the toggle in the builder.
    func test_transcriptionToggleControlsAudioInclusion() throws {
        let ctx = container.mainContext
        let notebook = makeNotebook(in: ctx, title: "with audio")
        let page = makePage(in: ctx, notebook: notebook)
        let element = PageElement(
            pageId: page.id, notebookId: notebook.id,
            kind: .audio,
            normalizedX: 0.1, normalizedY: 0.1,
            normalizedWidth: 0.3, normalizedHeight: 0.05,
            zIndex: 1
        )
        let audio = AudioContent(
            durationSeconds: 30,
            transcript: "this was said aloud"
        )
        element.audioContent = audio
        ctx.insert(element)
        try ctx.save()

        let scopeWith = QuizScope(
            type: .notebook,
            notebookIDs: [notebook.id],
            includeTranscriptions: true
        )
        let scopeWithout = QuizScope(
            type: .notebook,
            notebookIDs: [notebook.id],
            includeTranscriptions: false
        )
        XCTAssertGreaterThan(
            QuizSourceCollector.contentUnitCount(scope: scopeWith, context: ctx),
            0
        )
        XCTAssertEqual(
            QuizSourceCollector.contentUnitCount(scope: scopeWithout, context: ctx),
            0
        )
    }

    /// Legacy V5 `TextBlock` rows count toward eligibility. This is
    /// the storage layer every MCP/AI-imported notebook writes to
    /// (until the V6 text migration), so without this fold-in an
    /// agent-written notebook full of text reads as unquizzable.
    func test_legacyTextBlocks_countTowardEligibility() throws {
        let ctx = container.mainContext
        let notebook = makeNotebook(in: ctx, title: "mcp import")
        let page = makePage(in: ctx, notebook: notebook)
        let block = TextBlock(pageId: page.id, x: 0.1, y: 0.1, width: 0.8, height: 0.2)
        block.content = "Photosynthesis converts light energy into chemical energy stored in glucose."
        block.page = page
        ctx.insert(block)
        try ctx.save()

        let scope = QuizScope(
            type: .notebook,
            notebookIDs: [notebook.id],
            includeTranscriptions: true
        )
        XCTAssertGreaterThan(
            QuizSourceCollector.contentUnitCount(scope: scope, context: ctx), 0,
            "Legacy TextBlock text must register as quiz source"
        )
        XCTAssertGreaterThan(
            QuizSourceCollector.contentCharacterCount(scope: scope, context: ctx), 50
        )
        // Soft-deleted blocks must NOT count.
        block.isDeleted = true
        block.deletedAt = Date()
        try ctx.save()
        let flags = (page.textBlocks ?? []).map {
            "isDeleted=\($0.isDeleted) deletedAt=\($0.deletedAt != nil)"
        }
        XCTAssertEqual(
            QuizSourceCollector.contentUnitCount(scope: scope, context: ctx), 0,
            "Soft-deleted TextBlock must not count as quiz source — blocks: \(flags)"
        )
    }

    /// `contentCharacterCount` sums characters across every text
    /// source — the builder's "enough context" gate reads this.
    func test_characterCount_sumsAcrossSources() throws {
        let ctx = container.mainContext
        let notebook = makeNotebook(in: ctx, title: "char count")
        let page = makePage(in: ctx, notebook: notebook)
        let element = PageElement(
            pageId: page.id, notebookId: notebook.id,
            kind: .text,
            normalizedX: 0.1, normalizedY: 0.1,
            normalizedWidth: 0.5, normalizedHeight: 0.05,
            zIndex: 1
        )
        element.textContent = TextContent(text: "abcde")     // 5 chars
        ctx.insert(element)
        let block = TextBlock(pageId: page.id, x: 0, y: 0, width: 1, height: 0.1)
        block.content = "fghij"                              // 5 chars
        block.page = page
        ctx.insert(block)
        try ctx.save()

        let scope = QuizScope(
            type: .notebook,
            notebookIDs: [notebook.id],
            includeTranscriptions: false
        )
        XCTAssertEqual(
            QuizSourceCollector.contentCharacterCount(scope: scope, context: ctx),
            10
        )
    }

    // MARK: - Fixtures

    private func makeNotebook(
        in ctx: ModelContext,
        title: String,
        subjectId: UUID? = nil
    ) -> Notebook {
        let nb = Notebook(
            title: title,
            subjectId: subjectId,
            coverColorHex: "#FAFAF8",
            pageSize: .a4,
            defaultTemplate: .blank
        )
        ctx.insert(nb)
        return nb
    }

    private func makePage(in ctx: ModelContext, notebook: Notebook) -> Page {
        let page = Page(
            notebookId: notebook.id,
            pageNumber: 1,
            pageSize: .a4,
            backgroundTemplate: .blank
        )
        ctx.insert(page)
        return page
    }
}
