import Foundation

/// Ring buffer of recent import/sync merge events surfaced in
/// Settings → Cloud → Conflicts. CloudKit row conflicts resolve
/// automatically (last-writer-wins); this log covers agent imports
/// where concurrent iPad edits were preserved via page-id merge.
@MainActor
enum SyncConflictLog {

    struct Record: Codable, Identifiable, Equatable {
        let id: UUID
        let date: Date
        let notebookTitle: String
        let sourceFilename: String
        let resolution: String
    }

    private static let key = "app.ceciliasnotes.sync.conflicts"
    private static let maxRecords = 30

    static var records: [Record] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        return decoded
    }

    static func record(
        notebookTitle: String,
        sourceFilename: String,
        resolution: String
    ) {
        var list = records
        list.insert(
            Record(
                id: UUID(),
                date: Date(),
                notebookTitle: notebookTitle,
                sourceFilename: sourceFilename,
                resolution: resolution
            ),
            at: 0
        )
        if list.count > maxRecords {
            list.removeLast(list.count - maxRecords)
        }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .syncConflictLogChanged, object: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: .syncConflictLogChanged, object: nil)
    }
}

extension Notification.Name {
    static let syncConflictLogChanged = Notification.Name("app.ceciliasnotes.sync.conflictsChanged")
}
