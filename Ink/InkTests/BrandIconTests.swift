import XCTest
@testable import Ink

/// Verifies the 26-letter alternate-icon variant key resolution. Names
/// that don't start with a Latin letter (Cyrillic, Chinese, digits)
/// must return `nil` — those names keep the default icon. Diacritics
/// are stripped so "Naïve" → "n", "Émile" → "e".
final class BrandIconTests: XCTestCase {

    func test_uppercaseAscii_isLowercased() {
        XCTAssertEqual(BrandIcon.variantKey(for: "A"), "a")
        XCTAssertEqual(BrandIcon.variantKey(for: "Z"), "z")
    }

    func test_lowercaseAscii_isReturnedUnchanged() {
        XCTAssertEqual(BrandIcon.variantKey(for: "k"), "k")
    }

    func test_diacriticsAreFolded_naive() {
        let first = "Naïve".first
        XCTAssertNotNil(first)
        XCTAssertEqual(BrandIcon.variantKey(for: first!), "n")
    }

    func test_diacriticsAreFolded_emile() {
        let first = "Émile".first
        XCTAssertNotNil(first)
        XCTAssertEqual(BrandIcon.variantKey(for: first!), "e")
    }

    func test_diacriticsAreFolded_angstrom() {
        let first = "Ångström".first
        XCTAssertNotNil(first)
        XCTAssertEqual(BrandIcon.variantKey(for: first!), "a")
    }

    func test_nonLatinScript_returnsNil() {
        let first = "中文".first
        XCTAssertNotNil(first)
        XCTAssertNil(BrandIcon.variantKey(for: first!))
    }

    func test_cyrillic_returnsNil() {
        let first = "Анна".first
        XCTAssertNotNil(first)
        XCTAssertNil(BrandIcon.variantKey(for: first!))
    }

    func test_digit_returnsNil() {
        let first = "1".first
        XCTAssertNotNil(first)
        XCTAssertNil(BrandIcon.variantKey(for: first!))
    }

    func test_punctuation_returnsNil() {
        let first = "!hello".first
        XCTAssertNotNil(first)
        XCTAssertNil(BrandIcon.variantKey(for: first!))
    }

    // Convenience wrapper that takes a full name.

    func test_variantKey_forName_emptyString_isNil() {
        XCTAssertNil(BrandIcon.variantKey(forName: ""))
    }

    func test_variantKey_forName_strippedToFirstLetter() {
        XCTAssertEqual(BrandIcon.variantKey(forName: "Naïve"),         "n")
        XCTAssertEqual(BrandIcon.variantKey(forName: "  Émile"),       "e")
        XCTAssertEqual(BrandIcon.variantKey(forName: "jean-luc picard"), "j")
    }
}
