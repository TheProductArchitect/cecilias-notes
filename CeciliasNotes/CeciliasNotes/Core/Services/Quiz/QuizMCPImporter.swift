import Foundation
import SwiftData

/// Parses a `quiz_generation_response_<uuid>.json` written by
/// `cecilias-notes-mcp` and merges its questions into the matching
/// `Quiz` row (by `quiz_id`). Idempotent across re-fires of the watcher
/// — duplicate responses for the same request are skipped via the
/// `processedRequests` cache.
@MainActor
final class QuizMCPImporter {

    static let shared = QuizMCPImporter()
    private init() {}

    /// Request IDs we've already imported. The watcher de-dupes by
    /// mtime, but if the helper rewrites the same response file with
    /// a fresh timestamp we'd otherwise re-merge. Process-local — a
    /// cold launch can re-import responses still sitting in the Inbox,
    /// which is the right behaviour after the helper recovers from a
    /// crash mid-write.
    private var processedRequests: Set<String> = []

    func importResponse(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data)
        else {
            log("could not decode \(url.lastPathComponent)")
            return
        }
        guard envelope.type == "quiz_generation_response" else { return }

        if let reqID = envelope.request_id, processedRequests.contains(reqID) {
            return
        }
        guard let quizUUID = UUID(uuidString: envelope.quiz_id) else { return }

        let questions = envelope.questions.compactMap(Self.convert)
        log("importing \(questions.count) questions for quiz=\(envelope.quiz_id)")

        QuizGenerationService.shared.mcpResponseReceived(
            quizID: quizUUID,
            questions: questions
        )
        MCPStatusMonitor.shared.recordActivity()
        if let reqID = envelope.request_id { processedRequests.insert(reqID) }

        // Remove the response file once consumed so the Inbox doesn't
        // accumulate stale payloads.
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Conversion

    private static func convert(_ q: ResponseQuestion) -> GeneratedQuestion? {
        guard let type = QuestionType(rawValue: q.type) else { return nil }
        return GeneratedQuestion(
            type: type,
            question: q.question,
            options: q.options ?? [],
            correctOptionIndex: q.correct_option_index,
            frontText: q.front_text ?? (type == .flashcard ? q.question : nil),
            backText: q.back_text,
            sampleAnswer: q.sample_answer,
            keyPoints: q.key_points ?? [],
            sourceText: q.source_text,
            sourceNotebookID: q.source_notebook_id.flatMap(UUID.init(uuidString:))
        )
    }

    private func log(_ message: String) {
        #if DEBUG
        dlog("[QuizMCPImporter] \(message)")
        #endif
    }

    // MARK: - JSON shapes

    private struct ResponseEnvelope: Decodable {
        let type: String
        let request_id: String?
        let quiz_id: String
        let questions: [ResponseQuestion]
    }

    private struct ResponseQuestion: Decodable {
        let type: String
        let question: String
        let options: [String]?
        let correct_option_index: Int?
        let front_text: String?
        let back_text: String?
        let sample_answer: String?
        let key_points: [String]?
        let source_text: String?
        let source_notebook_id: String?
    }
}
