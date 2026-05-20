import Foundation
import SwiftUI

/// User-invoked AI capabilities — Summarize this page in v1, with
/// Ask / Suggest / etc. following in subsequent phases. This service
/// is deliberately separate from `IntelligenceService`:
///
///   • `IntelligenceService` powers *background* features
///     (auto-summarise notebooks, auto-suggest titles + tags) that
///     run without explicit user invocation. It pre-dates this
///     abstraction and calls `LanguageModelSession` directly.
///
///   • `AIService` powers *user-invoked* features (tap-to-summarize)
///     and dispatches through a swappable `AIProvider`. The
///     abstraction prepares the call sites for cloud providers
///     (architecture §11, Step 11) without forcing the existing
///     background features through the same refactor.
///
/// Both services gate on the same user toggle (`intelligence.enabled`,
/// stored in UserDefaults via `@AppStorage`) so users have one
/// consistent on/off switch.
@MainActor
final class AIService {

    static let shared = AIService()

    /// The current provider. Default is `AppleFoundationProvider` —
    /// on-device, free, private. `setProvider(_:)` swaps the
    /// backend at runtime when (eventually) a cloud provider is
    /// added behind a separate settings toggle.
    private(set) var provider: AIProvider

    /// Master toggle — shared with `IntelligenceService`. When this
    /// is false, every `AIService` call short-circuits to
    /// `AIError.unavailable` so the UI can prompt the user to
    /// enable AI in Settings.
    ///
    /// Read directly from UserDefaults rather than via `@AppStorage`
    /// because `@AppStorage` on a non-@Observable class doesn't
    /// publish changes; we don't need observation here — we read
    /// at request time.
    private var userOptIn: Bool {
        UserDefaults.standard.object(forKey: "intelligence.enabled") as? Bool ?? true
    }

    /// Conservative upper bound on prompt characters before the
    /// on-device session refuses. The exact context window isn't
    /// surfaced by the framework; this is sized so a typical page
    /// (5–10 typed notes + dictation + stickies) fits comfortably
    /// and only very long pages trip the `tooLong` short-circuit.
    /// Chunking + map-reduce summarisation is a follow-up.
    private let maxPromptCharacters = 12_000

    init(provider: AIProvider? = nil) {
        // Resolve the default in the (`@MainActor`) body rather than
        // as a default argument — default-argument expressions are
        // evaluated in a nonisolated context, which trips a Swift 6
        // warning on `AppleFoundationProvider()`.
        self.provider = provider ?? AppleFoundationProvider()
    }

    /// Replace the active provider. Reserved for the eventual
    /// cloud-provider Settings toggle. Not wired in v1.
    func setProvider(_ provider: AIProvider) {
        self.provider = provider
    }

    /// `true` when both the provider and the user toggle agree —
    /// the editor's Summarize button consults this to gate visibility
    /// (button hidden / disabled rather than tappable-then-erroring).
    var canRun: Bool {
        provider.isAvailable && userOptIn
    }

    // MARK: - Summarize page

    /// Run the Summarize-this-page capability against `context`.
    /// Throws `AIError` on every failure path so the UI can show
    /// the specific message it wants.
    func summarizePage(_ context: PageContext) async throws -> String {
        guard canRun else { throw AIError.unavailable }
        guard !context.isEmpty else { throw AIError.empty }

        let userPrompt = context.toPrompt()
        guard userPrompt.count <= maxPromptCharacters else {
            throw AIError.tooLong
        }

        return try await provider.complete(
            systemPrompt: Self.summarizeSystemPrompt,
            userPrompt: userPrompt,
            maxTokens: 256,
            temperature: 0.3
        )
    }

    /// System prompt for Summarize. Phrased to keep the response
    /// short, factual, and grounded in the page content — the
    /// model occasionally adds "these notes describe…" framing
    /// without this guardrail, which reads as filler in the result
    /// sheet.
    private static let summarizeSystemPrompt = """
    You are a helpful assistant summarising handwritten notes from a notebook page. \
    Read the page contents below and produce a brief summary in 2–4 sentences \
    capturing the key points. Use a neutral, factual tone. Do not add opinions or \
    commentary. Do not begin with phrases like "these notes cover" — just state \
    what they contain. If the page is mostly empty or contains only fragments, \
    say so honestly.
    """
}
