import XCTest
@testable import CeciliasNotes

/// Covers the pure z-order math behind the new "Bring to Front /
/// Send to Back" layer controls — the device ask "there is no way to
/// send elements back" when screenshots overlap.
@MainActor
final class PageElementOrderingTests: XCTestCase {

    private let a = UUID(), b = UUID(), c = UUID()

    private func siblings(_ pairs: [(UUID, Int)]) -> [(id: UUID, zIndex: Int)] {
        pairs.map { (id: $0.0, zIndex: $0.1) }
    }

    func test_toFront_whenBehind_liftsAboveHighestSibling() {
        // a=0 (target, at back), b=1, c=2 → a must clear c(2) → 3.
        let z = PageElementOrdering.newZIndex(
            for: a, move: .toFront, siblings: siblings([(a, 0), (b, 1), (c, 2)])
        )
        XCTAssertEqual(z, 3)
    }

    func test_toFront_whenAlreadyFront_isNoOp() {
        let z = PageElementOrdering.newZIndex(
            for: c, move: .toFront, siblings: siblings([(a, 0), (b, 1), (c, 2)])
        )
        XCTAssertNil(z, "already the frontmost — no write, no undo entry")
    }

    func test_toBack_whenInFront_dropsBelowLowestSibling() {
        // c=2 (target, front), a=0, b=1 → c must clear a(0) → -1.
        let z = PageElementOrdering.newZIndex(
            for: c, move: .toBack, siblings: siblings([(a, 0), (b, 1), (c, 2)])
        )
        XCTAssertEqual(z, -1)
    }

    func test_toBack_whenAlreadyBack_isNoOp() {
        let z = PageElementOrdering.newZIndex(
            for: a, move: .toBack, siblings: siblings([(a, 0), (b, 1), (c, 2)])
        )
        XCTAssertNil(z)
    }

    func test_singleElement_hasNothingToReorder() {
        XCTAssertNil(PageElementOrdering.newZIndex(for: a, move: .toFront, siblings: siblings([(a, 5)])))
        XCTAssertNil(PageElementOrdering.newZIndex(for: a, move: .toBack,  siblings: siblings([(a, 5)])))
    }

    func test_toFront_tolerates_tiedZIndexes() {
        // Legacy rows can all sit at z=0. Bringing one to front must
        // still lift it strictly above the others.
        let z = PageElementOrdering.newZIndex(
            for: b, move: .toFront, siblings: siblings([(a, 0), (b, 0), (c, 0)])
        )
        XCTAssertEqual(z, 1)
    }

    func test_refreshNotification_mapsKindToItsOverlaySignal() {
        XCTAssertEqual(PageElementOrdering.refreshNotification(for: .image), .mediaAttachmentsChanged)
        XCTAssertEqual(PageElementOrdering.refreshNotification(for: .shape), .shapeElementsChanged)
        XCTAssertEqual(PageElementOrdering.refreshNotification(for: .stickyNote), .stickyNotesChanged)
        XCTAssertEqual(PageElementOrdering.refreshNotification(for: .text), .textElementsChanged)
    }
}
