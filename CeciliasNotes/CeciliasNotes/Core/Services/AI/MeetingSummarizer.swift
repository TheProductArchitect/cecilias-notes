import Foundation

/// Distills a dictation/meeting transcript with the on-device model.
/// Platform-neutral: the Mac and iPad recording pipelines both call
/// this so a meeting summarized on either device reads identically.
///
/// Long transcripts are handled map-reduce style: condense each
/// slice, then fold the condensed notes into one summary. If even
/// the joined partials exceed the window (multi-hour meeting),
/// recurse — each round shrinks the text by roughly 10×.
@MainActor
enum MeetingSummarizer {

    /// Below this the transcript IS the summary — don't add noise.
    static let minimumTranscriptCharacters = 280

    /// Per-chunk budget for the map phase. Sized against the same
    /// conservative window `AIService.maxPromptCharacters` uses.
    private static let chunkCharacters = 9_000

    static var canRun: Bool { AIService.shared.canRun }

    private static let mapSystemPrompt = """
        You condense a segment of a meeting transcript. Extract only what matters: \
        topics discussed, decisions made, action items with owners, open questions, \
        and key facts or numbers. Write terse bullet lines, no preamble.
        """

    private static let reduceSystemPrompt = """
        You write the final summary of a meeting from condensed notes. Structure it as: \
        a 1-3 sentence overview paragraph, then a short list of key points, then \
        "Decisions:" and "Action items:" lines when any exist (omit the label when \
        there are none). Plain text only — no markdown symbols like # or *. Use \
        "- " for list items. Be concise and specific; never invent details.
        """

    static func summarize(transcript: String) async throws -> String {
        let provider = AIService.shared.provider

        if transcript.count <= chunkCharacters {
            return try await provider.complete(
                systemPrompt: reduceSystemPrompt,
                userPrompt: transcript,
                maxTokens: 700,
                temperature: 0.3
            )
        }

        var partials: [String] = []
        var start = transcript.startIndex
        while start < transcript.endIndex {
            let end = transcript.index(
                start, offsetBy: chunkCharacters, limitedBy: transcript.endIndex
            ) ?? transcript.endIndex
            let chunk = String(transcript[start..<end])
            let partial = try await provider.complete(
                systemPrompt: mapSystemPrompt,
                userPrompt: chunk,
                maxTokens: 400,
                temperature: 0.3
            )
            partials.append(partial)
            start = end
        }

        let joined = partials.joined(separator: "\n")
        if joined.count > chunkCharacters {
            return try await summarize(transcript: joined)
        }
        return try await provider.complete(
            systemPrompt: reduceSystemPrompt,
            userPrompt: joined,
            maxTokens: 700,
            temperature: 0.3
        )
    }
}
