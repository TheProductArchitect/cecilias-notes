import XCTest
@testable import Ink

final class NameFormatterTests: XCTestCase {

    // mastheadPossessive returns the bare possessive — `BrandWordmark`
    // owns the trailing blue dot, so the helper must NOT include "."
    // in its output. (See Phase C6 refactor.)

    func test_mastheadPossessive_simpleName() {
        XCTAssertEqual(NameFormatter.mastheadPossessive(for: "Venu"), "venu's")
    }

    func test_mastheadPossessive_nameEndingInS() {
        XCTAssertEqual(NameFormatter.mastheadPossessive(for: "James"), "james'")
    }

    func test_mastheadPossessive_emptyFallsBackToCecilia() {
        XCTAssertEqual(NameFormatter.mastheadPossessive(for: ""), "cecilia's")
    }

    func test_mastheadPossessive_trimsAndTakesFirstWord() {
        XCTAssertEqual(
            NameFormatter.mastheadPossessive(for: "  Maria Lopez  "),
            "maria's"
        )
    }

    func test_notesPossessive_simpleName() {
        XCTAssertEqual(NameFormatter.notesPossessive(for: "Sara"), "sara's notes")
    }

    func test_notesPossessive_nameEndingInS() {
        XCTAssertEqual(NameFormatter.notesPossessive(for: "Chris"), "chris' notes")
    }

    func test_normalised_lowercasesAndTakesFirstWord() {
        XCTAssertEqual(NameFormatter.normalised("  Maria Lopez  "), "maria")
        XCTAssertEqual(NameFormatter.normalised("VENU"), "venu")
    }
}
