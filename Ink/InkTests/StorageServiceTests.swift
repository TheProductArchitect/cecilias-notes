import XCTest
import SwiftData
@testable import Ink

/// Storage CRUD + soft-delete + reaper, all against an in-memory
/// SwiftData container. Never touches the on-disk store, so tests are
/// hermetic and parallel-safe.
@MainActor
final class StorageServiceTests: XCTestCase {

    var storage: StorageService!
    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.inkTestContainer()
        storage = StorageService(container: container)
    }

    override func tearDown() async throws {
        storage = nil
        container = nil
        try await super.tearDown()
    }

    /// Fetch every soft-deleted notebook (non-soft-deleted ones excluded
    /// by the production fetch). Used to verify the reaper's behaviour.
    private func fetchTrashedNotebooks() -> [Notebook] {
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isDeleted == true }
        )
        return (try? container.mainContext.fetch(descriptor)) ?? []
    }

    // MARK: Notebook CRUD

    func test_createNotebook_thenFetchById_matches() throws {
        let nb = try storage.createNotebook(
            title: "Test",
            subjectId: nil,
            coverColorHex: "#007AFF",
            coverTexture: .none,
            pageSize: .a4,
            template: .blank
        )
        let fetched = storage.fetchAllNotebooks().first { $0.id == nb.id }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Test")
        XCTAssertEqual(fetched?.coverColorHex, "#007AFF")
        // First page is auto-created on notebook creation.
        XCTAssertEqual(fetched?.totalPageCount, 1)
    }

    func test_softDeleteNotebook_disappearsFromActiveFetch_butStaysInTrash() throws {
        let nb = try storage.createNotebook(
            title: "ToDelete",
            subjectId: nil,
            coverColorHex: "#000000",
            coverTexture: .none,
            pageSize: .a4,
            template: .blank
        )
        let id = nb.id
        try storage.deleteNotebook(nb)

        // Active fetch (production predicate excludes soft-deleted rows).
        let visible = storage.fetchAllNotebooks().contains { $0.id == id }
        XCTAssertFalse(visible, "Soft-deleted notebook should not appear in fetchAllNotebooks")

        // Trash fetch picks it up.
        let trashed = fetchTrashedNotebooks().contains { $0.id == id }
        XCTAssertTrue(trashed, "Soft-deleted notebook should still exist in storage as trash")
    }

    // MARK: Reaper

    func test_purgeExpiredDeletedRecords_removesRowsOlderThan30Days() throws {
        // Create two soft-deleted notebooks: one 31 days old, one fresh.
        let stale = try storage.createNotebook(
            title: "Stale",
            subjectId: nil,
            coverColorHex: "#111111",
            coverTexture: .none,
            pageSize: .a4,
            template: .blank
        )
        let recent = try storage.createNotebook(
            title: "Recent",
            subjectId: nil,
            coverColorHex: "#222222",
            coverTexture: .none,
            pageSize: .a4,
            template: .blank
        )
        try storage.deleteNotebook(stale)
        try storage.deleteNotebook(recent)
        // Backdate stale's deletedAt to 31 days ago.
        stale.deletedAt = Calendar.current.date(byAdding: .day, value: -31, to: Date())

        try storage.purgeExpiredDeletedRecords()

        // Direct fetch over the in-memory container — bypasses the
        // production isDeleted-false predicate so we can see what the
        // reaper left behind.
        let trash = fetchTrashedNotebooks()
        XCTAssertFalse(
            trash.contains(where: { $0.title == "Stale" }),
            "Stale (>30d) soft-deleted notebook should have been purged"
        )
        XCTAssertTrue(
            trash.contains(where: { $0.title == "Recent" }),
            "Recent soft-deleted notebook should remain"
        )
    }

    // MARK: Folders

    func test_moveNotebookIntoFolder_updatesFolderId() throws {
        let subject = try storage.createSubject(name: "Maths", colorHex: "#FF3B30")
        let nb = try storage.createNotebook(
            title: "Quadratics",
            subjectId: subject.id,
            coverColorHex: "#0A84FF",
            coverTexture: .none,
            pageSize: .a4,
            template: .blank
        )
        let folder = try storage.createFolder(name: "Term 1", in: subject)

        XCTAssertNil(nb.folderId, "Notebook should start with no folder")
        try storage.moveNotebook(nb, toFolder: folder.id)
        XCTAssertEqual(nb.folderId, folder.id, "folderId should be updated to target folder")
    }

    func test_moveNotebookOutOfFolder_setsFolderIdNil() throws {
        let subject = try storage.createSubject(name: "Maths", colorHex: "#FF3B30")
        let nb = try storage.createNotebook(
            title: "X",
            subjectId: subject.id,
            coverColorHex: "#0A84FF",
            coverTexture: .none,
            pageSize: .a4,
            template: .blank
        )
        let folder = try storage.createFolder(name: "F", in: subject)
        try storage.moveNotebook(nb, toFolder: folder.id)
        XCTAssertEqual(nb.folderId, folder.id)
        try storage.moveNotebook(nb, toFolder: nil)
        XCTAssertNil(nb.folderId, "folderId should clear when moved out")
    }
}
