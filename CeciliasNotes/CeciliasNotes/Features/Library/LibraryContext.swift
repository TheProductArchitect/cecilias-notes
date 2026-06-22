import Foundation

/// Which subset of notebooks the home grid is currently rendering.
///
/// Drives both the grid's contents and the sidebar's active-row
/// indicator. Persisted across launches via `UserDefaults` under
/// `library.lastSelectedContext` so a user who picked a subject
/// returns to it on relaunch; first-ever launch defaults to `.recent`.
///
/// `@AppStorage` doesn't natively support enums with associated
/// values, so the value round-trips through a small raw-string form
/// (`"recent"`, `"all"`, `"subject:<UUID>"`).
enum LibraryContext: Equatable, Hashable {
    case recent
    case allNotes
    case subject(UUID)
    /// Top-level file-system style listing of every Subject, with
    /// multi-select for batch delete / merge. The grid swaps to
    /// `AllSubjectsView` when this is active.
    case allSubjects
    /// Top-level file-system style listing of every Quiz, with
    /// multi-select for batch delete / move-to-folder. The grid
    /// swaps to `AllQuizzesView` when this is active.
    case allQuizzes

    // MARK: Persistence round-trip

    var rawString: String {
        switch self {
        case .recent:           return "recent"
        case .allNotes:         return "all"
        case .subject(let id):  return "subject:\(id.uuidString)"
        case .allSubjects:      return "allSubjects"
        case .allQuizzes:       return "allQuizzes"
        }
    }

    init?(rawString: String) {
        switch rawString {
        case "recent":      self = .recent
        case "all":         self = .allNotes
        case "allSubjects": self = .allSubjects
        case "allQuizzes":  self = .allQuizzes
        default:
            let prefix = "subject:"
            guard rawString.hasPrefix(prefix),
                  let id = UUID(uuidString: String(rawString.dropFirst(prefix.count)))
            else { return nil }
            self = .subject(id)
        }
    }

    // MARK: Helpers

    /// The subject id when in subject context; `nil` otherwise.
    var subjectId: UUID? {
        if case .subject(let id) = self { return id }
        return nil
    }
}
