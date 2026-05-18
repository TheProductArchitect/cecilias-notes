import XCTest
import SwiftData
@testable import CeciliasNotes

/// Step 4 smoke tests for the V6 image element. Verifies:
///   • A `PageElement(kind: .image)` + `ImageContent` round-trip
///     through SwiftData with `fileFormat` and pixel dimensions.
///   • `ImageContent.fileURL` resolves to the canonical
///     `MediaStorage.url(for: .images, id:, fileExtension:)`.
///   • Optional crop fields default to `nil`.
///   • Soft-delete via `element.deletedAt` keeps the row but hides
///     it from the standard pageId + non-deleted query the overlay
///     uses.
@MainActor
final class ImageElementSmokeTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    func test_imageElement_insertAndFetch_preservesContent() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let notebookId = UUID()
        let imageId = UUID()

        let element = PageElement(
            pageId: pageId,
            notebookId: notebookId,
            kind: .image,
            normalizedX: 0.2,
            normalizedY: 0.1,
            normalizedWidth: 0.6,
            normalizedHeight: 0.45
        )
        let content = ImageContent(
            id: imageId,
            filename: "\(imageId.uuidString).heic",
            fileFormat: "heic",
            originalPixelWidth: 4032,
            originalPixelHeight: 3024
        )
        element.imageContent = content
        ctx.insert(element)
        try ctx.save()

        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )
        let fetched = try ctx.fetch(descriptor).filter { $0.kind == .image }
        XCTAssertEqual(fetched.count, 1)
        let row = try XCTUnwrap(fetched.first)
        XCTAssertEqual(row.imageContent?.fileFormat, "heic")
        XCTAssertEqual(row.imageContent?.originalPixelWidth, 4032)
        XCTAssertEqual(row.imageContent?.originalPixelHeight, 3024)
    }

    func test_imageContent_fileURL_matchesMediaStorageConvention() {
        let id = UUID()
        let content = ImageContent(
            id: id,
            filename: "\(id.uuidString).png",
            fileFormat: "png"
        )
        XCTAssertEqual(
            content.fileURL,
            MediaStorage.url(for: .images, id: id, fileExtension: "png")
        )
    }

    func test_imageContent_cropFields_defaultToNil() {
        let content = ImageContent()
        XCTAssertNil(content.cropOriginX)
        XCTAssertNil(content.cropOriginY)
        XCTAssertNil(content.cropWidth)
        XCTAssertNil(content.cropHeight)
    }

    func test_imageElement_softDelete_hidesFromOverlayQuery() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let element = PageElement(
            pageId: pageId,
            notebookId: UUID(),
            kind: .image
        )
        element.imageContent = ImageContent(filename: "x.jpg", fileFormat: "jpg")
        ctx.insert(element)
        try ctx.save()

        // Sanity — visible before soft-delete.
        let pid = pageId
        let before = try ctx.fetch(FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )).filter { $0.kind == .image }
        XCTAssertEqual(before.count, 1)

        element.deletedAt = Date()
        try ctx.save()

        // The overlay's query excludes `deletedAt != nil`.
        let after = try ctx.fetch(FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )).filter { $0.kind == .image }
        XCTAssertEqual(after.count, 0)
    }
}
