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
    /// the device doesn't have access to.
    case formatNeedsCloud

    /// No generation tier is available on this device (Apple
    /// Intelligence off + MCP never connected). Quiz generation
    /// is gated on at least one of these — the legacy on-device
    /// generator was retired.
    case noTierAvailable

    /// Apple Intelligence was selected but produced no questions
    /// despite having text — model returned empty, parse failed,
    /// availability lost mid-flight, etc.
    case aiReturnedEmpty

    /// Catch-all when the generator returns empty but the inputs
    /// looked OK — surfaces a softer copy than the structured
    /// case while still being honest the run failed.
    case unknown

    var userMessage: String {
        switch self {
        case .noScopeContent:
            return "this quiz's scope has no notebooks. open the quiz builder and pick a subject or notebook that contains typed notes."
        case .noTextInScope:
            return "the selected notes don't have any typed text yet — handwritten pages, sketches, and image-only PDFs aren't readable. type a few notes, add transcribed audio, or import a digital pdf, then regenerate."
        case .noStructuredPatterns:
            return "the generator couldn't find concept-definition patterns in these notes. try a different scope, or rely on apple intelligence / mcp which handle free-form prose better."
        case .formatNeedsCloud:
            return "this format requires apple intelligence or mcp — switch the generator in quiz builder, or change the format."
        case .noTierAvailable:
            return "quiz generation needs apple intelligence or mcp. turn on apple intelligence in settings → intelligence, or connect mcp on your mac."
        case .aiReturnedEmpty:
            return "apple intelligence couldn't build questions from these notes — the model returned nothing. try a different scope or add more content, then regenerate."
        case .unknown:
            return "couldn't build any questions from these notes. try a different scope or add more content."
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
