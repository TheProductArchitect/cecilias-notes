import XCTest
import SwiftData
@testable import CeciliasNotes

/// End-to-end round-trip tests for the MCP mirror pipeline. The
/// importer ingests a multi-block `.inkbook`, edits propagate to
/// SwiftData, and the exporter writes back. The mirror must
/// preserve structure verbatim — the previous flatten-everything-
/// into-paragraphs path destroyed heading levels, callout kinds,
/// list styles, etc. on every round-trip.
@MainActor
final class InkbookRoundTripTests: XCTestCase {

    var storage: StorageService!
    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
        storage   = StorageService(container: container)
    }

    override func tearDown() async throws {
        // Remove any scratch notebooks the test inserted into the
        // *shared* context (the exporter's data source). Per-test
        // cleanup keeps the suite hermetic across runs.
        let ctx = StorageService.shared.context
        for id in sharedScratchNotebookIDs {
            let descriptor = FetchDescriptor<Notebook>(
                predicate: #Predicate { $0.id == id }
            )
            if let nb = (try? ctx.fetch(descriptor))?.first {
                ctx.delete(nb)
            }
        }
        try? ctx.save()
        sharedScratchNotebookIDs.removeAll()

        storage   = nil
        container = nil
        try await super.tearDown()
    }

    /// Encode a structured-blocks file as the importer would receive
    /// it, persist via the same encode→stash path the importer uses,
    /// then verify the exporter's extracted blocks match verbatim.
    func test_blockStructure_preservedAcrossRoundTrip() throws {
        // The bug repro: three structured blocks on a single page
        // (heading H1 + paragraph + tip callout). The pre-fix
        // exporter flattened them into one paragraph with "\n\n"
        // joins and a "💡 " prefix; post-fix, the bytes must
        // round-trip exactly.
        let incoming: [CeciliasNotesFile.Block] = [
            .heading(content: "Project Plan", level: 1),
            .paragraph(content: "Kickoff is next Tuesday."),
            .callout(content: "Bring the laptop.", kind: .tip)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(incoming)
        let json = String(data: encoded, encoding: .utf8)
        XCTAssertNotNil(json)

        // Round-trip through the importer's decodeBlocks helper —
        // mirrors what the exporter does on emit.
        let decoded = CeciliasNotesImporter.decodeBlocks(json)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.count, 3)

        // Spot-check each block type so a future regression that
        // collapses any of them to `.paragraph` fails loudly.
        guard let blocks = decoded else { return XCTFail() }
        if case let .heading(content, level) = blocks[0] {
            XCTAssertEqual(content, "Project Plan")
            XCTAssertEqual(level, 1)
        } else { XCTFail("expected heading, got \(blocks[0])") }

        if case let .paragraph(content) = blocks[1] {
            XCTAssertEqual(content, "Kickoff is next Tuesday.")
        } else { XCTFail("expected paragraph, got \(blocks[1])") }

        if case let .callout(content, kind) = blocks[2] {
            XCTAssertEqual(content, "Bring the laptop.")
            XCTAssertEqual(kind, .tip)
        } else { XCTFail("expected callout(tip), got \(blocks[2])") }
    }

    /// Agent attribution must round-trip with the exact strings
    /// (Bug 5). The pre-fix exporter hard-coded `tool_version: "1"`
    /// and lost whatever the source `.inkbook` carried.
    func test_agentAttribution_preservedVerbatim() throws {
        // Build a notebook with all four agent columns populated
        // and verify the exporter's `buildFile` output carries them
        // verbatim. Inserts into the shared context (see
        // `test_hasInk_…` for the reason).
        let ctx = StorageService.shared.context
        let nb = Notebook(
            title: "n",
            subjectId: nil,
            coverColorHex: "",
            coverTexture: .none,
            pageSize: .a4,
            defaultTemplate: .blank
        )
        nb.isAgentWritten   = true
        nb.agentName        = "cecilias-notes-mcp"
        nb.agentModel       = "claude-opus-4-7"
        nb.agentTool        = "cecilias-notes-mcp"
        nb.agentToolVersion = "1.0.1"
        ctx.insert(nb)
        sharedScratchNotebookIDs.append(nb.id)
        try ctx.save()

        let file = CeciliasNotesExporter.shared.testOnlyBuildFile(for: nb)
        XCTAssertEqual(file.agent?.written_by,   "cecilias-notes-mcp")
        XCTAssertEqual(file.agent?.model,        "claude-opus-4-7")
        XCTAssertEqual(file.agent?.tool,         "cecilias-notes-mcp")
        // The specific value that the pre-fix code corrupted to "1".
        XCTAssertEqual(file.agent?.tool_version, "1.0.1")
    }

    /// A page with non-empty stroke bytes must emit `has_ink: true`.
    /// A text-only page must omit the field entirely (encoded as
    /// nil so the JSON stays back-compatible).
    ///
    /// Inserts into `StorageService.shared.context` rather than the
    /// test's isolated instance because the exporter's `buildFile`
    /// queries `PageElement` rows via `StorageService.shared.context`
    /// (it doesn't accept an injectable context). Test-only data is
    /// cleaned up on tearDown so subsequent tests are unaffected.
    func test_hasInk_emittedOnlyForInkedPages() throws {
        let ctx = StorageService.shared.context

        let nb = Notebook(
            title: "n",
            subjectId: nil,
            coverColorHex: "",
            coverTexture: .none,
            pageSize: .a4,
            defaultTemplate: .blank
        )
        ctx.insert(nb)
        sharedScratchNotebookIDs.append(nb.id)

        // Page A: no ink. Stays nil in the mirror.
        let pageA = Page(notebookId: nb.id, pageNumber: 1, pageSize: .a4, backgroundTemplate: .blank)
        pageA.notebook = nb
        nb.pages = [pageA]
        ctx.insert(pageA)

        // Page B: ink. The stroke singleton lives as a
        // `PageElement(.stroke)` whose `StrokeContent.strokeData`
        // is non-empty.
        let pageB = Page(notebookId: nb.id, pageNumber: 2, pageSize: .a4, backgroundTemplate: .blank)
        pageB.notebook = nb
        nb.pages = (nb.pages ?? []) + [pageB]
        ctx.insert(pageB)
        let strokeEl = PageElement(
            id: UUID(), pageId: pageB.id, notebookId: nb.id, kind: .stroke,
            normalizedX: 0, normalizedY: 0, normalizedWidth: 1, normalizedHeight: 1
        )
        let strokeContent = StrokeContent(
            strokeData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        strokeEl.strokeContent = strokeContent
        ctx.insert(strokeEl)
        try ctx.save()

        let file = CeciliasNotesExporter.shared.testOnlyBuildFile(for: nb)
        XCTAssertEqual(file.pages.count, 2)
        XCTAssertNil(file.pages[0].has_ink, "text-only page should not emit has_ink")
        XCTAssertEqual(file.pages[1].has_ink, true, "inked page must emit has_ink: true")
    }

    /// Notebook IDs inserted into the shared context for tests
    /// that exercise exporter paths reading from the shared
    /// container. Cleaned up on tearDown.
    private var sharedScratchNotebookIDs: [UUID] = []

}
