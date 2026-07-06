import AppIntents
import Foundation

// MARK: - Intent routing symbols (Core — visible to Mac + iOS)

enum CeciliasNotesIntentKeys {
    static let notebookId = "notebookId"
    static let askQuery   = "askQuery"
}

extension Notification.Name {
    static let ceciliasNotesOpenNotebook = Notification.Name("ceciliasnotes.command.openNotebook")
    static let ceciliasNotesOpenAsk      = Notification.Name("ceciliasnotes.command.openAsk")
}

// MARK: - Notebook entity (Shortcuts picker)

struct NotebookEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Notebook")
    }
    static var defaultQuery: NotebookEntityQuery { NotebookEntityQuery() }

    var id: String
    var title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct NotebookEntityQuery: EntityQuery {
    func entities(for identifiers: [NotebookEntity.ID]) async throws -> [NotebookEntity] {
        await MainActor.run { NotebookEntityQuery.entities(for: identifiers) }
    }

    func suggestedEntities() async throws -> [NotebookEntity] {
        await MainActor.run { NotebookEntityQuery.suggestedEntities() }
    }

    @MainActor
    private static func suggestedEntities() -> [NotebookEntity] {
        let storage = StorageService.shared
        var notebooks = storage.fetchRecentNotebooks(limit: 20)
        if notebooks.count < 20 {
            let seen = Set(notebooks.map(\.id))
            let rest = storage.fetchAllNotebooks()
                .filter { !seen.contains($0.id) && !$0.isDeleted }
            notebooks.append(contentsOf: rest.prefix(20 - notebooks.count))
        }
        return notebooks.map { NotebookEntity(id: $0.id.uuidString, title: $0.title) }
    }

    @MainActor
    private static func entities(for identifiers: [String]) -> [NotebookEntity] {
        let idSet = Set(identifiers)
        return StorageService.shared.fetchAllNotebooks()
            .filter { idSet.contains($0.id.uuidString) && !$0.isDeleted }
            .map { NotebookEntity(id: $0.id.uuidString, title: $0.title) }
    }
}

// MARK: - Intents

/// App Intents / Shortcuts — Universal Purchase bundle enables both targets.
struct CreateNotebookIntent: AppIntent {
    static var title: LocalizedStringResource { "Create New Notebook" }
    static var description: IntentDescription { "Creates a new notebook in Cecilia's Notes." }
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
#if os(macOS)
            NotificationCenter.default.post(
                name: Notification.Name("app.ceciliasnotes.mac.newNotebook"),
                object: nil
            )
#else
            NotificationCenter.default.post(name: .ceciliasNotesCommandNewNotebook, object: nil)
#endif
        }
        return .result()
    }
}

struct OpenNotebookIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Notebook" }
    static var description: IntentDescription { "Opens a notebook in Cecilia's Notes." }
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Notebook")
    var notebook: NotebookEntity

    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: notebook.id) else { return .result() }
        await MainActor.run { CeciliasNotesIntentRouting.openNotebook(id: uuid) }
        return .result()
    }
}

struct OpenQuickCaptureIntent: AppIntent {
    static var title: LocalizedStringResource { "Quick Capture" }
    static var description: IntentDescription { "Open quick capture to jot a note." }
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
#if os(macOS)
            NotificationCenter.default.post(
                name: Notification.Name("app.ceciliasnotes.mac.quickCaptureToggle"),
                object: nil
            )
#else
            NotificationCenter.default.post(name: .ceciliasNotesQuickCapture, object: nil)
#endif
        }
        return .result()
    }
}

struct AskMyNotesIntent: AppIntent {
    static var title: LocalizedStringResource { "Ask My Notes" }
    static var description: IntentDescription {
        "Ask a question about your notes using on-device AI."
    }
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What would you like to ask about your notes?"))
    var question: String?

    func perform() async throws -> some IntentResult {
        let trimmed = question?.trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run {
            CeciliasNotesIntentRouting.openAsk(
                query: (trimmed?.isEmpty == false) ? trimmed : nil
            )
        }
        return .result()
    }
}

struct CeciliasNotesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNotebookIntent(),
            phrases: [
                "Create a notebook in \(.applicationName)",
                "New note in \(.applicationName)",
            ],
            shortTitle: "New Notebook",
            systemImageName: "plus"
        )
        AppShortcut(
            intent: OpenNotebookIntent(),
            phrases: [
                "Open \(\.$notebook) in \(.applicationName)",
                "Show \(\.$notebook) in \(.applicationName)",
            ],
            shortTitle: "Open Notebook",
            systemImageName: "book.closed"
        )
        AppShortcut(
            intent: OpenQuickCaptureIntent(),
            phrases: [
                "Quick capture in \(.applicationName)",
                "Capture a note in \(.applicationName)",
            ],
            shortTitle: "Quick Capture",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: AskMyNotesIntent(),
            phrases: [
                "Ask my notes in \(.applicationName)",
                "Ask \(.applicationName) about my notes",
            ],
            shortTitle: "Ask My Notes",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
    }
}

// MARK: - Routing

enum CeciliasNotesIntentRouting {
    @MainActor
    static func openNotebook(id: UUID) {
#if os(macOS)
        NotificationCenter.default.post(
            name: Notification.Name("app.ceciliasnotes.mac.openNotebook"),
            object: nil,
            userInfo: [CeciliasNotesIntentKeys.notebookId: id]
        )
#else
        NotificationCenter.default.post(
            name: .ceciliasNotesOpenNotebook,
            object: nil,
            userInfo: [CeciliasNotesIntentKeys.notebookId: id]
        )
#endif
    }

    @MainActor
    static func openAsk(query: String?) {
        var userInfo: [String: Any] = [:]
        if let query { userInfo[CeciliasNotesIntentKeys.askQuery] = query }
        NotificationCenter.default.post(
            name: .ceciliasNotesOpenAsk,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
    }
}
