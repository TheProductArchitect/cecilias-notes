import Combine
import Foundation
import SwiftData

/// Drives one run through a quiz: tracks the current question, records
/// each answer, marks short answers (via Apple Intelligence when
/// available), and on completion persists a `QuizAttempt` +
/// `QuestionResponse` rows and computes the result. Quitting mid-run
/// discards everything — only completed runs are stored.
@MainActor
final class QuizTakingViewModel: ObservableObject {

    private(set) var questions: [QuizQuestion]
    private let quizID: UUID
    private let context: ModelContext
    /// A "review missed" run — practice over a subset. Not persisted as
    /// an attempt, so it doesn't skew the quiz's best score.
    private var isReview: Bool = false

    @Published var index: Int = 0
    @Published private(set) var isFinished: Bool = false
    @Published private(set) var result: QuizResult?

    /// In-memory drafts keyed by question id; flushed to SwiftData on
    /// `finish()`.
    private var drafts: [UUID: Draft] = [:]

    struct Draft {
        var selectedOptionIndex: Int?
        var selfRating: FlashcardRating?
        var writtenResponse: String?
        var aiScore: Double?
        var aiFeedback: String?
        var isCorrect: Bool
    }

    init(quiz: Quiz, context: ModelContext) {
        self.quizID = quiz.id
        self.questions = quiz.orderedQuestions
        self.context = context
    }

    var current: QuizQuestion? {
        questions.indices.contains(index) ? questions[index] : nil
    }

    var progress: Double {
        guard !questions.isEmpty else { return 0 }
        return Double(index) / Double(questions.count)
    }

    var isLastQuestion: Bool { index >= questions.count - 1 }

    func draft(for questionID: UUID) -> Draft? { drafts[questionID] }

    // MARK: - Answering

    func answerMultipleChoice(_ optionIndex: Int) {
        guard let q = current else { return }
        let correct = (optionIndex == q.correctOptionIndex)
        drafts[q.id] = Draft(
            selectedOptionIndex: optionIndex,
            isCorrect: correct
        )
    }

    func answerFlashcard(_ rating: FlashcardRating) {
        guard let q = current else { return }
        drafts[q.id] = Draft(
            selfRating: rating,
            isCorrect: rating == .good || rating == .easy
        )
        advanceOrFinish()
    }

    /// Self-assessment fallback for short answer when no AI marker is
    /// available.
    func answerShortAnswerSelfAssessed(_ gotIt: Bool, text: String) {
        guard let q = current else { return }
        drafts[q.id] = Draft(
            writtenResponse: text,
            isCorrect: gotIt
        )
    }

    /// Mark a short answer with Apple Intelligence (if available).
    /// Returns the feedback string to show inline, or nil if no marker
    /// ran (caller then shows the self-assessment affordance).
    func markShortAnswer(_ text: String) async -> (score: Double, feedback: String)? {
        guard let q = current else { return nil }
        let marker = AppleIntelligenceQuizGenerator()
        guard marker.isAvailable else { return nil }
        let mark = await marker.markShortAnswer(
            question: q.question,
            sampleAnswer: q.sampleAnswer ?? "",
            keyPoints: q.keyPoints,
            userAnswer: text
        )
        guard let mark else { return nil }
        drafts[q.id] = Draft(
            writtenResponse: text,
            aiScore: mark.score,
            aiFeedback: mark.feedback,
            isCorrect: mark.score >= 0.5
        )
        return mark
    }

    // MARK: - Navigation

    func advanceOrFinish() {
        if isLastQuestion {
            finish()
        } else {
            index += 1
        }
    }

    func finish() {
        guard !isFinished else { return }
        if !isReview { persistAttempt() }
        result = computeResult()
        isFinished = true
    }

    /// Restart the session over a subset of questions (the missed ones)
    /// as a non-persisted practice run.
    func restart(with newQuestions: [QuizQuestion]) {
        guard !newQuestions.isEmpty else { return }
        questions = newQuestions
        drafts.removeAll()
        index = 0
        result = nil
        isReview = true
        isFinished = false
    }

    // MARK: - Persistence

    private func persistAttempt() {
        let attempt = QuizAttempt(totalQuestions: questions.count)
        attempt.completedAt = Date()

        var correct = 0
        for q in questions {
            guard let d = drafts[q.id] else { continue }
            if d.isCorrect { correct += 1 }
            let response = QuestionResponse(questionID: q.id, questionType: q.type)
            response.selectedOptionIndex = d.selectedOptionIndex
            response.selfRating = d.selfRating
            response.writtenResponse = d.writtenResponse
            response.aiScore = d.aiScore
            response.aiFeedback = d.aiFeedback
            response.isCorrect = d.isCorrect
            response.attempt = attempt
            context.insert(response)
        }
        attempt.correctCount = correct
        attempt.score = questions.isEmpty ? 0 : Double(correct) / Double(questions.count)

        // Link to the quiz.
        if let quiz = fetchQuiz() {
            attempt.quiz = quiz
        }
        context.insert(attempt)
        do {
            try context.save()
        } catch {
            // The quiz attempt — score, per-response history,
            // duration — is silently lost on failure. User finishes
            // the quiz, sees the score animate, then doesn't see
            // it appear in the history list later. Log the cause.
            #if DEBUG
            dlog("[QuizTaking] attempt commit SAVE FAILED quizId=\(quizID): \(error)")
            #endif
        }
    }

    private func fetchQuiz() -> Quiz? {
        let id = quizID
        var d = FetchDescriptor<Quiz>(predicate: #Predicate<Quiz> { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    // MARK: - Result

    private func computeResult() -> QuizResult {
        var byType: [QuestionType: (correct: Int, total: Int)] = [:]
        var missed: [String] = []
        var missedIDs: [UUID] = []
        var correct = 0

        for q in questions {
            let d = drafts[q.id]
            let isCorrect = d?.isCorrect ?? false
            if isCorrect { correct += 1 }
            var entry = byType[q.type] ?? (0, 0)
            entry.total += 1
            if isCorrect { entry.correct += 1 }
            byType[q.type] = entry
            if !isCorrect {
                missed.append(q.question)
                missedIDs.append(q.id)
            }
        }

        return QuizResult(
            correct: correct,
            total: questions.count,
            byType: byType,
            missed: missed,
            missedQuestionIDs: missedIDs
        )
    }
}

// MARK: - Result model

struct QuizResult {
    let correct: Int
    let total: Int
    let byType: [QuestionType: (correct: Int, total: Int)]
    let missed: [String]
    let missedQuestionIDs: [UUID]

    var fraction: Double { total == 0 ? 0 : Double(correct) / Double(total) }

    /// A characterful one-liner matched to the score band (PRD pool).
    var characterLine: String {
        let pct = fraction
        let pool: [String]
        switch pct {
        case 0.9...:
            pool = ["you clearly paid attention.", "your notes are doing their job.", "that's what revision looks like."]
        case 0.7..<0.9:
            pool = ["not bad.", "most of it landed.", "solid. the gaps are worth noting."]
        case 0.5..<0.7:
            pool = ["you're getting there.", "some of it stuck.", "worth another pass."]
        default:
            pool = ["the notes need a revisit.", "back to the page.", "that's what quizzes are for."]
        }
        // Deterministic pick (no Date/random in this codebase's rules):
        // index by score so the same result reads consistently.
        let idx = min(pool.count - 1, Int((pct * 100).rounded()) % pool.count)
        return pool[idx]
    }

    var orderedTypeBreakdown: [(type: QuestionType, correct: Int, total: Int)] {
        let order: [QuestionType] = [.multipleChoice, .flashcard, .shortAnswer]
        return order.compactMap { t in
            guard let e = byType[t] else { return nil }
            return (t, e.correct, e.total)
        }
    }
}

extension QuestionType {
    var displayName: String {
        switch self {
        case .multipleChoice: return "multiple choice"
        case .flashcard:      return "flashcards"
        case .shortAnswer:    return "short answer"
        }
    }
}
