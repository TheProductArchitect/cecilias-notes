import Foundation
import NaturalLanguage

/// A generated question in transport form — plain value type the
/// generators return and the persistence layer turns into
/// `QuizQuestion` models. Keeps generation free of SwiftData so it can
/// run off the main actor.
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

/// Tier 1 — always-available, on-device, no network. Extracts
/// definition patterns, named entities and key phrases from typed
/// notes + transcriptions and builds multiple-choice / flashcard
/// questions. Short-answer is out of reach here (needs a model that can
/// mark free text) — `mixed` simply drops the short-answer share when
/// only Tier 1 is available.
struct OnDeviceQuizGenerator {

    /// A term/definition pair extracted from the notes.
    private struct Definition {
        let term: String
        let definition: String
        let notebookID: UUID
        let sourceText: String
    }

    func generate(
        from documents: [QuizSourceDocument],
        format: QuizFormat,
        count: Int
    ) -> [GeneratedQuestion] {
        let definitions = extractDefinitions(from: documents)
        let entities = extractNamedEntities(from: documents)

        var questions: [GeneratedQuestion]
        switch format {
        case .multipleChoice:
            questions = generateMultipleChoice(definitions: definitions, entities: entities, count: count)
        case .flashcard:
            questions = generateFlashcards(definitions: definitions, count: count)
        case .shortAnswer:
            // Not supported on-device — caller falls back / surfaces the
            // "requires Apple Intelligence or MCP" affordance.
            questions = []
        case .mixed:
            // Split across the two formats Tier 1 can produce.
            let mcCount = Int((Double(count) * 0.6).rounded())
            let fcCount = count - mcCount
            questions = generateMultipleChoice(definitions: definitions, entities: entities, count: mcCount)
                + generateFlashcards(definitions: definitions, count: fcCount)
        }

        return Array(questions.shuffled().prefix(count))
    }

    // MARK: - Multiple choice

    private func generateMultipleChoice(
        definitions: [Definition],
        entities: [String],
        count: Int
    ) -> [GeneratedQuestion] {
        guard !definitions.isEmpty else { return [] }
        // Distractor pool: other terms + extracted entities.
        let termPool = Array(Set(definitions.map(\.term) + entities)).filter { !$0.isEmpty }

        var out: [GeneratedQuestion] = []
        for def in definitions {
            // Question asks for the term given its definition.
            let distractors = pickDistractors(for: def.term, from: termPool, n: 3)
            guard distractors.count == 3 else { continue }

            var options = ([def.term] + distractors).shuffled()
            guard let correctIndex = options.firstIndex(of: def.term) else { continue }
            // Cap option text so a runaway paragraph doesn't blow up the row.
            options = options.map { String($0.prefix(120)) }

            out.append(GeneratedQuestion(
                type: .multipleChoice,
                question: "Which term matches: \u{201C}\(clip(def.definition, 160))\u{201D}?",
                options: options,
                correctOptionIndex: correctIndex,
                sourceText: def.sourceText,
                sourceNotebookID: def.notebookID
            ))
            if out.count >= count { break }
        }
        return out
    }

    private func pickDistractors(for term: String, from pool: [String], n: Int) -> [String] {
        let candidates = pool.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        return Array(candidates.shuffled().prefix(n))
    }

    // MARK: - Flashcards

    private func generateFlashcards(definitions: [Definition], count: Int) -> [GeneratedQuestion] {
        definitions.prefix(count).map { def in
            GeneratedQuestion(
                type: .flashcard,
                question: def.term,
                frontText: def.term,
                backText: def.definition,
                sourceText: def.sourceText,
                sourceNotebookID: def.notebookID
            )
        }
    }

    // MARK: - Extraction

    /// Detects `X is Y`, `X: Y`, `X — Y`, and `X - Y` definition
    /// patterns line by line. **Strict** by design — Tier 1 has no
    /// language model to judge whether a pattern actually represents a
    /// concept, so anything questionable is rejected. The result: notes
    /// that aren't structured (conversational dictation, journal-style
    /// prose) produce **zero** definitions, and `generate(...)` then
    /// produces zero questions — better than nonsense like "Which term
    /// matches: 'I'm trying to record an audio'?"
    private func extractDefinitions(from documents: [QuizSourceDocument]) -> [Definition] {
        var defs: [Definition] = []
        for doc in documents {
            for block in doc.allText {
                for rawLine in block.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    guard line.count >= 12 else { continue }
                    guard let (term, definition) = splitDefinition(line) else { continue }
                    defs.append(Definition(
                        term: term,
                        definition: definition,
                        notebookID: doc.notebookID,
                        sourceText: line
                    ))
                }
            }
        }
        // Dedupe by term (case-insensitive, keep first).
        var seen = Set<String>()
        return defs.filter { seen.insert($0.term.lowercased()).inserted }
    }

    /// Try the separators in order and validate. Returns nil for
    /// anything that doesn't look like a real concept→definition pair.
    private func splitDefinition(_ line: String) -> (String, String)? {
        // Earliest separator wins — picks up "X: Y" before "X is Y" if
        // a colon appears earlier in the line.
        var bestRange: Range<String.Index>?
        var bestSeparator: String?
        let separators = [": ", " — ", " – ", " - ", " is ", " are ", " means ", " refers to "]
        for sep in separators {
            if let r = line.range(of: sep) {
                if bestRange == nil || r.lowerBound < bestRange!.lowerBound {
                    bestRange = r
                    bestSeparator = sep
                }
            }
        }
        guard let range = bestRange, let sep = bestSeparator else { return nil }

        let lhs = String(line[line.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let rhs = String(line[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        return validate(term: lhs, definition: rhs, viaVerbSeparator: sep.hasPrefix(" "))
    }

    /// Strict gate on what counts as a real definition. The single most
    /// important guard is rejecting **conversational openings** — `I`,
    /// `we`, `this`, `there`, `let's`, `hi`, etc. — which is how
    /// dictation transcripts slip nonsense into the quiz.
    private func validate(
        term rawTerm: String,
        definition rawDefinition: String,
        viaVerbSeparator: Bool
    ) -> (String, String)? {
        let term = stripLeadingArticle(rawTerm)
        let definition = rawDefinition

        let termWords = term.split(separator: " ").map(String.init)
        guard !termWords.isEmpty else { return nil }
        // Length envelope: a real term is short.
        guard (1...5).contains(termWords.count),
              term.count >= 2, term.count <= 60
        else { return nil }
        // The first letter must be a capital (concept names are
        // capitalised; full sentences usually start with lowercase
        // verbs/conjunctions in the middle of speech).
        guard let firstChar = term.first, firstChar.isLetter, firstChar.isUppercase
        else { return nil }
        // Contractions almost always indicate prose, not a term.
        if term.contains("'") { return nil }
        // Reject conversational openings — this is what filters out
        // dictation fragments like "I'm trying to record an audio".
        if Self.conversationalStarters.contains(termWords[0].lowercased()) {
            return nil
        }
        // For " is "/" are "/" means " patterns specifically, also
        // reject single-word terms that are themselves a stop-word.
        if viaVerbSeparator, Self.stopWords.contains(term.lowercased()) {
            return nil
        }
        // Definition has to read like an explanation — at least three
        // words and a couple of letters per word on average.
        let defWords = definition.split(separator: " ")
        guard defWords.count >= 3, definition.count >= 12 else { return nil }
        return (term, definition)
    }

    private func stripLeadingArticle(_ s: String) -> String {
        for article in ["The ", "An ", "A "] {
            if s.hasPrefix(article) {
                return String(s.dropFirst(article.count))
            }
        }
        return s
    }

    /// First-words that almost never start a real term/definition.
    /// Anything starting with these is rejected outright.
    private static let conversationalStarters: Set<String> = [
        // Pronouns + contractions
        "i", "i'm", "i've", "i'll", "i'd", "im",
        "you", "you're", "you've", "you'll", "you'd",
        "he", "he's", "he'd", "she", "she's", "she'd",
        "it", "it's", "it'd",
        "we", "we're", "we've", "we'll", "we'd",
        "they", "they're", "they've", "they'll", "they'd",
        // Demonstratives / locatives
        "this", "that", "these", "those", "there", "their",
        // Question words (questions aren't definitions)
        "what", "where", "when", "why", "how", "who", "which",
        // Conversational fillers
        "hi", "hello", "hey", "ok", "okay", "yeah", "yes", "no",
        "ah", "uh", "um", "oh",
        // Conjunctions / discourse markers commonly leading prose
        "so", "and", "but", "or", "if", "then", "well", "now",
        "actually", "basically", "literally", "honestly",
        "let", "let's", "lets",
    ]

    /// Single-word "terms" too generic to quiz on when paired with
    /// `X is Y`-style separators. Specific to the verb path because
    /// punctuation separators (`X: Y`) usually appear in deliberately
    /// structured notes where these words are unlikely.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been",
        "thing", "stuff", "something", "anything",
    ]

    /// Named entities (people, places, organisations) — used as
    /// multiple-choice distractors.
    private func extractNamedEntities(from documents: [QuizSourceDocument]) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        var entities: Set<String> = []
        let wanted: [NLTag] = [.personalName, .placeName, .organizationName]

        for doc in documents {
            for text in doc.allText where !text.isEmpty {
                tagger.string = text
                tagger.enumerateTags(
                    in: text.startIndex..<text.endIndex,
                    unit: .word,
                    scheme: .nameType,
                    options: [.omitWhitespace, .omitPunctuation]
                ) { tag, range in
                    if let tag, wanted.contains(tag) {
                        let token = String(text[range]).trimmingCharacters(in: .whitespaces)
                        if token.count >= 2 { entities.insert(token) }
                    }
                    return true
                }
            }
        }
        return Array(entities)
    }

    private func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}
