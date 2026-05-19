import Foundation

/// Swappable backend for user-invoked AI capabilities. The protocol
/// formalises the model surface that the user-facing `AIService`
/// dispatches to — keeping the call sites (Summarize page, future
/// Ask, Suggest, etc.) decoupled from a concrete model.
///
/// Existing background AI features (`IntelligenceService.suggestTitle`,
/// `summarise(text:)`, `suggestTags`, `askMyNotesStream`) continue to
/// call into `LanguageModelSession` directly. That code predates this
/// abstraction; pulling it through here is a refactor for Step 11
/// (cloud providers), not part of this commit.
///
/// **Failure model.** `complete` throws so the caller can distinguish
/// "model unavailable / system off" (`AIError.unavailable`) from
/// "request invalid" (`AIError.empty` / `.tooLong`) from "model
/// produced no usable output" (`AIError.modelFailure`). Streaming is
/// optional — the v1 (Apple Foundation Models) wiring supports it
/// for the future Ask feature but Summarize doesn't use it.
protocol AIProvider: Sendable {

    /// Provider identifier — surfaced in logs and (eventually) in
    /// the per-feature provenance stamp on AI-generated content.
    var name: String { get }

    /// `true` when the provider runs locally on the device — no
    /// network call needed. The Settings UI surfaces this so users
    /// understand the privacy posture without reading docs.
    var isOnDevice: Bool { get }

    /// `true` when the provider can be invoked right now (framework
    /// linkable, system model ready, user opt-in honoured). Callers
    /// should check this before invoking to give a clean "AI is off"
    /// message rather than catching `AIError.unavailable` after the
    /// fact.
    var isAvailable: Bool { get }

    /// One-shot text completion. `temperature` is advisory — providers
    /// without a temperature knob ignore it. `maxTokens` is best-
    /// effort; the on-device Foundation Models session enforces its
    /// own internal cap and may return fewer tokens.
    func complete(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) async throws -> String

    /// Streaming completion — yields successive partial strings as
    /// the model produces them. Each yielded string is the cumulative
    /// content so far (matching the Foundation Models
    /// `LanguageModelSession.streamResponse(...)` semantics). Throws
    /// `AIError.unsupportedOperation` for providers that don't
    /// stream; callers can fall back to `complete`.
    func stream(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) -> AsyncThrowingStream<String, Error>
}

/// Failure cases surfaced to AI feature call sites. `AIService`
/// translates these into user-visible copy ("Enable AI features in
/// Settings", "Page is too long to summarize", etc.) so the
/// per-feature UI doesn't have to know about provider internals.
enum AIError: Error, Equatable {
    /// Provider is not available — framework missing, system model
    /// not ready, or user has turned AI off in Settings. The UI
    /// surfaces this as an "Enable AI features" prompt.
    case unavailable

    /// Input prompt is empty after trimming (the caller didn't have
    /// content to send). Distinguished from `modelFailure` so the UI
    /// can show "No content to summarize" rather than a generic
    /// error.
    case empty

    /// Input prompt exceeds the provider's context window. For the
    /// on-device provider this is a coarse character cap — chunking /
    /// streaming summary is a future capability.
    case tooLong

    /// Provider invoked the model but the model returned empty or
    /// produced no usable response. Generic catch-all for
    /// "something went wrong inside the model" — the UI shows a
    /// retry prompt.
    case modelFailure

    /// Optional capability the provider doesn't support (e.g.
    /// streaming on a provider that's complete-only). Callers can
    /// fall back to a different code path.
    case unsupportedOperation
}
