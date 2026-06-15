import Combine
import Foundation
import SwiftData

/// Orchestrates quiz generation: resolves the source text, picks the
/// best available tier (with silent fallback), runs the generator off
/// the main actor where possible, and persists the `Quiz` +
/// `QuizQuestion` rows. The UI calls `createQuiz(...)`, which returns
/// immediately with a persisted (initially empty) `Quiz` and fills in
/// questions on a background task — the sidebar shows a progress
/// indicator for any id in `generatingQuizIDs`.
@MainActor
final class QuizGenerationService: ObservableObject {

    static let shared = QuizGenerationService()
    private init() {}

    /// Quiz ids currently generating — drives the sidebar spinner.
    @Published private(set) var generatingQuizIDs: Set<UUID> = []

    private var context: ModelContext { StorageService.shared.context }

    // MARK: - Tier resolution

    /// Tiers available on this device/configuration, best last.
    func availableTiers() -> [AITier] {
        var tiers: [AITier] = [.onDevice]
        if IntelligenceService.shared.canRun { tiers.append(.appleIntelligence) }
        if MCPStatusMonitor.shared.hasEverConnected { tiers.append(.mcp) }
        return tiers
    }

    /// The tier actually used given a requested one, downgrading when
    /// the request isn't available (e.g. Apple Intelligence off → on-device).
    func resolvedTier(requested: AITier) -> AITier {
        let available = availableTiers()
        if available.contains(requested) { return requested }
        return available.last ?? .onDevice
    }

    // MARK: - Create + generate

    /// Persist a new quiz immediately, then generate its questions in
    /// the background. Returns the quiz so the caller can select it.
    @discardableResult
    func createQuiz(
        title: String,
        scope: QuizScope,
        format: QuizFormat,
        requestedTier: AITier,
        questionCount: Int,
        autoUpdate: Bool
    ) -> Quiz {
        let tier = resolvedTier(requested: requestedTier)
        let quiz = Quiz(title: title, sourceScope: scope, format: format, generationTier: tier)
        quiz.autoUpdateEnabled = autoUpdate
        context.insert(quiz)
        try? context.save()

        generatingQuizIDs.insert(quiz.id)
        let quizID = quiz.id
        Task { [weak self] in
            await self?.runGeneration(quizID: quizID, scope: scope, format: format, tier: tier, count: questionCount)
        }
        return quiz
    }

    /// Append freshly-generated questions to an existing quiz from only
    /// new source text. Used by `QuizAutoUpdater`. Returns how many were
    /// added (0 on no-op / failure — never throws).
    @discardableResult
    func appendQuestions(
        to quiz: Quiz,
        from documents: [QuizSourceDocument],
        count: Int
    ) async -> Int {
        let existing = quiz.orderedQuestions.count
        guard existing < Self.maxQuestionsPerQuiz else { return 0 }
        let room = Self.maxQuestionsPerQuiz - existing
        let want = min(count, room)
        let generated = await generateQuestions(
            documents: documents, format: quiz.format, tier: quiz.generationTier, count: want
        )
        guard !generated.isEmpty else { return 0 }
        persist(generated, into: quiz, startingAt: existing)
        return generated.count
    }

    static let maxQuestionsPerQuiz = 100

    // MARK: - Internal

    private func runGeneration(
        quizID: UUID,
        scope: QuizScope,
        format: QuizFormat,
        tier: AITier,
        count: Int
    ) async {
        let documents = QuizSourceCollector.collect(scope: scope, context: context)

        if tier == .mcp {
            // Hand off to the Mac helper via the iCloud Inbox. We keep
            // `generatingQuizIDs` set — the sidebar spinner stays
            // visible — until the response file lands and
            // `mcpResponseReceived(...)` clears the flag. If the helper
            // never replies, the quiz stays in "generating" state; the
            // user can regenerate via the detail view.
            let title = fetchQuiz(id: quizID)?.title ?? "new quiz"
            let existing = fetchQuiz(id: quizID)?.orderedQuestions.count ?? 0
            QuizMCPExchange.writeRequest(
                quizID: quizID,
                title: title,
                format: format,
                questionCount: count,
                existingQuestionCount: existing,
                documents: documents
            )
            return
        }

        let generated = await generateQuestions(documents: documents, format: format, tier: tier, count: count)
        guard let quiz = fetchQuiz(id: quizID) else {
            generatingQuizIDs.remove(quizID)
            return
        }
        if generated.isEmpty {
            // Surface a specific reason in the detail view's empty
            // state so the user understands what's missing rather
            // than seeing a generic "nothing to quiz on" string.
            QuizDiagnosticStore.record(
                diagnoseEmptyResult(documents: documents, format: format),
                for: quizID
            )
        } else {
            QuizDiagnosticStore.clear(quizID)
        }
        persist(generated, into: quiz, startingAt: 0)
        generatingQuizIDs.remove(quizID)
        HapticManager.shared.exportCompleted()
    }

    /// Classify why an on-device generation run produced zero
    /// questions. Ordering matters: scope before content, content
    /// before pattern recognition — we want the most actionable
    /// reason surfaced, not a deeper one the user can't fix
    /// without first fixing the shallower problem.
    private func diagnoseEmptyResult(
        documents: [QuizSourceDocument],
        format: QuizFormat
    ) -> QuizGenerationDiagnostic {
        if documents.isEmpty { return .noScopeContent }
        if documents.allSatisfy({ $0.isEmpty }) { return .noTextInScope }
        if format == .shortAnswer { return .formatNeedsCloud }
        return .noStructuredPatterns
    }

    /// Hook for `QuizMCPImporter` to merge MCP-authored questions into
    /// the matching quiz and clear the in-progress flag.
    func mcpResponseReceived(quizID: UUID, questions: [GeneratedQuestion]) {
        defer { generatingQuizIDs.remove(quizID) }
        guard let quiz = fetchQuiz(id: quizID) else { return }
        let startingAt = quiz.orderedQuestions.count
        persist(questions, into: quiz, startingAt: startingAt)
        if !questions.isEmpty { QuizDiagnosticStore.clear(quizID) }
        HapticManager.shared.exportCompleted()
    }

    /// Run the right generator for the tier, falling back to on-device
    /// if an AI tier yields nothing (availability lost mid-flight, parse
    /// failure, etc.). MCP is handled out-of-band (async file exchange),
    /// so here it also falls back to on-device for the synchronous path.
    private func generateQuestions(
        documents: [QuizSourceDocument],
        format: QuizFormat,
        tier: AITier,
        count: Int
    ) async -> [GeneratedQuestion] {
        guard !documents.allSatisfy({ $0.isEmpty }) else { return [] }

        if tier == .appleIntelligence {
            let ai = AppleIntelligenceQuizGenerator()
            if ai.isAvailable {
                let result = await ai.generate(from: documents, format: format, count: count)
                if !result.isEmpty { return result }
            }
        }
        // Tier 1 / fallback.
        return OnDeviceQuizGenerator().generate(from: documents, format: format, count: count)
    }

    private func persist(_ generated: [GeneratedQuestion], into quiz: Quiz, startingAt startIndex: Int) {
        for (offset, g) in generated.enumerated() {
            let q = QuizQuestion(
                type: g.type,
                question: g.question,
                orderIndex: startIndex + offset,
                sourceText: g.sourceText,
                sourceNotebookID: g.sourceNotebookID
            )
            q.options = g.options
            q.correctOptionIndex = g.correctOptionIndex
            q.frontText = g.frontText
            q.backText = g.backText
            q.sampleAnswer = g.sampleAnswer
            q.keyPoints = g.keyPoints
            q.quiz = quiz
            context.insert(q)
        }
        quiz.updatedAt = Date()
        try? context.save()
    }

    private func fetchQuiz(id: UUID) -> Quiz? {
        var descriptor = FetchDescriptor<Quiz>(predicate: #Predicate<Quiz> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
