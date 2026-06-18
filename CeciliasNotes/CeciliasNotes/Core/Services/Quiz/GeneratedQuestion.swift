import Foundation

/// A generated question in transport form — plain value type the
/// generators return and the persistence layer turns into
/// `QuizQuestion` models. Keeps generation free of SwiftData so it can
/// run off the main actor.
///
/// The on-device tier this struct was originally co-located with was
/// retired in favour of Apple Intelligence + MCP. The struct survives
/// as the lingua franca every remaining generator (AI / MCP) hands
/// back to the persistence layer.
struct GeneratedQuestion {
    var type: QuestionType
    var question: String
    var options: [String] = []
    var correctOptionIndex: Int?
    var frontText: String?
    var backText: String?
    var sampleAnswer: String?
    var keyPoints: [String] = []
    var sourceText: String?
    var sourceNotebookID: UUID?
}
