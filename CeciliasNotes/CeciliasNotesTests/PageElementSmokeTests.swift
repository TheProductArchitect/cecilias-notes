import XCTest
import SwiftData
@testable import CeciliasNotes

/// Phase D smoke test for the V6 schema: confirms `PageElement` and
/// its content entities are present in the active schema, are
/// queryable, and that the polymorphic content relationship round-
/// trips through SwiftData with cascade delete intact.
///
/// This is intentionally minimal — Step 1 only proves the schema
/// works; per-kind behaviour gets covered as Steps 2-9 ship the
/// view-side migrations.
@MainActor
final class PageElementSmokeTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    func test_pageElement_insertAndFetchByPageId() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let notebookId = UUID()

        let element = PageElement(
            pageId: pageId,
            notebookId: notebookId,
            kind: .text,
            normalizedX: 0.1,
            normalizedY: 0.2,
            normalizedWidth: 0.3,
            normalizedHeight: 0.05,
            zIndex: 1
        )
        let text = TextContent(text: "hello", source: .typed)
        element.textContent = text
        ctx.insert(element)
        try ctx.save()

        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pageId }
        )
        let fetched = try ctx.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.kind, .text)
        XCTAssertEqual(fetched.first?.textContent?.text, "hello")
    }

    func test_pageElement_cascadeDeletesContent() throws {
        let ctx = container.mainContext
        let element = PageElement(
            pageId: UUID(),
            notebookId: UUID(),
            kind: .image
        )
        let image = ImageContent(filename: "x.jpg", originalPixelWidth: 10, originalPixelHeight: 10)
        element.imageContent = image
        ctx.insert(element)
        try ctx.save()

        let imageDescriptor = FetchDescriptor<ImageContent>()
        XCTAssertEqual(try ctx.fetch(imageDescriptor).count, 1)

        ctx.delete(element)
        try ctx.save()

        XCTAssertEqual(try ctx.fetch(imageDescriptor).count, 0,
                       "ImageContent should be cascade-deleted with its parent PageElement")
    }

    func test_pageElement_sortByZIndex() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let notebookId = UUID()

        for z in [3, 1, 2] {
            let e = PageElement(
                pageId: pageId,
                notebookId: notebookId,
                kind: .stroke,
                zIndex: z
            )
            ctx.insert(e)
        }
        try ctx.save()

        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pageId },
            sortBy: [SortDescriptor(\.zIndex)]
        )
        let fetched = try ctx.fetch(descriptor)
        XCTAssertEqual(fetched.map(\.zIndex), [1, 2, 3])
    }
}
