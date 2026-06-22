import XCTest
import PencilKit
import SwiftData
import UIKit
@testable import CeciliasNotes

/// Regression coverage for the editor follow-up fixes shipped in
/// commits 30b8b50 (lasso flush, cross-page, ruler ink, paragraph
/// spacing, sticky/shape undo) and the ruler companion-picker
/// follow-up. Each test pins one of the bugs the user reported so a
/// future change that re-breaks the behaviour fails CI loudly.
@MainActor
final class EditorFollowUpTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    // MARK: - Paragraph spacing on Enter

    /// RichTextController.defaultAttributes seeds an NSParagraphStyle
    /// with paragraphSpacing > 0 so user-pressed Enter produces a
    /// visible gap between paragraphs. Soft-wrap inside a paragraph
    /// keeps using the same style (so no extra space mid-line).
    func test_richText_defaultAttributes_setsParagraphSpacing() {
        let attrs = RichTextController.defaultAttributes(ink: .label)
        let para = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertNotNil(para, "default attrs must include a paragraph style")
        XCTAssertGreaterThan(
            para?.paragraphSpacing ?? 0,
            0,
            "Enter must add space between paragraphs — paragraphSpacing > 0"
        )
    }

    // MARK: - LibraryContext round-trip (All Subjects / Quizzes)

    /// Persistence round-trip must cover every case or a relaunch
    /// silently demotes the user's last context to .recent.
    func test_libraryContext_roundTrip_allCases() {
        let cases: [LibraryContext] = [
            .recent,
            .allNotes,
            .allSubjects,
            .allQuizzes,
            .subject(UUID()),
        ]
        for original in cases {
            let raw = original.rawString
            let parsed = LibraryContext(rawString: raw)
            XCTAssertEqual(parsed, original, "round-trip failed for \(original)")
        }
    }

    func test_libraryContext_invalidRaw_returnsNil() {
        XCTAssertNil(LibraryContext(rawString: ""))
        XCTAssertNil(LibraryContext(rawString: "nope"))
        XCTAssertNil(LibraryContext(rawString: "subject:not-a-uuid"))
    }

    // MARK: - Lasso group delete

    /// Lassoing a shape and pressing delete must soft-delete it AND
    /// post the .shapeElementsChanged notification so the shape
    /// overlay re-fetches and the rectangle visually disappears.
    func test_lassoDelete_softDeletesShape_andNotifies() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let element = makeShape(pageId: pageId, into: ctx)
        try ctx.save()

        let selection = LassoSelectionState.shared
        selection.clear()
        selection.setSelection(
            elementIds: [element.id],
            partialStrokes: [:],
            pageId: pageId,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        let expectation = XCTestExpectation(description: "shapeElementsChanged fires")
        let token = NotificationCenter.default.addObserver(
            forName: .shapeElementsChanged, object: nil, queue: nil
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        LassoGroupOps.delete(selection: selection, context: ctx)
        wait(for: [expectation], timeout: 1.0)

        XCTAssertNotNil(element.deletedAt, "shape must be soft-deleted")
        XCTAssertFalse(selection.hasSelection, "selection must clear after delete")
    }

    /// Sticky-note delete via the lasso chrome must broadcast
    /// .stickyNotesChanged — the sticky overlay listens on that
    /// notification, NOT on .shapeElementsChanged.
    func test_lassoDelete_sticky_postsStickyNotification() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let sticky = PageElement(
            pageId: pageId, notebookId: UUID(),
            kind: .stickyNote,
            normalizedX: 0.1, normalizedY: 0.1,
            normalizedWidth: 0.2, normalizedHeight: 0.15,
            zIndex: 1
        )
        sticky.stickyNoteContent = StickyNoteContent(text: "", colorVariant: "yellow")
        ctx.insert(sticky)
        try ctx.save()

        let selection = LassoSelectionState.shared
        selection.clear()
        selection.setSelection(
            elementIds: [sticky.id],
            partialStrokes: [:],
            pageId: pageId,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        let expectation = XCTestExpectation(description: "stickyNotesChanged fires")
        let token = NotificationCenter.default.addObserver(
            forName: .stickyNotesChanged, object: nil, queue: nil
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        LassoGroupOps.delete(selection: selection, context: ctx)
        wait(for: [expectation], timeout: 1.0)

        XCTAssertNotNil(sticky.deletedAt)
    }

    // MARK: - Cross-page handoff

    /// Dragging a single shape past the bottom of the page through
    /// the lasso chrome must hand off via the cross-page notification
    /// instead of clamping. Without the handoff the element snaps
    /// back to the edge of the source page.
    func test_lassoTranslate_singleShape_pastPageEdge_postsHandoff() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let element = makeShape(pageId: pageId, into: ctx)
        element.normalizedY = 0.9
        try ctx.save()

        let selection = LassoSelectionState.shared
        selection.clear()
        selection.setSelection(
            elementIds: [element.id],
            partialStrokes: [:],
            pageId: pageId,
            bounds: CGRect(x: 0, y: 800, width: 100, height: 100)
        )

        let expectation = XCTestExpectation(description: "imageElementCrossPageHandoffRequested fires")
        var capturedInfo: [AnyHashable: Any]?
        let token = NotificationCenter.default.addObserver(
            forName: .imageElementCrossPageHandoffRequested, object: nil, queue: nil
        ) { note in
            capturedInfo = note.userInfo
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Drag 300pt downward on a 1000pt page → +0.3 normalised, well
        // past 1 - height.
        LassoGroupOps.translate(
            selection: selection,
            delta: CGSize(width: 0, height: 300),
            pageSize: CGSize(width: 800, height: 1000),
            context: ctx
        )
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(capturedInfo?["elementId"] as? UUID, element.id)
        XCTAssertEqual(capturedInfo?["currentPageId"] as? UUID, pageId)
        XCTAssertFalse(selection.hasSelection, "selection clears on hand-off")
    }

    /// Cross-page handoff must still fire when the lasso happens
    /// to also catch a partial stroke fragment alongside the
    /// moved element. Device logs showed the most common block on
    /// the handoff was an incidentally-selected stroke fragment;
    /// the fast-path now ignores `partialStrokeSelections`.
    func test_lassoTranslate_pastEdge_withPartialStrokes_stillPostsHandoff() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let element = makeShape(pageId: pageId, into: ctx)
        element.normalizedY = 0.9
        let strokeElementId = UUID()
        try ctx.save()

        let selection = LassoSelectionState.shared
        selection.clear()
        selection.setSelection(
            elementIds: [element.id],
            partialStrokes: [strokeElementId: [0, 2]],
            pageId: pageId,
            bounds: CGRect(x: 0, y: 800, width: 100, height: 100)
        )

        let expectation = XCTestExpectation(description: "handoff fires even with partial strokes")
        let token = NotificationCenter.default.addObserver(
            forName: .imageElementCrossPageHandoffRequested, object: nil, queue: nil
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        LassoGroupOps.translate(
            selection: selection,
            delta: CGSize(width: 0, height: 300),
            pageSize: CGSize(width: 800, height: 1000),
            context: ctx
        )
        wait(for: [expectation], timeout: 1.0)
    }

    /// In-bounds translate must NOT hand off — only the past-edge
    /// case triggers cross-page routing.
    func test_lassoTranslate_inBounds_doesNotPostHandoff() throws {
        let ctx = container.mainContext
        let pageId = UUID()
        let element = makeShape(pageId: pageId, into: ctx)
        element.normalizedY = 0.1
        try ctx.save()

        let selection = LassoSelectionState.shared
        selection.clear()
        selection.setSelection(
            elementIds: [element.id],
            partialStrokes: [:],
            pageId: pageId,
            bounds: CGRect(x: 0, y: 100, width: 100, height: 100)
        )

        let inverseExpectation = XCTestExpectation(description: "no handoff")
        inverseExpectation.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .imageElementCrossPageHandoffRequested, object: nil, queue: nil
        ) { _ in inverseExpectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        LassoGroupOps.translate(
            selection: selection,
            delta: CGSize(width: 0, height: 50),
            pageSize: CGSize(width: 800, height: 1000),
            context: ctx
        )
        wait(for: [inverseExpectation], timeout: 0.5)
    }

    // MARK: - Helpers

    private func makeShape(pageId: UUID, into ctx: ModelContext) -> PageElement {
        let element = PageElement(
            pageId: pageId, notebookId: UUID(),
            kind: .shape,
            normalizedX: 0.1, normalizedY: 0.1,
            normalizedWidth: 0.2, normalizedHeight: 0.15,
            zIndex: 1
        )
        element.shapeContent = ShapeContent(
            shapeKind: .rectangle,
            strokeColorHex: "",
            strokeWidth: 2,
            strokeStyle: .solid
        )
        ctx.insert(element)
        return element
    }
}
