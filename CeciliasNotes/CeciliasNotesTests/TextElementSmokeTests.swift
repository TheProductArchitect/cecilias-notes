import XCTest
import SwiftData
@testable import CeciliasNotes

/// Step 3 smoke tests for the V6 text element. Verifies:
///   • A `PageElement(kind: .text)` + `TextContent` round-trip
///     through SwiftData.
///   • `TextContent.size` defaults to `.body` and survives a
///     save/fetch cycle.
///   • The `FingerDrawingMode` resolver returns the expected bool
///     against detector state.
@MainActor
final class TextElementSmokeTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    func test_textElement_insertAndFetch_preservesContent() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let notebookId = UUID()

        let element = PageElement(
            pageId: pageId,
            notebookId: notebookId,
            kind: .text,
            normalizedX: 0.1,
            normalizedY: 0.2,
            normalizedWidth: 0.5,
            normalizedHeight: 0.05
        )
        let content = TextContent(text: "Step 3 lives", source: .typed, size: .heading)
        element.textContent = content
        ctx.insert(element)
        try ctx.save()

        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid }
        )
        let fetched = try ctx.fetch(descriptor).filter { $0.kind == .text }
        XCTAssertEqual(fetched.count, 1)
        let fetchedElement = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetchedElement.textContent?.text, "Step 3 lives")
        XCTAssertEqual(fetchedElement.textContent?.size, .heading)
        XCTAssertEqual(fetchedElement.textContent?.source, .typed)
    }

    func test_textContent_sizeDefault_isBody() {
        let content = TextContent(text: "default")
        XCTAssertEqual(content.size, .body)
    }

    func test_textSize_pointSize_andWeight_areExpected() {
        XCTAssertEqual(TextSize.small.pointSize, 14)
        XCTAssertEqual(TextSize.body.pointSize, 17)
        XCTAssertEqual(TextSize.heading.pointSize, 24)
        XCTAssertEqual(TextSize.heading.fontWeight, .semibold)
        XCTAssertEqual(TextSize.body.fontWeight, .regular)
    }

    // MARK: - FingerDrawingMode resolution

    func test_fingerDrawingMode_auto_resolvesToEnabledWhenNoPencil() {
        XCTAssertTrue(FingerDrawingMode.auto.fingerDrawingEnabled(hasPencil: false))
        XCTAssertFalse(FingerDrawingMode.auto.fingerDrawingEnabled(hasPencil: true))
    }

    func test_fingerDrawingMode_always_andNever_ignoreDetection() {
        XCTAssertTrue(FingerDrawingMode.always.fingerDrawingEnabled(hasPencil: false))
        XCTAssertTrue(FingerDrawingMode.always.fingerDrawingEnabled(hasPencil: true))
        XCTAssertFalse(FingerDrawingMode.never.fingerDrawingEnabled(hasPencil: false))
        XCTAssertFalse(FingerDrawingMode.never.fingerDrawingEnabled(hasPencil: true))
    }
}
