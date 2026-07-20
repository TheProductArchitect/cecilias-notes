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

    // MARK: - Regression: import must surface at the TOP of its subject
    //
    // Bug (fixed 4fc64ab): an imported .ceciliabook landed at the very
    // bottom of the library and read as "nothing was imported", because
    // createNotebook append-assigns the highest sortOrder and the
    // library sorts ascending. reconstruct() now gives the import the
    // lowest order in its subject.
    func test_import_surfacesNotebookAtTopOfSubject() throws {
        let storage = StorageService.shared
        let a = try storage.createNotebook(
            title: "Existing A", subjectId: nil, coverColorHex: "#111111",
            coverTexture: .none, pageSize: .a4, template: .blank
        )
        let b = try storage.createNotebook(
            title: "Existing B", subjectId: nil, coverColorHex: "#222222",
            coverTexture: .none, pageSize: .a4, template: .blank
        )
        // Give A one page of content so the archive is well-formed.
        let aPage = try XCTUnwrap(storage.fetchPages(in: a).first)
        let el = PageElement(
            pageId: aPage.id, notebookId: a.id, kind: .text,
            normalizedX: 0.1, normalizedY: 0.1, normalizedWidth: 0.5, normalizedHeight: 0.1, zIndex: 1
        )
        el.textContent = TextContent(text: "hi", source: .typed, size: .body)
        storage.context.insert(el)
        try storage.context.save()

        let data = try XCTUnwrap(NotebookArchiveIO.archiveData(for: a))
        let imported = try XCTUnwrap(NotebookArchiveIO.importArchive(data: data))

        let peers = storage.fetchNotebooks(subjectId: imported.subjectId)
        let minOrder = try XCTUnwrap(peers.map(\.sortOrder).min())
        XCTAssertEqual(imported.sortOrder, minOrder,
                       "imported notebook must have the lowest sortOrder (top of the subject)")
        XCTAssertLessThan(imported.sortOrder, a.sortOrder,
                          "import must sort above pre-existing notebook A")
        XCTAssertLessThan(imported.sortOrder, b.sortOrder,
                          "import must sort above pre-existing notebook B")
    }

    // MARK: - Regression: multi-page ink must all round-trip
    //
    // Strengthens the net around the "imported notebook is empty"
    // report: every page's PKDrawing (StrokeContent.strokeData) must
    // survive export→import, with no cross-page contamination.
    func test_roundTrip_multiPage_preservesEveryPagesInk() throws {
        let storage = StorageService.shared
        let nb = try storage.createNotebook(
            title: "Multi-Page Ink", subjectId: nil, coverColorHex: "#333333",
            coverTexture: .none, pageSize: .a4, template: .blank
        )
        // Seed page (1) plus two more → three pages, each with a
        // DISTINCT ink blob so cross-page mixups would be caught.
        var pages = storage.fetchPages(in: nb)
        for n in 2...3 {
            let p = Page(notebookId: nb.id, pageNumber: n, pageSize: .a4, backgroundTemplate: .blank)
            p.notebook = nb
            storage.context.insert(p)
            pages.append(p)
        }
        var expectedInk: [Int: Data] = [:]  // pageNumber → ink bytes
        for p in pages {
            let ink = Data([UInt8(p.pageNumber), 0xAA, 0xBB, UInt8(p.pageNumber &* 7)])
            expectedInk[p.pageNumber] = ink
            let strokeEl = PageElement(
                pageId: p.id, notebookId: nb.id, kind: .stroke,
                normalizedX: 0, normalizedY: 0, normalizedWidth: 1, normalizedHeight: 1, zIndex: 0
            )
            strokeEl.strokeContent = StrokeContent(
                strokeData: ink, toolKind: "pen", colorHex: "#000000", widthBase: 2, opacity: 1
            )
            storage.context.insert(strokeEl)
        }
        try storage.context.save()

        let data = try XCTUnwrap(NotebookArchiveIO.archiveData(for: nb), "export must produce data")
        let imported = try XCTUnwrap(NotebookArchiveIO.importArchive(data: data), "import must succeed")

        let importedPages = storage.fetchPages(in: imported).sorted { $0.pageNumber < $1.pageNumber }
        XCTAssertEqual(importedPages.count, 3, "all three pages must round-trip (not an empty notebook)")
        for p in importedPages {
            let strokes = elements(pageId: p.id).filter { $0.kind == .stroke }
            XCTAssertEqual(strokes.count, 1, "page \(p.pageNumber) must keep its stroke element")
            XCTAssertEqual(strokes.first?.strokeContent?.strokeData, expectedInk[p.pageNumber],
                           "page \(p.pageNumber) ink must match exactly (no loss, no cross-page mixup)")
        }
    }
}
