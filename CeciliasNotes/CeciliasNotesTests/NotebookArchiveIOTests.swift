import XCTest
import SwiftData
@testable import CeciliasNotes

/// Round-trip coverage for the full-fidelity `.ceciliabook` archive:
/// export a notebook with mixed elements + media, import it back, and
/// assert the reconstruction preserves content, geometry, and media
/// bytes with FRESH ids (so a shared copy can't collide with the
/// sender's).
@MainActor
final class NotebookArchiveIOTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    private func elements(pageId: UUID) -> [PageElement] {
        let d = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pageId && $0.deletedAt == nil }
        )
        return (try? StorageService.shared.context.fetch(d)) ?? []
    }

    func test_roundTrip_preservesElementsMediaAndGeometry() throws {
        let storage = StorageService.shared
        let nb = try storage.createNotebook(
            title: "Round Trip",
            subjectId: nil,
            coverColorHex: "#123456",
            coverTexture: .linen,
            pageSize: .a4,
            template: .blank
        )
        let page = try XCTUnwrap(storage.fetchPages(in: nb).first)

        // Text (with a non-default size + rich payload)
        let textEl = PageElement(
            pageId: page.id, notebookId: nb.id, kind: .text,
            normalizedX: 0.1, normalizedY: 0.15, normalizedWidth: 0.8, normalizedHeight: 0.2, zIndex: 1
        )
        textEl.textContent = TextContent(text: "Hello world", source: .typed, size: .heading)
        storage.context.insert(textEl)

        // Image (with bytes)
        let imgBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x11, 0x22, 0x33, 0x44])
        let imgEl = PageElement(
            pageId: page.id, notebookId: nb.id, kind: .image,
            normalizedX: 0.2, normalizedY: 0.4, normalizedWidth: 0.3, normalizedHeight: 0.25,
            rotation: 0.5, zIndex: 2
        )
        imgEl.imageContent = ImageContent(
            id: UUID(), filename: "x.jpg", fileFormat: "jpg",
            originalPixelWidth: 120, originalPixelHeight: 90, imageData: imgBytes
        )
        storage.context.insert(imgEl)

        // Stroke (ink)
        let inkBytes = Data([1, 2, 3, 4, 5, 6])
        let strokeEl = PageElement(
            pageId: page.id, notebookId: nb.id, kind: .stroke,
            normalizedX: 0, normalizedY: 0, normalizedWidth: 1, normalizedHeight: 1, zIndex: 0
        )
        strokeEl.strokeContent = StrokeContent(
            strokeData: inkBytes, toolKind: "pen", colorHex: "#00FF00", widthBase: 2.5, opacity: 0.8
        )
        storage.context.insert(strokeEl)

        // Sticky
        let stickyEl = PageElement(
            pageId: page.id, notebookId: nb.id, kind: .stickyNote,
            normalizedX: 0.5, normalizedY: 0.6, normalizedWidth: 0.2, normalizedHeight: 0.1, zIndex: 3
        )
        stickyEl.stickyNoteContent = StickyNoteContent(text: "note!", colorVariant: "blue")
        storage.context.insert(stickyEl)

        try storage.context.save()

        // Export → import
        let data = try XCTUnwrap(NotebookArchiveIO.archiveData(for: nb), "export must produce data")
        let imported = try XCTUnwrap(NotebookArchiveIO.importArchive(data: data), "import must succeed")

        // Fresh identity + preserved notebook metadata.
        XCTAssertNotEqual(imported.id, nb.id, "imported notebook must get a fresh id")
        XCTAssertEqual(imported.coverColorHex, "#123456")
        XCTAssertEqual(imported.pageSize, .a4)

        let importedPages = storage.fetchPages(in: imported)
        XCTAssertEqual(importedPages.count, 1)
        let importedEls = elements(pageId: try XCTUnwrap(importedPages.first).id)
        XCTAssertEqual(importedEls.count, 4, "all four elements must round-trip")

        // Text preserved (content + coarse size + geometry).
        let text = try XCTUnwrap(importedEls.first { $0.kind == .text })
        XCTAssertEqual(text.textContent?.text, "Hello world")
        XCTAssertEqual(text.textContent?.size, .heading)
        XCTAssertEqual(text.normalizedWidth, 0.8, accuracy: 0.0001)

        // Image bytes + rotation preserved.
        let img = try XCTUnwrap(importedEls.first { $0.kind == .image })
        XCTAssertEqual(img.imageContent?.imageData, imgBytes)
        XCTAssertEqual(img.rotation, 0.5, accuracy: 0.0001)
        XCTAssertEqual(img.imageContent?.originalPixelWidth, 120)

        // Ink bytes preserved.
        let stroke = try XCTUnwrap(importedEls.first { $0.kind == .stroke })
        XCTAssertEqual(stroke.strokeContent?.strokeData, inkBytes)
        XCTAssertEqual(stroke.strokeContent?.colorHex, "#00FF00")

        // Sticky preserved.
        let sticky = try XCTUnwrap(importedEls.first { $0.kind == .stickyNote })
        XCTAssertEqual(sticky.stickyNoteContent?.text, "note!")
        XCTAssertEqual(sticky.stickyNoteContent?.colorVariant, "blue")
    }

    func test_importGarbageData_isQuietNil() throws {
        XCTAssertNil(NotebookArchiveIO.importArchive(data: Data("not a notebook".utf8)))
        XCTAssertNil(NotebookArchiveIO.importArchive(data: Data()))
    }
}
