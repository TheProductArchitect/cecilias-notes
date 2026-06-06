import Foundation

/// Describes which notes a quiz is generated from. Stored on `Quiz`
/// as a JSON string column (`Quiz.sourceScopeRaw`) rather than as
/// SwiftData fields — it's a value type with a nested enum + arrays,
/// the same reason `Notebook.defaultTemplate` round-trips through a
/// JSON string (CloudKit-backed SwiftData can't store nested Codable
/// structs directly without a transformer).
struct QuizScope: Codable, Equatable {
    enum ScopeType: String, Codable {
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

    init(
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

    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func from(jsonString: String) -> QuizScope {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(QuizScope.self, from: data)
        else {
            // Sensible empty default — a custom scope with no notebooks.
            return QuizScope(type: .custom)
        }
        return decoded
    }
}
