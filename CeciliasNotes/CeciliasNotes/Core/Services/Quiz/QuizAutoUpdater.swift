import Foundation
import SwiftData

/// Background service that grows quizzes with `autoUpdateEnabled` as
/// their source notes accumulate new content. Runs once on app launch.
/// Entirely silent: never blocks the UI, never surfaces an error, skips
/// anything that fails. Caps each quiz at
/// `QuizGenerationService.maxQuestionsPerQuiz`.
@MainActor
enum QuizAutoUpdater {

    /// Minimum gap between auto-update passes for a given quiz.
    static let updateInterval: TimeInterval = 7 * 24 * 60 * 60   // 7 days
    /// How many questions a single pass may add.
    static let batchSize = 5

    /// Kick off the launch pass on a detached task so it never delays
    /// the first frame. Safe to call unconditionally.
    static func runOnLaunch() {
        Task { await run() }
    }

    static func run() async {
        let context = StorageService.shared.context
        let now = Date()

        let descriptor = FetchDescriptor<Quiz>(
            predicate: #Predicate<Quiz> {
                $0.autoUpdateEnabled == true && $0.isArchived == false
            }
        )
        guard let quizzes = try? context.fetch(descriptor) else { return }

        for quiz in quizzes {
            // Respect the weekly cadence.
            if let last = quiz.lastAutoUpdateAt,
               now.timeIntervalSince(last) < updateInterval {
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
            try? context.save()
        }
    }
}
