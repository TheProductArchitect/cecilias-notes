import Foundation

/// Reason the on-device (Tier 1) quiz generator produced zero
/// questions for a given quiz. Stored per-quiz so the detail view
/// can explain to the user what's missing instead of showing a
/// generic "nothing to quiz on" string. SwiftData isn't involved
/// — these are client-side hints that don't need to sync.
enum QuizGenerationDiagnostic: String, Codable {

    /// The scope resolved to zero notebooks / pages — the user
    /// scoped the quiz at an empty subject or the source notebook
    /// has been deleted.
    case noScopeContent

    /// Scope has notebooks but every text block in them is empty
    /// (PDF / handwritten / sketch-only pages, no typed content,
    /// no transcriptions).
    case noTextInScope

    /// Text was present but didn't match the strict on-device
    /// patterns the Tier 1 engine needs ("X: Y", "X is Y",
    /// "X — Y"). Conversational notes land here.
    case noStructuredPatterns

    /// Requested format requires a cloud/Apple-Intelligence tier
    /// the device doesn't have access to (currently: short-answer
    /// on Tier 1 only).
    case formatNeedsCloud

    /// Catch-all when the generator returns empty but the inputs
    /// looked OK — surfaces a softer copy than the structured
    /// case while still being honest the run failed.
    case unknown

    var userMessage: String {
        switch self {
        case .noScopeContent:
            return "this quiz's scope has no notebooks. open the quiz builder and pick a subject or notebook that contains typed notes."
        case .noTextInScope:
            return "the selected notes don't have any typed text yet — handwritten pages, sketches, and PDF page rasters aren't readable by the on-device engine. type a few notes or add transcribed audio, then regenerate."
        case .noStructuredPatterns:
            return "the on-device engine looks for clear concept → definition patterns (\u{201C}X: …\u{201D}, \u{201C}X is …\u{201D}, headings + bullets) and couldn't find any. conversational prose works better via apple intelligence or mcp — switch the generator in quiz builder."
        case .formatNeedsCloud:
            return "short-answer questions need apple intelligence or mcp — the on-device engine can only build multiple-choice and flashcards. switch the generator in quiz builder, or change the format."
        case .unknown:
            return "couldn't build any questions from these notes. try adding more structured content or switch the generator to apple intelligence / mcp in quiz builder."
        }
    }
}

/// UserDefaults-backed per-quiz diagnostic registry. Stays
/// client-side — diagnostics are recompute-on-regenerate and
/// have no value across devices.
enum QuizDiagnosticStore {

    private static let keyPrefix = "ceciliasnotes.quiz.diagnostic."

    static func record(_ diagnostic: QuizGenerationDiagnostic, for quizID: UUID) {
        UserDefaults.standard.set(diagnostic.rawValue, forKey: keyPrefix + quizID.uuidString)
    }

    static func diagnostic(for quizID: UUID) -> QuizGenerationDiagnostic? {
        guard let raw = UserDefaults.standard.string(forKey: keyPrefix + quizID.uuidString),
              let value = QuizGenerationDiagnostic(rawValue: raw)
        else { return nil }
        return value
    }

    /// Clear the diagnostic — called once a generation run actually
    /// persists at least one question, so a successful regenerate
    /// drops the stale "couldn't generate" hint.
    static func clear(_ quizID: UUID) {
        UserDefaults.standard.removeObject(forKey: keyPrefix + quizID.uuidString)
    }
}
