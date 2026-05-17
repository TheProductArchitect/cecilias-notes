import XCTest
import SwiftData
@testable import CeciliasNotes

@MainActor
final class StorageServiceTests: XCTestCase {

    var container: ModelContainer!
    var service: StorageService!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
        service   = StorageService(container: container)
    }

    override func tearDown() async throws {
        service   = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeSubject(name: String = "Science") throws -> Subject {
        try service.createSubject(name: name, colorHex: CeciliasNotesColorPresets.subjectColors[0])
    }

    private func makeNotebook(subjectId: UUID? = nil, title: String = "Test Notebook") throws -> Notebook {
        try service.createNotebook(
            title: title,
            subjectId: subjectId,
            coverColorHex: "#007AFF",
            coverTexture: .none,
            pageSize: .a4,
            template: .blank
        )
    }

    // MARK: - Subject CRUD

    func test_createSubject_appears_in_fetch() throws {
        let subject = try makeSubject(name: "Maths")
        let fetched = service.fetchSubjects()
        XCTAssertTrue(fetched.contains { $0.id == subject.id })
    }

    func test_createSubject_enforces_name_max_50_chars() {
        let longName = String(repeating: "A", count: 51)
        XCTAssertThrowsError(try service.createSubject(name: longName, colorHex: CeciliasNotesColorPresets.subjectColors[0]))
    }

    func test_createSubject_rejects_invalid_colorHex() {
        XCTAssertThrowsError(try service.createSubject(name: "Art", colorHex: "#BADBAD"))
    }

    func test_updateSubject_name() throws {
        let subject = try makeSubject(name: "Old")
        try service.updateSubject(subject, name: "New", colorHex: nil)
        XCTAssertEqual(subject.name, "New")
    }

    func test_updateSubject_bumps_updatedAt() throws {
        let subject  = try makeSubject()
        let before   = subject.updatedAt
        try Task.sleep(nanoseconds: 10_000_000)   // 10 ms
        try service.updateSubject(subject, name: "Changed", colorHex: nil)
        XCTAssertGreaterThan(subject.updatedAt, before)
    }

    func test_deleteSubject_softDelete_moves_notebooks_to_uncategorised() throws {
        let subject  = try makeSubject()
        let notebook = try makeNotebook(subjectId: subject.id)
        try service.deleteSubject(subject)

        XCTAssertTrue(subject.isDeleted)
        XCTAssertNotNil(subject.deletedAt)
        XCTAssertNil(notebook.subjectId, "Notebook should be moved to Uncategorised")
    }

    func test_deleteSubject_hidden_from_fetchSubjects() throws {
        let subject = try makeSubject()
        try service.deleteSubject(subject)
        let fetched = service.fetchSubjects()
        XCTAssertFalse(fetched.contains { $0.id == subject.id })
    }

    func test_reorderSubjects() throws {
        let a = try makeSubject(name: "A")
        let b = try makeSubject(name: "B")
        try service.reorderSubjects([b, a])
        XCTAssertEqual(b.sortOrder, 0)
        XCTAssertEqual(a.sortOrder, 1)
    }

    // MARK: - Notebook CRUD

    func test_createNotebook_appears_in_fetch() throws {
        let subject  = try makeSubject()
        let notebook = try makeNotebook(subjectId: subject.id)
        let fetched  = service.fetchNotebooks(subjectId: subject.id)
        XCTAssertTrue(fetched.contains { $0.id == notebook.id })
    }

    func test_createNotebook_creates_first_page() throws {
        let notebook = try makeNotebook()
        XCTAssertEqual(notebook.totalPageCount, 1)
        let pages = service.fetchPages(in: notebook)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].pageNumber, 1)
    }

    func test_createNotebook_enforces_title_max_80_chars() {
        let longTitle = String(repeating: "T", count: 81)
        XCTAssertThrowsError(try makeNotebook(title: longTitle))
    }

    func test_updateNotebook_title() throws {
        let notebook = try makeNotebook()
        try service.updateNotebook(notebook, title: "Updated", coverColorHex: nil, isPinned: nil, tags: nil)
        XCTAssertEqual(notebook.title, "Updated")
    }

    func test_updateNotebook_tags_capped_at_5_and_20_chars() throws {
        let notebook = try makeNotebook()
        let tags     = ["one", "two", "three", "four", "five", "six"]  // 6 tags
        try service.updateNotebook(notebook, title: nil, coverColorHex: nil, isPinned: nil, tags: tags)
        XCTAssertEqual(notebook.tags.count, 5)
    }

    func test_fetchPinnedNotebooks() throws {
        let a = try makeNotebook(title: "Pinned")
        let b = try makeNotebook(title: "Not Pinned")
        try service.updateNotebook(a, title: nil, coverColorHex: nil, isPinned: true, tags: nil)
        let pinned = service.fetchPinnedNotebooks()
        XCTAssertTrue(pinned.contains  { $0.id == a.id })
        XCTAssertFalse(pinned.contains { $0.id == b.id })
    }

    func test_deleteNotebook_softDelete() throws {
        let notebook = try makeNotebook()
        try service.deleteNotebook(notebook)
        XCTAssertTrue(notebook.isDeleted)
        XCTAssertNotNil(notebook.deletedAt)
        XCTAssertFalse(service.fetchAllNotebooks().contains { $0.id == notebook.id })
    }

    func test_moveNotebook_to_different_subject() throws {
        let s1  = try makeSubject(name: "S1")
        let s2  = try makeSubject(name: "S2")
        let nb  = try makeNotebook(subjectId: s1.id)
        try service.moveNotebook(nb, to: s2.id)
        XCTAssertEqual(nb.subjectId, s2.id)
    }

    func test_updateThumbnail() throws {
        let notebook = try makeNotebook()
        let image    = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 260)).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 260))
        }
        try service.updateThumbnail(for: notebook, image: image)
        XCTAssertNotNil(notebook.thumbnailData)
    }

    // MARK: - Page CRUD

    func test_createPage_increments_total() throws {
        let notebook = try makeNotebook()
        _  = try service.createPage(in: notebook, after: nil)
        XCTAssertEqual(notebook.totalPageCount, 2)
    }

    func test_createPage_after_inserts_correct_number() throws {
        let notebook = try makeNotebook()
        let p2 = try service.createPage(in: notebook, after: 1)
        XCTAssertEqual(p2.pageNumber, 2)
    }

    func test_deletePage_renumbers_subsequent_pages() throws {
        let notebook = try makeNotebook()                           // p1
        let p2 = try service.createPage(in: notebook, after: 1)   // p2
        let p3 = try service.createPage(in: notebook, after: 2)   // p3

        // Delete p2 — p3 should become p2
        let pages = service.fetchPages(in: notebook)
        let secondPage = pages.first { $0.pageNumber == 2 }!
        try service.deletePage(secondPage)

        let remaining = service.fetchPages(in: notebook)
        XCTAssertEqual(remaining.count, 2)
        let numbers = remaining.map(\.pageNumber).sorted()
        XCTAssertEqual(numbers, [1, 2])
        XCTAssertEqual(notebook.totalPageCount, 2)
        _ = p2; _ = p3  // silence unused warnings
    }

    func test_deletePage_first_page_renumbers_all() throws {
        let notebook = try makeNotebook()
        _ = try service.createPage(in: notebook, after: 1)
        _ = try service.createPage(in: notebook, after: 2)

        let all      = service.fetchPages(in: notebook)
        let firstPage = all.first { $0.pageNumber == 1 }!
        try service.deletePage(firstPage)

        let remaining = service.fetchPages(in: notebook)
        XCTAssertEqual(remaining.map(\.pageNumber).sorted(), [1, 2])
    }

    func test_movePage_forward() throws {
        let notebook = try makeNotebook()
        _ = try service.createPage(in: notebook, after: 1)
        _ = try service.createPage(in: notebook, after: 2)

        let all  = service.fetchPages(in: notebook)
        let p1   = all.first { $0.pageNumber == 1 }!
        try service.movePage(p1, to: 3)

        let updated = service.fetchPages(in: notebook)
        XCTAssertEqual(updated.first { $0.id == p1.id }?.pageNumber, 3)
    }

    func test_movePage_invalid_number_throws() throws {
        let notebook = try makeNotebook()
        let pages    = service.fetchPages(in: notebook)
        XCTAssertThrowsError(try service.movePage(pages[0], to: 99))
    }

    func test_duplicatePage_copies_page_number() throws {
        let notebook = try makeNotebook()
        let page1    = service.fetchPages(in: notebook)[0]
        let copy     = try service.duplicatePage(page1)
        XCTAssertEqual(copy.pageNumber, 2)
    }

    // MARK: - TextBlock CRUD

    func test_createTextBlock_on_page() throws {
        let notebook = try makeNotebook()
        let page     = service.fetchPages(in: notebook)[0]
        let rect     = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2)
        let block    = try service.createTextBlock(on: page, at: rect)
        XCTAssertEqual(block.pageId, page.id)
        XCTAssertEqual(block.x, 0.1)
    }

    func test_updateTextBlock_content_and_richText() throws {
        let notebook = try makeNotebook()
        let page     = service.fetchPages(in: notebook)[0]
        let block    = try service.createTextBlock(on: page, at: CGRect(x: 0, y: 0, width: 0.5, height: 0.1))
        let attrStr  = NSAttributedString(string: "Hello CeciliasNotes")
        try service.updateTextBlock(block, richText: attrStr, rect: nil)
        XCTAssertEqual(block.content, "Hello CeciliasNotes")
        XCTAssertNotNil(block.richTextData)
    }

    func test_deleteTextBlock_softDelete() throws {
        let notebook = try makeNotebook()
        let page     = service.fetchPages(in: notebook)[0]
        let block    = try service.createTextBlock(on: page, at: CGRect(x: 0, y: 0, width: 0.5, height: 0.1))
        try service.deleteTextBlock(block)
        XCTAssertTrue(block.isDeleted)
        XCTAssertNotNil(block.deletedAt)
    }

    // MARK: - MediaAttachment CRUD

    func test_addImage_creates_attachment() async throws {
        let notebook  = try makeNotebook()
        let page      = service.fetchPages(in: notebook)[0]
        let imageData = makeSolidColorJPEG(color: .red, size: CGSize(width: 100, height: 100))!
        let rect      = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        let att       = try await service.addImage(to: page, imageData: imageData, mimeType: "image/jpeg", at: rect)
        XCTAssertEqual(att.pageId, page.id)
        XCTAssertEqual(att.type, .image)
    }

    func test_updateAttachment_caption() async throws {
        let notebook  = try makeNotebook()
        let page      = service.fetchPages(in: notebook)[0]
        let imageData = makeSolidColorJPEG(color: .blue, size: CGSize(width: 50, height: 50))!
        let att       = try await service.addImage(to: page, imageData: imageData, mimeType: "image/jpeg", at: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        try service.updateAttachment(att, rect: nil, rotation: nil, caption: "Test caption")
        XCTAssertEqual(att.caption, "Test caption")
    }

    func test_deleteAttachment_softDelete() async throws {
        let notebook  = try makeNotebook()
        let page      = service.fetchPages(in: notebook)[0]
        let imageData = makeSolidColorJPEG(color: .green, size: CGSize(width: 50, height: 50))!
        let att       = try await service.addImage(to: page, imageData: imageData, mimeType: "image/jpeg", at: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        try service.deleteAttachment(att)
        XCTAssertTrue(att.isDeleted)
    }

    // MARK: - AudioAnnotation CRUD

    func test_addAudioAnnotation() throws {
        let notebook = try makeNotebook()
        let page     = service.fetchPages(in: notebook)[0]
        let ann      = try service.addAudioAnnotation(to: page, fileName: "rec.m4a", duration: 12.5, at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(ann.pageId, page.id)
        XCTAssertEqual(ann.durationSeconds, 12.5)
    }

    func test_updateTranscription() throws {
        let notebook = try makeNotebook()
        let page     = service.fetchPages(in: notebook)[0]
        let ann      = try service.addAudioAnnotation(to: page, fileName: "rec.m4a", duration: 5.0, at: .zero)
        let segments = [TranscriptionSegment(word: "Hello", startTime: 0, endTime: 0.4, confidence: 0.99)]
        try service.updateTranscription(ann, text: "Hello", segments: segments)
        XCTAssertEqual(ann.transcription, "Hello")
        XCTAssertNotNil(ann.transcriptionSegments)
    }

    func test_deleteAudioAnnotation_softDelete() throws {
        let notebook = try makeNotebook()
        let page     = service.fetchPages(in: notebook)[0]
        let ann      = try service.addAudioAnnotation(to: page, fileName: "rec.m4a", duration: 3.0, at: .zero)
        try service.deleteAudioAnnotation(ann)
        XCTAssertTrue(ann.isDeleted)
        XCTAssertNotNil(ann.deletedAt)
    }

    // MARK: - Page renumbering edge cases

    func test_renumbering_preserves_contiguous_sequence() throws {
        let notebook = try makeNotebook()
        _ = try service.createPage(in: notebook, after: 1)
        _ = try service.createPage(in: notebook, after: 2)
        _ = try service.createPage(in: notebook, after: 3)
        // Delete middle page
        var pages  = service.fetchPages(in: notebook)
        let mid    = pages.first { $0.pageNumber == 2 }!
        try service.deletePage(mid)
        pages      = service.fetchPages(in: notebook)
        let nums   = pages.map(\.pageNumber).sorted()
        XCTAssertEqual(nums, Array(1...nums.count), "Page numbers must be contiguous after deletion")
    }

    func test_renumbering_multiple_deletions_stay_contiguous() throws {
        let notebook = try makeNotebook()
        for _ in 0..<4 { _ = try service.createPage(in: notebook, after: nil) }
        var pages = service.fetchPages(in: notebook)
        // Delete pages 2 and 4
        for num in [2, 4] {
            pages = service.fetchPages(in: notebook)
            if let target = pages.first(where: { $0.pageNumber == num }) {
                try service.deletePage(target)
            }
        }
        let final = service.fetchPages(in: notebook)
        let nums  = final.map(\.pageNumber).sorted()
        XCTAssertEqual(nums, Array(1...nums.count))
    }

    // MARK: - Storage calculation

    func test_localStorageUsed_returns_non_negative_values() async throws {
        let info = await service.localStorageUsed()
        XCTAssertGreaterThanOrEqual(info.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(info.audioBytes, 0)
        XCTAssertGreaterThanOrEqual(info.mediaBytes, 0)
        XCTAssertGreaterThanOrEqual(info.dbBytes, 0)
    }

    func test_localStorageUsed_total_equals_sum_of_parts() async throws {
        let info = await service.localStorageUsed()
        XCTAssertEqual(info.totalBytes, info.dbBytes + info.mediaBytes + info.audioBytes)
    }

    // MARK: - Search

    func test_search_finds_notebook_title() throws {
        _ = try makeNotebook(title: "My Quantum Notes")
        let results = service.search(query: "Quantum")
        XCTAssertTrue(results.contains { $0.type == .notebookTitle && $0.context.contains("Quantum") })
    }

    func test_search_finds_text_block_content() throws {
        let notebook = try makeNotebook()
        let page     = service.fetchPages(in: notebook)[0]
        let block    = try service.createTextBlock(on: page, at: CGRect(x: 0, y: 0, width: 0.5, height: 0.1))
        try service.updateTextBlock(block, richText: NSAttributedString(string: "Schrödinger equation"), rect: nil)
        let results = service.search(query: "Schrödinger")
        XCTAssertTrue(results.contains { $0.type == .textBlock })
    }

    func test_search_finds_transcription() throws {
        let notebook = try makeNotebook()
        let page     = service.fetchPages(in: notebook)[0]
        let ann      = try service.addAudioAnnotation(to: page, fileName: "x.m4a", duration: 1, at: .zero)
        try service.updateTranscription(ann, text: "Wave function collapse", segments: [])
        let results = service.search(query: "collapse")
        XCTAssertTrue(results.contains { $0.type == .transcription })
    }

    func test_search_empty_query_returns_empty() {
        let results = service.search(query: "   ")
        XCTAssertTrue(results.isEmpty)
    }

    func test_search_is_case_insensitive() throws {
        _ = try makeNotebook(title: "Biology Notes")
        XCTAssertFalse(service.search(query: "BIOLOGY").isEmpty)
        XCTAssertFalse(service.search(query: "biology").isEmpty)
    }

    // MARK: - Soft-delete filtering

    func test_softDeleted_records_excluded_from_all_fetches() throws {
        let notebook = try makeNotebook(title: "Trash Me")
        try service.deleteNotebook(notebook)
        XCTAssertFalse(service.fetchAllNotebooks().contains { $0.id == notebook.id })
        // Deleted notebooks should not appear in search
        XCTAssertFalse(service.search(query: "Trash").contains { $0.notebookId == notebook.id })
    }

    // MARK: - Helpers

    private func makeSolidColorJPEG(color: UIColor, size: CGSize) -> Data? {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.8)
    }
}
