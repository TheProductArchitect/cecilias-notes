import Foundation
import SwiftUI
import UIKit

// MARK: - Storage keys

enum PersonalIdentity {
    static let nameKey               = "app.user.name"
    static let onboardingCompletedKey = "app.onboarding.completed"
}

// MARK: - Name validation

/// Outcome of validating the onboarding TextField. The empty case is
/// distinct from `invalid` because an empty input is an *accepted*
/// completion — the user just opts out of personalisation. Only entries
/// containing digits or emoji are rejected.
enum NameValidationResult: Equatable {
    /// Empty / whitespace only — accept silently, store no name.
    case acceptEmpty
    /// Valid input. The associated value is the stored name (first
    /// whitespace-separated word, original casing preserved).
    case accept(String)
    /// Contains digits or emoji. Show "Letters only, please." inline.
    case invalid
}

/// Runs the validation rules from the spec.
///   • empty / whitespace → acceptEmpty
///   • any digit (U+0030…U+0039)        → invalid
///   • any extended-pictographic emoji   → invalid
///   • otherwise → accept(firstWord)
///
/// Apostrophes, hyphens, diacritics, non-Latin letters all pass through.
func validateName(_ input: String) -> NameValidationResult {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .acceptEmpty }

    for scalar in trimmed.unicodeScalars {
        // Digits.
        if scalar.value >= 0x30 && scalar.value <= 0x39 {
            return .invalid
        }
        // Emoji. `isEmojiPresentation` catches the typical pictographic
        // emoji (faces, hearts, etc.). Some letter-like scalars below
        // U+2600 confuse `isEmoji` alone, so we require the
        // *presentation* property as the disqualifier.
        if scalar.properties.isEmojiPresentation {
            return .invalid
        }
    }

    let firstWord = trimmed.split(whereSeparator: { $0.isWhitespace })
        .first
        .map(String.init) ?? ""
    if firstWord.isEmpty { return .acceptEmpty }
    return .accept(firstWord)
}

// MARK: - Icon variant mapping

/// Maps a name (or arbitrary first character) to one of the 26 alternate
/// icon keys (`a` … `z`), or `nil` if no Latin letter is reachable. Strips
/// diacritics so "Naïve" → "n", "Émile" → "e", "Ångström" → "a". Returns
/// `nil` for names that don't start with a Latin letter (Cyrillic,
/// Chinese, Arabic, etc.) — those keep the default app icon.
enum BrandIcon {
    static func variantKey(for firstCharacter: Character) -> String? {
        // Diacritic strip via folding; works for Latin-derived scripts
        // including Vietnamese, Polish, Czech, Turkish.
        let stripped = String(firstCharacter)
            .folding(options: .diacriticInsensitive, locale: .current)
        guard let asciiChar = stripped.lowercased().first,
              asciiChar.isLetter,
              asciiChar.isASCII
        else { return nil }
        return String(asciiChar)
    }

    /// Convenience wrapper: takes the user's full name (possibly empty),
    /// returns the key — or nil if no valid letter is reachable.
    static func variantKey(forName name: String) -> String? {
        guard let firstChar = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .first
        else { return nil }
        return variantKey(for: firstChar)
    }
}

// MARK: - Greeting

/// Possessive grammar for the Library home greeting.
///   • Empty name → empty string (Library shows nothing in that slot).
///   • Name ending in "s" (case-insensitive) → "name' notes" (Chris' notes).
///   • Otherwise → "name's notes" (alex's notes).
/// Entire string is lowercased — matches the wordmark convention.
func libraryGreeting(forName name: String) -> String {
    guard !name.isEmpty else { return "" }
    let lower  = name.lowercased()
    let suffix = lower.hasSuffix("s") ? "'" : "'s"
    return "\(lower)\(suffix) notes"
}

// MARK: - Icon switching

/// Switch to the alternate icon keyed by the user's name's first letter,
/// or revert to the default if the name is empty / has no Latin letter.
///
/// `setAlternateIconName` triggers a system alert that Apple does not
/// allow apps to suppress or restyle. The onboarding flow frames that
/// alert with a "Personalising your app…" transition so the user's own
/// wordmark anchors the moment.
@MainActor
func updateAppIcon(for name: String) {
    let app = UIApplication.shared
    guard app.supportsAlternateIcons else { return }
    let key = BrandIcon.variantKey(forName: name)
    // setAlternateIconName(nil) reverts to the default icon. Calling it
    // when already at the default is harmless (no alert).
    if app.alternateIconName == key { return }
    app.setAlternateIconName(key) { error in
        if let error = error {
            // Fail silently in production — there's no recovery action
            // we can offer the user. Print so dev builds surface bugs.
            #if DEBUG
            print("[BrandIcon] setAlternateIconName(\(key ?? "nil")) failed: \(error)")
            #endif
        }
    }
}
