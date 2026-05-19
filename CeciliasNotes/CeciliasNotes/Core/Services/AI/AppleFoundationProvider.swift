import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// `AIProvider` backed by Apple's on-device Foundation Models
/// framework. Mirrors the gating shape of `IntelligenceService`:
///
///   • `#if canImport(FoundationModels)` keeps the framework symbols
///     out of the binary on simulators / older SDKs.
///   • `if #available(iOS 26.0, *)` keeps the runtime branch
///     unreachable on iOS 18 devices until the deployment target
///     is bumped.
///
/// `isAvailable` reflects both gates plus the system model's own
/// availability signal — the AI Service consults this before
/// dispatching, so unsupported devices never invoke the provider
/// at all (`AIError.unavailable` surfaces upstream instead of a
/// silent stub return).
///
/// The provider is `Sendable` so multiple call sites can hold a
/// shared reference. `LanguageModelSession` is constructed per
/// request rather than once per provider — sessions are cheap and
/// per-request sessions sidestep any internal state retention that
/// might prejudice a second prompt.
final class AppleFoundationProvider: AIProvider {

    let name = "AppleFoundation"
    let isOnDevice = true

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
        #else
        return false
        #endif
    }

    init() {}

    func complete(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) async throws -> String {
        let prompt = Self.composePrompt(system: systemPrompt, user: userPrompt)

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available else {
                throw AIError.unavailable
            }
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                let trimmed = response.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { throw AIError.modelFailure }
                return trimmed
            } catch let error as AIError {
                throw error
            } catch {
                throw AIError.modelFailure
            }
        }
        throw AIError.unavailable
        #else
        throw AIError.unavailable
        #endif
    }

    func stream(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = Self.composePrompt(system: systemPrompt, user: userPrompt)

        return AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                guard SystemLanguageModel.default.availability == .available else {
                    continuation.finish(throwing: AIError.unavailable)
                    return
                }
                Task {
                    do {
                        let session = LanguageModelSession()
                        let stream = session.streamResponse(to: prompt)
                        for try await partial in stream {
                            continuation.yield(partial.content)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: AIError.modelFailure)
                    }
                }
            } else {
                continuation.finish(throwing: AIError.unavailable)
            }
            #else
            continuation.finish(throwing: AIError.unavailable)
            #endif
        }
    }

    /// Foundation Models takes a single string. We join the system
    /// guidance + user content with a blank line — the model parses
    /// the two-part shape implicitly. Future cloud providers
    /// (Anthropic, OpenAI) take the parts as distinct message roles
    /// and will tear this back apart.
    private static func composePrompt(system: String, user: String) -> String {
        let trimmedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSystem.isEmpty { return user }
        return "\(trimmedSystem)\n\n\(user)"
    }
}
