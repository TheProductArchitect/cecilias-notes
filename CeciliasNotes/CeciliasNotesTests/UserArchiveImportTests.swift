import XCTest
import SwiftData
@testable import CeciliasNotes

/// Imports the user's REAL exported `.ceciliabook` (the one that
/// reproduced "imported notebook was all empty" on-device) and
/// asserts every page + element survives. The file lives at the repo
/// root; simulator tests share the host filesystem, so the absolute
/// path resolves. Skips (rather than fails) when the file isn't
/// present so CI on other machines stays green.
@MainActor
final class UserArchiveImportTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    func test_importUsersRealArchive_reproducesOrRefutesEmptyImport() async throws {
        let path = "/Users/venu/Documents/GitHub/Cecilias-Notes/Happy Birthday Best Best Bestest Boyfriend -).ceciliabook"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("user archive not present on this machine")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(data.count, 20_000_000, "expected the ~22MB archive")

        // Same entry point the device uses (tap-to-open / inbox).
        let imported = await NotebookArchiveIO.importArchiveAsync(data: data)
        let notebook = try XCTUnwrap(imported, "import must produce a notebook")

        let storage = StorageService.shared
        let pages = storage.fetchPages(in: notebook)
        XCTAssertEqual(pages.count, 26, "all 26 pages must import — 1 page or 0 pages = the empty-import bug")

        func elements(on pageId: UUID) -> [PageElement] {
            let pid = pageId
            let d = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil }
            )
            return (try? storage.context.fetch(d)) ?? []
        }

        var kinds: [ElementKind: Int] = [:]
        var firstStrokeBytes = 0
        for page in pages {
            for el in elements(on: page.id) {
                kinds[el.kind, default: 0] += 1
                if el.kind == .stroke, firstStrokeBytes == 0 {
                    firstStrokeBytes = el.strokeContent?.strokeData.count ?? 0
                }
            }
        }
        XCTAssertEqual(kinds[.stroke] ?? 0, 21, "all 21 ink strokes must import")
        XCTAssertEqual(kinds[.image] ?? 0, 13, "all 13 images must import")
        XCTAssertEqual(kinds[.text] ?? 0, 1, "the text element must import")
        // Ink must be non-empty (visible), not just rows.
        XCTAssertGreaterThan(firstStrokeBytes, 0,
                             "imported ink must carry non-empty PKDrawing bytes")
    }
}
