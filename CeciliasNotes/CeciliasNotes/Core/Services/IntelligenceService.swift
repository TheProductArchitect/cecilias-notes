import Combine
import Foundation
import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device AI surface, backed by Apple's Foundation Models
/// framework. **All inference runs locally** — there are no network
/// calls in this file, no cloud SDKs, no telemetry. The framework
/// itself runs Apple Intelligence on-device hardware (M-series iPad,
/// A17 Pro+ iPhone).
///
/// Compile-time gated via `#if canImport(FoundationModels)` so the
/// app builds cleanly on simulators or older SDKs without the
/// framework. When the framework is absent or Apple Intelligence is
/// disabled, `isAvailable` returns `false` and every generation
/// method returns `nil` — *every* AI surface in the app must
/// short-circuit to complete UI absence (no disabled states, no
/// placeholders) when `isAvailable && intelligenceEnabled` is false.
///
/// Threading model:
///   • `@MainActor` so SwiftUI views can observe `isAvailable` /
///     `intelligenceEnabled` without bridging.
///   • Each generation method awaits the model on the actor and
///     hops to a detached Task internally if needed. Callers
///     `await intelligenceService.summarise(...)` from any context.
@MainActor
final class IntelligenceService {

    static let shared = IntelligenceService()

    /// Explicit publisher for `@ObservedObject` in Settings / Library (iOS).
    let objectWillChange = ObservableObjectPublisher()

    // MARK: Availability + master gate

    /// `true` when Foundation Models is linkable AND
    /// `SystemLanguageModel.default.availability == .available` on
    /// the running device. UI surfaces should always check this
    /// before showing any AI affordance.
    ///
    /// Two-layer guard:
    ///   • `#if canImport(FoundationModels)` — the framework
    ///     itself may be absent on simulators or older SDKs.
    ///   • `if #available(iOS 26.0, macOS 26.0, *)` — even when the framework
    ///     is present in the SDK, the public Foundation Models
    ///     types are marked iOS 26+ on the current toolchain. At
    ///     this app's iOS 18.4 deployment target the runtime check
    ///     will be false on every device until deployment is bumped
    ///     (or until Apple back-deploys the symbols). Result: AI
    ///     remains gracefully absent — no UI, no crashes — and the
    ///     architecture is in place to light up the day the
    ///     deployment moves up.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
        #else
        return false
        #endif
    }

    /// Master user toggle, stored in UserDefaults under
    /// `intelligence.enabled`. Default ON when the framework is
    /// available; the user can opt out via Settings → Intelligence.
    @AppStorage("intelligence.enabled") var intelligenceEnabled: Bool = true

    /// Convenience: both the framework and the user toggle agree.
    /// Every AI feature site checks this and returns early when false.
    var canRun: Bool { isAvailable && intelligenceEnabled }

    private init() {}

    // MARK: - Scheduling (per-notebook debounce)

    /// Pending summary jobs keyed by notebook id. A fresh
    /// `scheduleSummary` call cancels the previous task for the
    /// same notebook so a burst of stroke saves coalesces into one
    /// model invocation 10s after the last edit.
    private var pendingSummaryTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingTitleTasks:   [UUID: Task<Void, Never>] = [:]
    private var pendingTagTasks:     [UUID: Task<Void, Never>] = [:]

    /// Lecture-summary generation in-flight set. The set is
    /// process-local — populated by `generateLectureSummary`
    /// on entry, cleared on completion or early-return. The
    /// editor's `LectureBlockView` reads this to decide whether
    /// to show "summarising…" or to leave the summary section
    /// absent (the latter for pre-Pass-B records and for any
    /// record whose generation never ran in the current session).
    /// Published so SwiftUI views observe re-renders directly.
    @Published private(set) var pendingLectureSummaryIds: Set<UUID> = []

    // MARK: Personalisation

    /// User's first-name possessive read from the App Group suite —
    /// the same key the widget reads. AI prompts that surface user-
    /// facing copy should personalise with this when available.
    var userDisplayName: String {
        UserDefaults(suiteName: "group.app.ceciliasnotes")?
            .string(forKey: "user.displayName") ?? ""
    }

    // MARK: - Summaries (Phase 1)

    /// Public hook called from the editor's save pipeline. Debounces
    /// to 10 s of quiet, then re-summarises and stores via
    /// `IntelligenceCache`. No-op when AI is off so callers don't
    /// need to gate.
    func scheduleSummary(notebookId: UUID) {
        guard canRun else { return }
        pendingSummaryTasks[notebookId]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            await self.regenerateSummary(notebookId: notebookId)
            self.pendingSummaryTasks[notebookId] = nil
        }
        pendingSummaryTasks[notebookId] = task
    }

    private func regenerateSummary(notebookId: UUID) async {
        let text = SearchIndexService.shared.combinedText(for: notebookId)
        guard let summary = await summarise(text: text) else { return }
        IntelligenceCache.setSummary(summary, for: notebookId)
        // Bump observers — NotebookCard reads from the cache, but the
        // grid won't know to re-fetch otherwise. Defer to next
        // runloop to avoid AttributeGraph cycles when the summary
        // completes synchronously after a UI-triggered request.
        Task { @MainActor in self.objectWillChange.send() }
    }

    /// 1–2 sentence summary of a notebook's combined content.
    /// Returns `nil` when AI is unavailable, the notebook has too
    /// little text (<50 words), or generation fails. Caching lives
    /// in `IntelligenceCache.summary(...)` keyed by notebook id +
    /// the notebook's `updatedAt` so stale summaries auto-invalidate.
    func summarise(text: String) async -> String? {
        guard canRun else { return nil }
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= 50 else { return nil }

        let prompt = """
        Summarise these notes in 1–2 sentences. Be direct. Do not say \
        "these notes cover" — just state what they contain.

        \(text)
        """
        return await respond(to: prompt)
    }

    // MARK: - Suggested titles (Phase 2)

    /// 2–5 word title proposal for a notebook whose current title is
    /// empty or a stock "Untitled" placeholder. Returns `nil` when
    /// AI is off, the notebook is too thin to title meaningfully,
    /// or generation fails.
    func suggestTitle(from text: String) async -> String? {
        guard canRun else { return nil }
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= 20 else { return nil }

        let prompt = """
        Suggest a 2–5 word title for these notes. Return ONLY the \
        title, no quotation marks, no trailing period, lowercase.

        \(text)
        """
        guard let raw = await respond(to: prompt) else { return nil }
        // Strip quotes, trailing punctuation, lowercase, cap length.
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,;:!?"))
            .lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return nil }
        return trimmed
    }

    // MARK: - Suggested tags (Phase 3)

    /// Up to 3 tag suggestions for an untagged notebook. Strings
    /// returned are pre-normalised (lowercase, trimmed, no
    /// punctuation) but the caller is still expected to run them
    /// through `TagValidator` before applying — defence in depth
    /// against a model that occasionally returns emoji or numbers.
    func suggestTags(from text: String) async -> [String] {
        guard canRun else { return [] }
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= 50 else { return [] }

        let prompt = """
        Given these notes, suggest 1–3 short tags (single words or \
        short phrases, lowercase, no punctuation). Return only the \
        tags as a comma-separated list, nothing else.

        \(text)
        """
        guard let raw = await respond(to: prompt) else { return [] }
        let candidates = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
            .prefix(3)
        return Array(candidates)
    }

    // MARK: - Transcript structure (Phase 6 — headings + subheadings)

    /// Post-processes a raw dictation transcript and returns a
    /// markdown-formatted version with detected headings and
    /// subheadings. Returns `nil` when AI is unavailable, the
    /// transcript is too short to structure meaningfully, or
    /// generation fails.
    ///
    /// Output format: GitHub-flavoured markdown with `#` and `##`
    /// headings. Each paragraph between headings is one block. The
    /// model is instructed to preserve the speaker's exact wording
    /// in body content — only the structural overlay (where headings
    /// sit, what gets promoted to a heading) is generated.
    ///
    /// Designed for transcripts of a single speaker dictating
    /// structured material (lectures, notes, meeting recaps). For
    /// multi-speaker recordings the heading detection will collapse
    /// turn changes into structural breaks — diarisation is a
    /// separate problem (no on-device iOS solution today).
    func structureTranscript(_ transcript: String) async -> String? {
        guard canRun else { return nil }
        let words = transcript.split(whereSeparator: { $0.isWhitespace }).count
        // Under ~80 words a single paragraph is the right answer —
        // no headings to introduce.
        guard words >= 80 else { return nil }

        let prompt = """
        You are post-processing a spoken-word transcript into \
        structured markdown notes. Identify the natural topic and \
        subtopic boundaries and add headings.

        Rules:
        - Use # for top-level headings (major topics) and ## for \
          subheadings (sub-topics within a major topic).
        - Body text under each heading must be the speaker's actual \
          words. You may merge sentence fragments and remove filler \
          words ("um", "uh", "you know") but do not paraphrase, \
          summarise, or add new information.
        - Do not invent content that isn't in the transcript.
        - Aim for 1–4 top-level headings depending on transcript \
          length. Use subheadings sparingly — only where the \
          speaker clearly shifts to a sub-topic.
        - Return ONLY the markdown. No preamble, no explanation, no \
          closing remarks.

        Transcript:
        \(transcript)
        """
        return await respond(to: prompt)
    }

    // MARK: - Lecture summary (Pass B)

    // Step 5: `generateLectureSummary(for: LectureRecord)` removed
    // alongside the V5 `LectureRecord` + `summary` / `summaryBullets`
    // fields. AudioContent in V6 carries only `transcript`. AI
    // summary surfaces re-land in Step 11 against the unified
    // `AIProvider` protocol (architecture §11 / §14.5).

    #if canImport(FoundationModels)
    /// One-shot lecture summary via Foundation Models. Returns `nil`
    /// for transcripts shorter than ~50 words (too thin to
    /// summarise) and for any response the parser can't shape back
    /// into the `SUMMARY:` / `BULLETS:` envelope. The `@available`
    /// guard is the second of the two-layer gate documented on
    /// `isAvailable` — `canImport` keeps the symbol out of the
    /// binary on older SDKs, `if #available` keeps the runtime
    /// branch out of the call path on iOS 18.
    @available(iOS 26.0, *)
    func summariseLecture(transcript: String) async -> (paragraph: String, bullets: [String])? {
        guard canRun else { return nil }
        let wordCount = transcript.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= 50 else { return nil }

        // The prompt asks for a fixed envelope so the parser below
        // can split deterministically. The model occasionally
        // returns the answer with no marker text or with extra
        // padding; both fall through the parse and return nil.
        let prompt = """
        You are summarising a recorded lecture or meeting. Write a \
        2–3 sentence summary paragraph, then list 5–8 key topics as \
        short bullet phrases. Format your response exactly as: \
        SUMMARY: [paragraph] BULLETS: [bullet1] | [bullet2] | ... \
        Return nothing else.

        \(transcript)
        """
        guard let raw = await respond(to: prompt) else { return nil }
        return Self.parseLectureSummary(raw)
    }

    /// Best-effort parse of the model's `SUMMARY: … BULLETS: …`
    /// response. Returns `nil` for any shape we can't recognise so
    /// the caller never has to surface a parse error.
    static func parseLectureSummary(_ raw: String) -> (paragraph: String, bullets: [String])? {
        let upper = raw as NSString
        let summaryRange = upper.range(of: "SUMMARY:", options: .caseInsensitive)
        let bulletsRange = upper.range(of: "BULLETS:", options: .caseInsensitive)
        guard summaryRange.location != NSNotFound,
              bulletsRange.location != NSNotFound,
              bulletsRange.location > summaryRange.location + summaryRange.length
        else { return nil }

        let paragraphStart = summaryRange.location + summaryRange.length
        let paragraphLength = bulletsRange.location - paragraphStart
        let paragraph = upper.substring(with: NSRange(location: paragraphStart, length: paragraphLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let bulletsTail = upper.substring(from: bulletsRange.location + bulletsRange.length)
        let bullets = bulletsTail
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paragraph.isEmpty, !bullets.isEmpty else { return nil }
        return (paragraph, bullets)
    }
    #endif

    // MARK: - Embeddings (Phase 4)

    /// Embedding vector for a piece of text, used by semantic
    /// search to score notebook similarity to a query.
    ///
    /// FIXME — verify against FoundationModels iOS 18.4 embedding
    /// API. The framework exposes a `LanguageModelSession.respond`
    /// path that's verified; the embedding-generation path I'm
    /// reaching for here is a best-effort match against the
    /// pattern of `Embedder()` / `embed(_:)` that's typical in
    /// Apple ML frameworks. On a real device this call may need
    /// to be retargeted to `SystemLanguageModel.default.embed(...)`
    /// or a separate `Embedder` type — replace the marked block
    /// once the right API is confirmed.
    func embed(text: String) async -> [Float]? {
        guard canRun, !text.isEmpty else { return nil }
        #if canImport(FoundationModels)
        // FIXME: replace with the verified embedding entry point.
        // Stub that returns nil so the rest of the semantic-search
        // pipeline degrades gracefully (falls back to keyword-only
        // results) until the real API is wired.
        return nil
        #else
        return nil
        #endif
    }

    // MARK: - Ask My Notes (Phase 5)

    /// One-shot conversational answer over a retrieved context.
    /// Non-streaming variant — used by the Ask sheet when the user
    /// is on a path that doesn't want progressive rendering.
    func askMyNotes(question: String, context: String, scopeTitle: String? = nil) async -> String? {
        guard canRun else { return nil }
        return await respond(
            to: askMyNotesPrompt(question: question, context: context, scopeTitle: scopeTitle)
        )
    }

    /// Streaming variant — yields successive partial strings as the
    /// model generates. The Ask sheet binds directly to this so the
    /// answer surfaces character-by-character as soon as the model
    /// starts producing output. Returns an empty stream when AI is
    /// off so callers don't have to guard separately.
    ///
    /// `scopeTitle` is the notebook the user narrowed the query to,
    /// or `nil` for an unscoped (search-everywhere) submit. When set,
    /// the system prompt instructs the model to answer using only
    /// notes from that notebook — keeps cross-notebook leakage out of
    /// scoped responses.
    func askMyNotesStream(
        question: String,
        context: String,
        scopeTitle: String? = nil,
        priorConversation: String? = nil
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            guard canRun else { continuation.finish(); return }
            let prompt = askMyNotesPrompt(
                question: question,
                context: context,
                scopeTitle: scopeTitle,
                priorConversation: priorConversation
            )
            Task {
                #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *) {
                    let session = LanguageModelSession()
                    do {
                        let stream = session.streamResponse(to: prompt)
                        for try await partial in stream {
                            continuation.yield(partial.content)
                        }
                        continuation.finish()
                    } catch {
                        // Silent failure per spec — never surface AI
                        // errors. Finishing the stream lets the UI
                        // fall back to its "couldn't find anything"
                        // state.
                        continuation.finish()
                    }
                } else {
                    continuation.finish()
                }
                #else
                continuation.finish()
                #endif
            }
        }
    }

    private func askMyNotesPrompt(
        question: String,
        context: String,
        scopeTitle: String?,
        priorConversation: String? = nil
    ) -> String {
        // The partial-match instruction is deliberate: the retrieval
        // path now stems the question and runs broader index queries,
        // which can surface pages that are *related* to the question
        // but don't contain a verbatim answer. Telling the model to
        // use those partial matches (and flag them as such) makes the
        // Ask feature feel less brittle to phrasing differences.
        //
        // Scope line — when present, narrows the model's domain to a
        // single notebook so it doesn't reach across into unrelated
        // notes that happened to slip through the retrieval filter.
        let scopeLine: String = {
            guard let scopeTitle, !scopeTitle.isEmpty else { return "" }
            return "Search scoped to: \(scopeTitle). Answer based only on notes in this notebook.\n\n"
        }()
        let priorLine: String = {
            guard let priorConversation, !priorConversation.isEmpty else { return "" }
            return "Prior conversation in this session:\n\(priorConversation)\n\n"
        }()
        return """
        \(scopeLine)\(priorLine)You are answering a question based only on the user's personal \
        notes. Answer based on the notes below. If the notes contain \
        information that is related to the question but not an exact \
        match, use it anyway and note that it may be relevant. If \
        nothing is relevant, say so plainly.

        Answer concisely. After your answer, list the sources as: \
        [Notebook Title, Page N].

        Question: \(question)

        \(context)
        """
    }

    // MARK: - Generation helper

    /// Single point of model invocation for non-streaming methods.
    /// Catches and swallows errors so AI features never propagate
    /// failures into the UI — `nil` is the only failure signal.
    private func respond(to prompt: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                let text = response.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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

#if os(iOS)
extension IntelligenceService: ObservableObject {}
#endif
