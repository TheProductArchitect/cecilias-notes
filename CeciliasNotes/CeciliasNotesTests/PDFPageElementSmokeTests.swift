import XCTest
import SwiftData
@testable import CeciliasNotes

/// Step 4.5 smoke tests for the V6 PDF-page element + the
/// MediaStorage PDF dedup index. Verifies:
///   • PageElement(kind: .pdfPage) + PDFPageContent round-trip
///     through SwiftData with pdfDocumentId, pageIndex, dimensions,
///     preview filename.
///   • PDFPageContent.pdfFileURL / .previewImageURL match the
///     MediaStorage layout.
///   • MediaStorage.writePDF returns the same UUID when given the
///     same hash twice (dedup contract).
///   • MediaStorage.sha256Hex is deterministic.
///   • Soft-delete hides from the overlay's standard query.
@MainActor
final class PDFPageElementSmokeTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    func test_pdfPageElement_insertAndFetch_preservesContent() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let notebookId = UUID()
        let pdfDocumentId = UUID()
        let contentId = UUID()

        let element = PageElement(
            pageId: pageId,
            notebookId: notebookId,
            kind: .pdfPage,
            normalizedX: 0.2,
            normalizedY: 0.1,
            normalizedWidth: 0.6,
            normalizedHeight: 0.4
        )
        let content = PDFPageContent(
            id: contentId,
            pdfDocumentId: pdfDocumentId,
            pageIndex: 7,
            originalPageWidth: 612,
            originalPageHeight: 792,
            previewImageFilename: "\(contentId.uuidString).png"
        )
        element.pdfPageContent = content
        ctx.insert(element)
        try ctx.save()

        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )
        let fetched = try ctx.fetch(descriptor).filter { $0.kind == .pdfPage }
        XCTAssertEqual(fetched.count, 1)
        let row = try XCTUnwrap(fetched.first)
        XCTAssertEqual(row.pdfPageContent?.pdfDocumentId, pdfDocumentId)
        XCTAssertEqual(row.pdfPageContent?.pageIndex, 7)
        XCTAssertEqual(row.pdfPageContent?.originalPageWidth, 612)
        XCTAssertEqual(row.pdfPageContent?.previewImageFilename, "\(contentId.uuidString).png")
    }

    func test_pdfPageContent_urls_matchMediaStorageLayout() {
        let pdfDocumentId = UUID()
        let contentId = UUID()
        let content = PDFPageContent(
            id: contentId,
            pdfDocumentId: pdfDocumentId,
            previewImageFilename: "\(contentId.uuidString).png"
        )
        XCTAssertEqual(content.pdfFileURL, MediaStorage.url(forPDF: pdfDocumentId))
        let expectedPreview = MediaStorage.pdfPreviewDirectory
            .appendingPathComponent("\(contentId.uuidString).png")
        XCTAssertEqual(content.previewImageURL, expectedPreview)
    }

    func test_mediaStorage_sha256Hex_isDeterministic() {
        let data = "Cecilia's Notes".data(using: .utf8)!
        let a = MediaStorage.sha256Hex(of: data)
        let b = MediaStorage.sha256Hex(of: data)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)  // 32 bytes × 2 hex chars
    }

    func test_mediaStorage_writePDF_dedupsOnHash() {
        // Use a unique hash for this test run so previous runs
        // don't pollute the on-disk index. The hash is just a
        // synthetic string; the contract is "same hash → same id".
        let hash = "test-dedup-\(UUID().uuidString)"
        let data = Data(repeating: 0x25, count: 32)
        let firstId = MediaStorage.writePDF(from: data, hash: hash)
        let secondId = MediaStorage.writePDF(from: data, hash: hash)
        XCTAssertEqual(firstId, secondId, "same hash must resolve to same pdfDocumentId")
    }

    func test_pdfPageElement_softDelete_hidesFromOverlayQuery() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let element = PageElement(
            pageId: pageId,
            notebookId: UUID(),
            kind: .pdfPage
        )
        element.pdfPageContent = PDFPageContent(
            pdfDocumentId: UUID(),
            pageIndex: 0
        )
        ctx.insert(element)
        try ctx.save()

        let pid = pageId
        let before = try ctx.fetch(FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )).filter { $0.kind == .pdfPage }
        XCTAssertEqual(before.count, 1)

        element.deletedAt = Date()
        try ctx.save()

        let after = try ctx.fetch(FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )).filter { $0.kind == .pdfPage }
        XCTAssertEqual(after.count, 0)
    }
}
