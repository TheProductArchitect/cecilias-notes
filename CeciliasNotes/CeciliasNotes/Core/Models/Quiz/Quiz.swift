import Foundation
import SwiftData

// MARK: - Enums
//
// All simple `String`-backed Codable enums — stored directly on the
// models the same way `Notebook.coverTexture` / `pageSize` are. The
// CloudKit-backed store can persist these as scalar columns without a
// transformer. Each property that uses one carries an inline default.

enum QuizFormat: String, Codable, CaseIterable {
    case multipleChoice
    case flashcard
    case shortAnswer
    case mixed
}

enum AITier: String, Codable {
    case onDevice
    case appleIntelligence
    case mcp
}

enum QuestionType: String, Codable, CaseIterable {
    case multipleChoice
    case flashcard
    case shortAnswer
}

enum FlashcardRating: String, Codable {
    case again   // didn't know it
    case hard    // knew it with difficulty
    case good    // knew it
    case easy    // knew it instantly
}

// MARK: - Quiz

/// A generated quiz. CloudKit-compatible per the rules in
/// `ModelContainer+CeciliasNotes.swift`: every scalar has an inline
/// default, the scope value-type round-trips through a JSON string
/// column, and the to-many relationships are optional with matching
/// inverses + cascade delete.
@Model
final class Quiz {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// JSON-encoded `QuizScope` — see `QuizScope.jsonString`. Access via
    /// the computed `sourceScope`.
    var sourceScopeRaw: String = ""

    var format: QuizFormat = QuizFormat.mixed
    var generationTier: AITier = AITier.onDevice

    var isArchived: Bool = false
    /// AI appends new questions as the source notes grow (see
    /// `QuizAutoUpdater`). Off by default.
    var autoUpdateEnabled: Bool = false
    var lastAutoUpdateAt: Date?

    /// Optional folder name for organising the sidebar quiz list.
    /// Stored as a plain string rather than a relationship — a Quiz
    /// folder is just a label the user types, like a tag, not a
    /// real entity that owns members. Nil / empty means "no folder"
    /// and the quiz appears under the default "ungrouped" section.
    /// CloudKit-safe: inline default, never required.
    var folderName: String = ""

    // MARK: Relationships
    @Relationship(deleteRule: .cascade, inverse: \QuizQuestion.quiz)
    var questions: [QuizQuestion]?

    @Relationship(deleteRule: .cascade, inverse: \QuizAttempt.quiz)
    var attempts: [QuizAttempt]?

    var sourceScope: QuizScope {
        get { .from(jsonString: sourceScopeRaw) }
        set { sourceScopeRaw = newValue.jsonString }
    }

    /// Questions in stable presentation order.
    var orderedQuestions: [QuizQuestion] {
        (questions ?? []).sorted { $0.orderIndex < $1.orderIndex }
    }

    init(
        title: String,
        sourceScope: QuizScope,
        format: QuizFormat,
        generationTier: AITier
    ) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.sourceScopeRaw = sourceScope.jsonString
        self.format = format
        self.generationTier = generationTier
        self.isArchived = false
        self.autoUpdateEnabled = false
        self.lastAutoUpdateAt = nil
    }
}

// MARK: - QuizQuestion

@Model
final class QuizQuestion {
    var id: UUID = UUID()
    var type: QuestionType = QuestionType.multipleChoice
    var question: String = ""
    /// The note text this was generated from — kept for "from: …"
    /// attribution and as context for AI marking / regeneration.
    var sourceText: String?
    var sourceNotebookID: UUID?
    var orderIndex: Int = 0

    // Multiple choice — options stored as a JSON string array so the
    // CloudKit store never needs a value transformer (same reasoning as
    // `Notebook.tagsRaw`, but JSON so option text may contain anything).
    var optionsRaw: String = ""
    var correctOptionIndex: Int?

    // Flashcard
    var frontText: String?
    var backText: String?

    // Short answer
    var sampleAnswer: String?
    var keyPointsRaw: String = ""

    // MARK: Relationship (back-ref to owning quiz)
    var quiz: Quiz?

    var options: [String] {
        get { Self.decodeStrings(optionsRaw) }
        set { optionsRaw = Self.encodeStrings(newValue) }
    }

    var keyPoints: [String] {
        get { Self.decodeStrings(keyPointsRaw) }
        set { keyPointsRaw = Self.encodeStrings(newValue) }
    }

    init(
        type: QuestionType,
        question: String,
        orderIndex: Int,
        sourceText: String? = nil,
        sourceNotebookID: UUID? = nil
    ) {
        self.id = UUID()
        self.type = type
        self.question = question
        self.orderIndex = orderIndex
        self.sourceText = sourceText
        self.sourceNotebookID = sourceNotebookID
    }

    // MARK: String-array JSON helpers
    static func encodeStrings(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
    static func decodeStrings(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }
}

// MARK: - QuizAttempt

@Model
final class QuizAttempt {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var completedAt: Date?
    var score: Double?           // 0.0–1.0, nil until scored
    var totalQuestions: Int = 0
    var correctCount: Int?

    @Relationship(deleteRule: .cascade, inverse: \QuestionResponse.attempt)
    var responses: [QuestionResponse]?

    var quiz: Quiz?

    init(totalQuestions: Int) {
        self.id = UUID()
        self.startedAt = Date()
        self.totalQuestions = totalQuestions
    }
}

// MARK: - QuestionResponse

@Model
final class QuestionResponse {
    var id: UUID = UUID()
    var questionID: UUID = UUID()
    var questionType: QuestionType = QuestionType.multipleChoice
    var answeredAt: Date = Date()
    var isCorrect: Bool?

    // Multiple choice
    var selectedOptionIndex: Int?

    // Flashcard
    var selfRating: FlashcardRating?

    // Short answer
    var writtenResponse: String?
    var aiScore: Double?
    var aiFeedback: String?

    var attempt: QuizAttempt?

    init(questionID: UUID, questionType: QuestionType) {
        self.id = UUID()
        self.questionID = questionID
        self.questionType = questionType
        self.answeredAt = Date()
    }
}
