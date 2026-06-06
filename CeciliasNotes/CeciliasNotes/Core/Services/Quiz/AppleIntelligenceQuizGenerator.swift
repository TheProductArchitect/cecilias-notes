import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tier 2 — Apple Intelligence via the on-device foundation model
/// (`FoundationModels`). Everything Tier 1 can do, plus short-answer
/// generation and marking, with more natural phrasing. Same two-layer
/// availability gate as `IntelligenceService` (`canImport` keeps the
/// symbols out of older-SDK builds; `#available(iOS 26)` keeps the
/// runtime branch off the path until the deployment target supports
/// it). Every method degrades to an empty/neutral result on failure —
/// the caller falls back to Tier 1 silently.
struct AppleIntelligenceQuizGenerator {

    /// True when the foundation model is usable right now.
    var isAvailable: Bool { IntelligenceService.shared.canRun }

    // MARK: - Generation

    func generate(
        from documents: [QuizSourceDocument],
        format: QuizFormat,
        count: Int
    ) async -> [GeneratedQuestion] {
        let corpus = corpusText(from: documents)
        guard corpus.split(whereSeparator: { $0.isWhitespace }).count >= 20 else { return [] }
        let notebookID = documents.first?.notebookID

        switch format {
        case .multipleChoice:
            return await generateMultipleChoice(corpus: corpus, count: count, notebookID: notebookID)
        case .flashcard:
            return await generateFlashcards(corpus: corpus, count: count, notebookID: notebookID)
        case .shortAnswer:
            return await generateShortAnswer(corpus: corpus, count: count, notebookID: notebookID)
        case .mixed:
            let mc = Int((Double(count) * 0.4).rounded())
            let fc = Int((Double(count) * 0.3).rounded())
            let sa = count - mc - fc
            async let a = generateMultipleChoice(corpus: corpus, count: mc, notebookID: notebookID)
            async let b = generateFlashcards(corpus: corpus, count: fc, notebookID: notebookID)
            async let c = generateShortAnswer(corpus: corpus, count: sa, notebookID: notebookID)
            return await (a + b + c)
        }
    }

    // MARK: - Per-format prompts + parsing

    private func generateMultipleChoice(corpus: String, count: Int, notebookID: UUID?) async -> [GeneratedQuestion] {
        guard count > 0 else { return [] }
        let prompt = """
        Generate \(count) multiple-choice questions from the notes below. \
        Each question has exactly four options and one correct answer. \
        Base every question only on the notes — do not invent facts. \
        Format each question EXACTLY as, separated by a line with only "---":
        Q: <question>
        A: <option>
        B: <option>
        C: <option>
        D: <option>
        CORRECT: <A|B|C|D>
        ---

        Notes:
        \(corpus)
        """
        guard let raw = await respond(to: prompt) else { return [] }
        return parseMultipleChoice(raw, notebookID: notebookID)
    }

    private func generateFlashcards(corpus: String, count: Int, notebookID: UUID?) async -> [GeneratedQuestion] {
        guard count > 0 else { return [] }
        let prompt = """
        Generate \(count) flashcards from the notes below. Front is a term \
        or concept, back is its definition or explanation. Base them only \
        on the notes. Format each EXACTLY as, separated by a line with only "---":
        FRONT: <term>
        BACK: <definition>
        ---

        Notes:
        \(corpus)
        """
        guard let raw = await respond(to: prompt) else { return [] }
        return parseFlashcards(raw, notebookID: notebookID)
    }

    private func generateShortAnswer(corpus: String, count: Int, notebookID: UUID?) async -> [GeneratedQuestion] {
        guard count > 0 else { return [] }
        let prompt = """
        Generate \(count) short-answer questions from the notes below. \
        For each, give a model answer and 2–4 key points the answer should \
        cover. Base them only on the notes. Format each EXACTLY as, \
        separated by a line with only "---":
        Q: <question>
        SAMPLE: <model answer>
        KEYPOINTS: <point 1> | <point 2> | <point 3>
        ---

        Notes:
        \(corpus)
        """
        guard let raw = await respond(to: prompt) else { return [] }
        return parseShortAnswer(raw, notebookID: notebookID)
    }

    // MARK: - Short-answer marking

    /// Mark a free-text answer. Returns a 0–1 score + one-sentence
    /// feedback, or nil on failure (caller falls back to self-assessment).
    func markShortAnswer(
        question: String,
        sampleAnswer: String,
        keyPoints: [String],
        userAnswer: String
    ) async -> (score: Double, feedback: String)? {
        guard !userAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (0, "No answer given.")
        }
        let points = keyPoints.isEmpty ? "(none provided)" : keyPoints.joined(separator: "; ")
        let prompt = """
        Mark the student's answer against the reference. Score 0 to 100 for \
        how well it covers the key points; be fair but not harsh. Give ONE \
        sentence of feedback. Respond EXACTLY as:
        SCORE: <0-100>
        FEEDBACK: <one sentence>

        Question: \(question)
        Reference answer: \(sampleAnswer)
        Key points: \(points)
        Student answer: \(userAnswer)
        """
        guard let raw = await respond(to: prompt) else { return nil }
        return parseMark(raw)
    }

    // MARK: - Parsing

    private func parseMultipleChoice(_ raw: String, notebookID: UUID?) -> [GeneratedQuestion] {
        blocks(raw).compactMap { block in
            let fields = lineFields(block)
            guard let q = fields["Q"], !q.isEmpty else { return nil }
            let letters = ["A", "B", "C", "D"]
            let options = letters.compactMap { fields[$0] }
            guard options.count == 4,
                  let correct = fields["CORRECT"]?.uppercased().first,
                  let idx = letters.firstIndex(of: String(correct))
            else { return nil }
            return GeneratedQuestion(
                type: .multipleChoice,
                question: q,
                options: options,
                correctOptionIndex: idx,
                sourceNotebookID: notebookID
            )
        }
    }

    private func parseFlashcards(_ raw: String, notebookID: UUID?) -> [GeneratedQuestion] {
        blocks(raw).compactMap { block in
            let fields = lineFields(block)
            guard let front = fields["FRONT"], let back = fields["BACK"],
                  !front.isEmpty, !back.isEmpty else { return nil }
            return GeneratedQuestion(
                type: .flashcard,
                question: front,
                frontText: front,
                backText: back,
                sourceNotebookID: notebookID
            )
        }
    }

    private func parseShortAnswer(_ raw: String, notebookID: UUID?) -> [GeneratedQuestion] {
        blocks(raw).compactMap { block in
            let fields = lineFields(block)
            guard let q = fields["Q"], !q.isEmpty else { return nil }
            let keyPoints = (fields["KEYPOINTS"] ?? "")
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return GeneratedQuestion(
                type: .shortAnswer,
                question: q,
                sampleAnswer: fields["SAMPLE"],
                keyPoints: keyPoints,
                sourceNotebookID: notebookID
            )
        }
    }

    private func parseMark(_ raw: String) -> (score: Double, feedback: String)? {
        let fields = lineFields(raw)
        guard let scoreStr = fields["SCORE"],
              let scoreVal = Double(scoreStr.filter { $0.isNumber || $0 == "." })
        else { return nil }
        let score = max(0, min(1, scoreVal / 100))
        let feedback = fields["FEEDBACK"] ?? ""
        return (score, feedback)
    }

    /// Split a model response into per-question blocks on `---` lines.
    private func blocks(_ raw: String) -> [String] {
        raw.components(separatedBy: "---")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Parse `KEY: value` lines in a block into a dictionary. Tolerant
    /// of leading bullet characters and extra whitespace.
    private func lineFields(_ block: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in block.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*"))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).uppercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty { fields[key] = value }
        }
        return fields
    }

    private func corpusText(from documents: [QuizSourceDocument]) -> String {
        documents.flatMap { doc in doc.allText }.joined(separator: "\n\n")
    }

    // MARK: - Model invocation

    private func respond(to prompt: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }
        return nil
        #else
        return nil
        #endif
    }
}
