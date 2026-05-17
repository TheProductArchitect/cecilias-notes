import Foundation

/// Validation + normalisation for free-form notebook tags.
///
/// Mirrors the existing name-validation contract (lowercase, trimmed,
/// no emoji / no digits, capped length). Tags are stored on
/// `Notebook` as a `\u{001F}`-joined string and exposed via the
/// `tags: [String]` computed accessor — the validator is the single
/// gatekeeper for what's allowed to land in that array.
///
/// No backend, no analytics — this is pure on-device validation.
enum TagValidator {

    static let maxTagLength = 32
    static let maxTagsPerNotebook = 20

    enum Issue: Error, Equatable {
        case empty
        case tooLong
        case containsDigit
        case containsEmoji
        case duplicate
        case tooManyTags
    }

    /// Returns the lowercased, trimmed form of `raw` ready for
    /// storage, or `nil` if the input is empty after trimming.
    /// Doesn't reject emoji / digits — call `validate(_:against:)`
    /// for that check.
    static func normalised(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Validate `raw` against the existing tag list. Returns either
    /// `.success(normalised)` or `.failure(issue)`. Duplicate
    /// detection compares against the already-normalised tag list,
    /// so case / whitespace differences don't sneak in twice.
    static func validate(
        _ raw: String,
        against existing: [String]
    ) -> Result<String, Issue> {
        guard existing.count < maxTagsPerNotebook else { return .failure(.tooManyTags) }
        guard let normal = normalised(raw) else { return .failure(.empty) }
        guard normal.count <= maxTagLength      else { return .failure(.tooLong) }
        guard !containsDigit(normal)            else { return .failure(.containsDigit) }
        guard !containsEmoji(normal)            else { return .failure(.containsEmoji) }
        guard !existing.contains(normal)        else { return .failure(.duplicate) }
        return .success(normal)
    }

    // MARK: Predicates

    private static func containsDigit(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    private static func containsEmoji(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || scalar.properties.isEmoji && scalar.value > 0x238C
        }
    }
}
