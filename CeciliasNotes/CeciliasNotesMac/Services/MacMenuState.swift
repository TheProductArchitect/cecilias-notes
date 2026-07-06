import Foundation

/// Drives dynamic File-menu entries (Open Recent) from live library data.
@MainActor
final class MacMenuState: ObservableObject {
    static let shared = MacMenuState()

    struct RecentItem: Identifiable {
        let id: UUID
        let title: String
    }

    @Published private(set) var recentNotebooks: [RecentItem] = []

    func refresh() {
        recentNotebooks = StorageService.shared
            .fetchRecentNotebooks(limit: 10)
            .map { RecentItem(id: $0.id, title: $0.title) }
    }

    func openMostRecent() {
        guard let first = recentNotebooks.first else { return }
        openNotebook(id: first.id)
    }

    func openNotebook(id: UUID) {
        NotificationCenter.default.post(
            name: .macOpenNotebook,
            object: nil,
            userInfo: [CeciliasNotesIntentKeys.notebookId: id]
        )
    }
}
