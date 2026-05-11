import Foundation

/// Formatting helpers for the user's display name.
///
/// The wordmark renders the user's name in possessive form, lowercased.
/// Names that already end in `s` take a bare apostrophe (`james'`); all
/// others take the standard `'s` (`sara's`). When the user hasn't set
/// a name yet we fall back to `cecilia` — the App Store name.
enum NameFormatter {

    // MARK: Normalisation

    /// Lowercased, trimmed, first-word-only. Used as the canonical
    /// short form everywhere in the redesigned UI.
    static func normalised(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstWord = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        return firstWord.lowercased()
    }

    // MARK: Possessive forms

    /// Possessive form for the masthead — *without* the trailing dot.
    /// The blue brand dot is owned by `BrandWordmark`, so callers feed
    /// it the bare possessive and the wordmark renders the dot itself.
    /// - `"Venu"`  → `"venu's"`
    /// - `"James"` → `"james'"`
    /// - `""`      → `"cecilia's"`
    static func mastheadPossessive(for name: String) -> String {
        let normal = normalised(name)
        let raw = normal.isEmpty ? "cecilia" : normal
        let suffix = raw.hasSuffix("s") ? "'" : "'s"
        return "\(raw)\(suffix)"
    }

    /// Possessive form for "[name]'s notes" — no trailing dot. Used on
    /// notebook covers and copy.
    /// - `"Venu"`  → `"venu's notes"`
    /// - `"James"` → `"james' notes"`
    /// - `""`      → `"cecilia's notes"`
    static func notesPossessive(for name: String) -> String {
        let normal = normalised(name)
        let raw = normal.isEmpty ? "cecilia" : normal
        let suffix = raw.hasSuffix("s") ? "'" : "'s"
        return "\(raw)\(suffix) notes"
    }
}
