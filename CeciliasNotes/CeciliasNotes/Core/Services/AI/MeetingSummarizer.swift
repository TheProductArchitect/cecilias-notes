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

/// Reformats a finished transcript in place — paragraph breaks
/// between distinct thoughts, a short uppercase heading at clear
/// topic changes, and speaker labels when the transcript itself
/// names the speakers. The words are sacred: the model is
/// instructed to keep them verbatim, and `structureIfFaithful`
/// rejects outputs that lost content, so a failed pass degrades to
/// the raw transcript rather than a rewritten one.
@MainActor
enum TranscriptStructurer {

    /// Below this the live pause-paragraphing is already enough.
    static let minimumCharacters = 200
    /// Above this we skip — chunked structuring can't see across
    /// chunk borders, and a mis-joined seam in the user's own words
    /// is worse than plain paragraphs.
    static let maximumCharacters = 9_000

    private static let systemPrompt = """
        You reformat a raw speech transcript for readability. HARD RULE: keep every \
        word of the transcript exactly as written, in order — never correct grammar, \
        never rephrase, never drop or add words to the spoken text. You may ONLY: \
        (1) insert paragraph breaks (blank line) between distinct thoughts; \
        (2) insert a heading line of 2-4 words in ALL CAPS before a clear topic \
        change (the heading is new text, everything else is verbatim); \
        (3) when the transcript shows a speaker introducing themselves or an obvious \
        turn change, start that line with the speaker's name followed by a colon, \
        using only names that appear in the transcript. \
        If unsure, prefer fewer headings and labels. Output plain text only.
        """

    /// Returns the structured transcript, or nil when the model is
    /// unavailable, the transcript is out of range, or the output
    /// fails the faithfulness check.
    static func structureIfFaithful(_ transcript: String) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters,
              trimmed.count <= maximumCharacters,
              AIService.shared.canRun else { return nil }
        guard let structured = try? await AIService.shared.provider.complete(
            systemPrompt: systemPrompt,
            userPrompt: trimmed,
            maxTokens: 1_600,
            temperature: 0.2
        ) else { return nil }
        guard isFaithful(original: trimmed, structured: structured) else { return nil }
        return structured
    }

    /// Cheap guard against the model rewriting instead of
    /// reformatting: the structured text may ADD headings/labels but
    /// must retain nearly all original words. Compare letters-only
    /// content length — a lossy rewrite shows up as a shortfall.
    static func isFaithful(original: String, structured: String) -> Bool {
        func letterCount(_ s: String) -> Int {
            s.unicodeScalars.lazy.filter { CharacterSet.letters.contains($0) }.count
        }
        let originalLetters = letterCount(original)
        guard originalLetters > 0 else { return false }
        let structuredLetters = letterCount(structured)
        return structuredLetters >= Int(Double(originalLetters) * 0.92)
    }
}
