import XCTest
@testable import CeciliasNotes

/// Library home greeting possessive logic. Names ending in `s`
/// (case-insensitive after lowercasing) take a trailing apostrophe
/// only — `chris' notes` not `chris's notes`. Empty input returns an
/// empty string so the greeting slot collapses cleanly.
@MainActor
final class PossessiveGrammarTests: XCTestCase {

    func test_simpleName_addsApostropheS() {
        XCTAssertEqual(libraryGreeting(forName: "Alex"),  "alex's notes")
        XCTAssertEqual(libraryGreeting(forName: "Maria"), "maria's notes")
    }

    func test_nameEndingInS_addsApostropheOnly() {
        XCTAssertEqual(libraryGreeting(forName: "Chris"), "chris' notes")
        XCTAssertEqual(libraryGreeting(forName: "James"), "james' notes")
    }

    func test_nameEndingInUppercaseS_addsApostropheOnly() {
        // Case shouldn't matter because we lowercase before checking
        // the suffix.
        XCTAssertEqual(libraryGreeting(forName: "MARCUS"), "marcus' notes")
    }

    func test_diacriticName_isLowercased() {
        XCTAssertEqual(libraryGreeting(forName: "Naïve"), "naïve's notes")
    }

    func test_apostrophedName_appendsCorrectly() {
        // `O'Brien` ends in `n` so takes `'s`. The apostrophe inside
        // the name is preserved as-is.
        XCTAssertEqual(libraryGreeting(forName: "O'Brien"), "o'brien's notes")
    }

    func test_emptyName_returnsEmpty() {
        XCTAssertEqual(libraryGreeting(forName: ""), "")
    }
}
