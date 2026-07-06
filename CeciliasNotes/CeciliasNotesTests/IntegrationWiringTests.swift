import XCTest
import SwiftData
@testable import CeciliasNotes

/// Smoke tests for cross-feature wiring added in batches 11–14:
/// share capture, handoff, sync conflict log, quick capture save.
@MainActor
final class IntegrationWiringTests: XCTestCase {

    private var scratchNotebookIDs: [UUID] = []

    override func tearDown() async throws {
        let ctx = StorageService.shared.context
        for id in scratchNotebookIDs {
            let descriptor = FetchDescriptor<Notebook>(predicate: #Predicate { $0.id == id })
            if let nb = (try? ctx.fetch(descriptor))?.first {
                ctx.delete(nb)
            }
        }
        try? ctx.save()
        scratchNotebookIDs.removeAll()
        SyncConflictLog.clear()
        try await super.tearDown()
    }

    // MARK: - Handoff (batch 13)

    func test_pageHandoff_roundTripsUserInfo() {
        let notebookId = UUID()
        let pageId = UUID()
        let info = PageHandoff.userInfo(
            notebookId: notebookId,
            pageId: pageId,
            scrollOffset: 120,
            zoom: 1.25
        )
        let parsed = PageHandoff.parse(info)
        XCTAssertEqual(parsed?.notebookId, notebookId)
        XCTAssertEqual(parsed?.pageId, pageId)
        XCTAssertEqual(parsed?.scrollOffset ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(parsed?.zoom ?? 0, 1.25, accuracy: 0.01)
    }

    // MARK: - Share extension capture (batch 14)

    func test_shareCapturePayload_decodesShareExtensionJSON() throws {
        let json = """
        {"title":"Shared note","body":"Hello from Safari"}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(ShareCapturePayload.self, from: json)
        XCTAssertEqual(payload.title, "Shared note")
        XCTAssertEqual(payload.body, "Hello from Safari")
    }

    func test_quickCaptureSave_createsNotebookWithTypedText() throws {
        let title = "Integration \(UUID().uuidString.prefix(6))"
        let body = "Wired via QuickCaptureSave"
        guard let notebookId = QuickCaptureSave.save(title: title, body: body) else {
            XCTFail("QuickCaptureSave.save returned nil")
            return
        }
        scratchNotebookIDs.append(notebookId)

        let ctx = StorageService.shared.context
        let descriptor = FetchDescriptor<Notebook>(predicate: #Predicate { $0.id == notebookId })
        let notebook = try XCTUnwrap(try ctx.fetch(descriptor).first)
        XCTAssertEqual(notebook.title, title)
        XCTAssertEqual(notebook.pages?.count, 1)

        let pageId = try XCTUnwrap(notebook.pages?.first?.id)
        let textDescriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pageId }
        )
        let elements = try ctx.fetch(textDescriptor).filter { $0.kind == ElementKind.text }
        XCTAssertFalse(elements.isEmpty, "typed body should create a text PageElement")
        XCTAssertTrue(
            elements.contains { $0.textContent?.text.contains("Wired via QuickCaptureSave") == true },
            "text element should contain capture body"
        )
    }

    // MARK: - Sync conflict log (batch 12)

    func test_syncConflictLog_postsChangedNotification() {
        SyncConflictLog.clear()
        let expectation = expectation(description: "syncConflictLogChanged")
        let token = NotificationCenter.default.addObserver(
            forName: .syncConflictLogChanged,
            object: nil,
            queue: nil
        ) { _ in expectation.fulfill() }

        SyncConflictLog.record(
            notebookTitle: "Test",
            sourceFilename: "mirror.cn",
            resolution: "merged"
        )
        wait(for: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(token)

        XCTAssertEqual(SyncConflictLog.records.count, 1)
        XCTAssertEqual(SyncConflictLog.records.first?.notebookTitle, "Test")
    }

    func test_notebookMarkdownExport_includesTypedTextAndTranscript() throws {
        let ctx = StorageService.shared.context
        let nb = Notebook(
            title: "MD Export",
            subjectId: nil,
            coverColorHex: "#FAFAF8",
            pageSize: .a4
        )
        ctx.insert(nb)
        let page = Page(
            notebookId: nb.id,
            pageNumber: 1,
            pageSize: .a4,
            backgroundTemplate: .blank
        )
        page.notebook = nb
        nb.pages = [page]
        ctx.insert(page)
        scratchNotebookIDs.append(nb.id)

        _ = TextElementCommit.create(
            text: "Hello markdown",
            source: .typed,
            pageId: page.id,
            notebookId: nb.id,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1),
            context: ctx
        )
        try ctx.save()

        let markdown = NotebookMarkdownExport.build(
            notebook: nb,
            pages: [page],
            storage: StorageService.shared
        )
        XCTAssertTrue(markdown.contains("# MD Export"))
        XCTAssertTrue(markdown.contains("Hello markdown"))
    }
}
