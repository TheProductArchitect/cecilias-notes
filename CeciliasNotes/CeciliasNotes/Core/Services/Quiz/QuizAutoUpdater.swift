import Foundation
import SwiftData

/// Background service that grows quizzes with `autoUpdateEnabled` as
/// their source notes accumulate new content. Runs once on app launch.
/// Entirely silent: never blocks the UI, never surfaces an error, skips
/// anything that fails. Caps each quiz at
/// `QuizGenerationService.maxQuestionsPerQuiz`.
@MainActor
enum QuizAutoUpdater {

    /// Minimum gap between auto-update passes for a given quiz on
    /// the silent launch sweep.
    static let updateInterval: TimeInterval = 7 * 24 * 60 * 60   // 7 days
    /// Snappier cadence for the opened-quiz pass — "I added notes
    /// yesterday, opened the quiz today, where are the new
    /// questions" should just work without waiting out the week.
    static let openedQuizInterval: TimeInterval = 24 * 60 * 60   // 1 day
    /// How many questions a single pass may add.
    static let batchSize = 5

    /// Kick off the launch pass on a detached task so it never delays
    /// the first frame. Safe to call unconditionally.
    static func runOnLaunch() {
        Task { await run() }
    }

    /// Opportunistic single-quiz pass fired when its detail view
    /// opens. Same silent contract as the launch sweep, but with the
    /// daily gap — the user is LOOKING at the quiz, so fresher
    /// content should surface here first.
    static func runForOpenedQuiz(id: UUID) {
        Task { await run(onlyQuizId: id, minimumGap: openedQuizInterval) }
    }

    static func run(onlyQuizId: UUID? = nil, minimumGap: TimeInterval = updateInterval) async {
        let context = StorageService.shared.context
        let now = Date()

        let descriptor = FetchDescriptor<Quiz>(
            predicate: #Predicate<Quiz> {
                $0.autoUpdateEnabled == true && $0.isArchived == false
            }
        )
        guard let quizzes = try? context.fetch(descriptor) else { return }

        for quiz in quizzes {
            if let onlyQuizId, quiz.id != onlyQuizId { continue }
            // Respect the pass cadence.
            if let last = quiz.lastAutoUpdateAt,
               now.timeIntervalSince(last) < minimumGap {
                continue
            }
            // Stop silently once the cap is reached.
            guard quiz.orderedQuestions.count < QuizGenerationService.maxQuestionsPerQuiz else {
                continue
            }

            // Only content added since the last pass (or since the quiz
            // was created, for a first-ever pass).
            let since = quiz.lastAutoUpdateAt ?? quiz.createdAt
            let docs = QuizSourceCollector.collect(
                scope: quiz.sourceScope, context: context, since: since
            )
            // Mark the pass as done regardless of whether there was new
            // content — otherwise an empty week re-checks every launch.
            quiz.lastAutoUpdateAt = now

            if docs.contains(where: { !$0.isEmpty }) {
                _ = await QuizGenerationService.shared.appendQuestions(
                    to: quiz, from: docs, count: batchSize
                )
            }
            do {
                try context.save()
            } catch {
                #if DEBUG
                dlog("[QuizAutoUpdater] SAVE FAILED quizId=\(quiz.id): \(error)")
                #endif
            }
        }
    }
}
