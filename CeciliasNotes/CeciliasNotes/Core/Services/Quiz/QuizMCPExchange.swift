import Foundation

/// Writes a `quiz_generation_request_<uuid>.json` to the iCloud Inbox
/// for `cecilias-notes-mcp` to pick up on the user's Mac. The matching
/// response is imported by `QuizMCPImporter` once it lands in the same
/// folder.
///
/// The Mac helper isn't running in this build path — that's a separate
/// repo — but the request/response contract on this side is complete
/// enough that the user can `ls` the Inbox in Files.app and verify a
/// request was emitted.
@MainActor
enum QuizMCPExchange {

    /// Writes a request JSON for the given quiz. The quiz must already
    /// exist (the response merges questions into it by `quiz_id`).
    @discardableResult
    static func writeRequest(
        quizID: UUID,
        title: String,
        format: QuizFormat,
        questionCount: Int,
        existingQuestionCount: Int,
        documents: [QuizSourceDocument]
    ) -> URL? {
        guard let inbox = CeciliasNotesFileWatcher.sharedInboxURL() else { return nil }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let requestID = UUID()
        let body = RequestEnvelope(
            type: "quiz_generation_request",
            id: requestID.uuidString,
            created_at: ISO8601DateFormatter().string(from: Date()),
            quiz_id: quizID.uuidString,
            quiz_title: title,
            format: format.rawValue,
            question_count: questionCount,
            existing_question_count: existingQuestionCount,
            source_text: documents.map {
                SourceBlock(
                    notebook_title: $0.notebookTitle,
                    subject: $0.subjectName,
                    content: $0.allText.joined(separator: "\n\n")
                )
            }
        )

        let url = inbox.appendingPathComponent("quiz_generation_request_\(requestID.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(body) else { return nil }

        // Coordinated write so iCloud picks up the file cleanly.
        var coordError: NSError?
        var resultURL: URL?
        let coord = NSFileCoordinator()
        coord.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { written in
            try? data.write(to: written, options: .atomic)
            resultURL = written
        }
        return resultURL
    }

    // MARK: - JSON shapes

    private struct RequestEnvelope: Encodable {
        let type: String
        let id: String
        let created_at: String
        let quiz_id: String
        let quiz_title: String
        let format: String
        let question_count: Int
        let existing_question_count: Int
        let source_text: [SourceBlock]
    }

    private struct SourceBlock: Encodable {
        let notebook_title: String
        let subject: String?
        let content: String
    }
}
