import XCTest
@testable import Ink

/// Covers the validation rules the onboarding TextField applies to the
/// user's name input. Onboarding now requires a name — empty input
/// is `.invalid`, the Continue button is disabled until the field has
/// a non-whitespace character, so this validator never sees empty in
/// practice. Digits or emoji are rejected; otherwise the first
/// whitespace-separated word is stored.
final class OnboardingValidationTests: XCTestCase {

    func test_emptyString_isInvalid() {
        XCTAssertEqual(validateName(""), .invalid)
    }

    func test_whitespaceOnly_isInvalid() {
        XCTAssertEqual(validateName("   "), .invalid)
        XCTAssertEqual(validateName("\n\t"), .invalid)
    }

    func test_simpleName_isAccepted() {
        XCTAssertEqual(validateName("Alex"), .accept("Alex"))
    }

    func test_digit_isRejected() {
        XCTAssertEqual(validateName("Alex123"), .invalid)
        XCTAssertEqual(validateName("3xyz"),    .invalid)
    }

    func test_emoji_isRejected() {
        XCTAssertEqual(validateName("🎨Maria"), .invalid)
        XCTAssertEqual(validateName("Maria 🎨"), .invalid)
    }

    func test_diacritics_areAccepted() {
        XCTAssertEqual(validateName("Naïve"),    .accept("Naïve"))
        XCTAssertEqual(validateName("Émile"),    .accept("Émile"))
        XCTAssertEqual(validateName("Ångström"), .accept("Ångström"))
    }

    func test_apostropheInName_isAccepted() {
        XCTAssertEqual(validateName("O'Brien"), .accept("O'Brien"))
    }

    func test_hyphenatedName_isAccepted() {
        XCTAssertEqual(validateName("Jean-Luc"), .accept("Jean-Luc"))
    }

    func test_multipleWords_takesFirstWord() {
        XCTAssertEqual(validateName("Jean-Luc Picard"), .accept("Jean-Luc"))
        XCTAssertEqual(validateName("Mary  Jane"),       .accept("Mary"))
    }

    func test_leadingTrailingWhitespace_isTrimmedThenFirstWord() {
        XCTAssertEqual(validateName("  Alex  "),         .accept("Alex"))
        XCTAssertEqual(validateName("\nMaria\n"),         .accept("Maria"))
    }

    func test_nonLatinScript_isAccepted() {
        // Spec is "letters only, please" — Cyrillic, Chinese, Arabic
        // count as letters. The icon mapping returns nil for these
        // (handled separately in BrandIconTests); validation accepts
        // them as a name to store.
        XCTAssertEqual(validateName("Анна"), .accept("Анна"))
        XCTAssertEqual(validateName("中文"),  .accept("中文"))
    }
}
