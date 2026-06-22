import Foundation

/// Describes which notes a quiz is generated from. Stored on `Quiz`
/// as a JSON string column (`Quiz.sourceScopeRaw`) rather than as
/// SwiftData fields — it's a value type with a nested enum + arrays,
/// the same reason `Notebook.defaultTemplate` round-trips through a
/// JSON string (CloudKit-backed SwiftData can't store nested Codable
/// structs directly without a transformer).
///
/// **Sendable + manually conformed Codable** — under Swift 6 strict
/// concurrency this module hosts SwiftData `@Model` types, so any
/// *synthesised* `Codable` witness or memberwise init is inferred
/// `@MainActor`-isolated. `Quiz.sourceScope`'s nonisolated accessor
/// would then refuse to call `from(jsonString:)` / `jsonString` from
/// a nonisolated context. Writing the conformance and the init by
/// hand lets each member be explicitly `nonisolated`, so the JSON
/// round-trip stays callable from any isolation domain. See
/// `OPEN_ISSUES.md` §1 mechanism 1.
struct QuizScope: Equatable, Sendable {
    enum ScopeType: String, Codable, Sendable {
        case notebook    // one specific notebook
        case subject     // all notebooks in a subject
        case custom      // user-selected list of notebooks
    }

    var type: ScopeType
    /// Populated for `.notebook` (single id) and `.custom` (many).
    var notebookIDs: [UUID]
    /// Populated for `.subject`. The subject's UUID is the stable key;
    /// `subjectName` is denormalised for the label so a renamed/missing
    /// subject still shows something sensible.
    var subjectID: UUID?
    var subjectName: String?
    /// Whether audio transcription text is folded into the source.
    var includeTranscriptions: Bool

    nonisolated init(
        type: ScopeType,
        notebookIDs: [UUID] = [],
        subjectID: UUID? = nil,
        subjectName: String? = nil,
        includeTranscriptions: Bool = true
    ) {
        self.type = type
        self.notebookIDs = notebookIDs
        self.subjectID = subjectID
        self.subjectName = subjectName
        self.includeTranscriptions = includeTranscriptions
    }

    // MARK: JSON round-trip (mirrors PageTemplate.jsonString)

    nonisolated var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    nonisolated static func from(jsonString: String) -> QuizScope {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(QuizScope.self, from: data)
        else {
            // Sensible empty default — a custom scope with no notebooks.
            return QuizScope(type: .custom)
        }
        return decoded
    }
}

// MARK: - Manual Codable

extension QuizScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, notebookIDs, subjectID, subjectName, includeTranscriptions
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(ScopeType.self, forKey: .type)
        self.notebookIDs = try c.decodeIfPresent([UUID].self, forKey: .notebookIDs) ?? []
        self.subjectID = try c.decodeIfPresent(UUID.self, forKey: .subjectID)
        self.subjectName = try c.decodeIfPresent(String.self, forKey: .subjectName)
        self.includeTranscriptions =
            try c.decodeIfPresent(Bool.self, forKey: .includeTranscriptions) ?? true
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(notebookIDs, forKey: .notebookIDs)
        try c.encodeIfPresent(subjectID, forKey: .subjectID)
        try c.encodeIfPresent(subjectName, forKey: .subjectName)
        try c.encode(includeTranscriptions, forKey: .includeTranscriptions)
    }
}
