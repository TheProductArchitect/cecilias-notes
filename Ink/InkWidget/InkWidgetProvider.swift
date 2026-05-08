import WidgetKit
import SwiftUI

// MARK: - Entry

struct NotebookEntry: TimelineEntry {
    let date:      Date
    let primary:   NotebookSummary?
    let recents:   [NotebookSummary]
}

// MARK: - Provider

/// Reads the App Group JSON snapshot on every refresh. Refreshes every 15
/// minutes (Apple's policy permits the system to coalesce these). The
/// system also reloads when the main app calls
/// `WidgetCenter.shared.reloadTimelines(ofKind:)`.
struct InkWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> NotebookEntry {
        NotebookEntry(date: Date(), primary: .placeholder, recents: NotebookSummary.placeholders)
    }

    func getSnapshot(in context: Context, completion: @escaping (NotebookEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NotebookEntry>) -> Void) {
        let entry = currentEntry()
        let next  = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    // MARK: Snapshot read

    private func currentEntry() -> NotebookEntry {
        let all = Self.readFromAppGroup().sorted { $0.updatedAt > $1.updatedAt }
        let recents = Array(all.prefix(3))
        return NotebookEntry(date: Date(), primary: all.first, recents: recents)
    }

    private static func readFromAppGroup() -> [NotebookSummary] {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.wave.venu.Ink")?
            .appendingPathComponent("ink_widget_data.json"),
              let data = try? Data(contentsOf: url),
              let arr  = try? JSONDecoder().decode([NotebookSummary].self, from: data)
        else { return [] }
        return arr
    }
}

// MARK: - Placeholder data

extension NotebookSummary {
    static let placeholder = NotebookSummary(
        id: UUID(),
        title: "Ideas",
        coverColorHex: "#007AFF",
        coverTexture: "linen",
        pageCount: 12,
        updatedAt: Date()
    )

    static let placeholders: [NotebookSummary] = [
        placeholder,
        NotebookSummary(id: UUID(), title: "Lecture Notes",
                        coverColorHex: "#FF9500", coverTexture: "ruled",
                        pageCount: 38, updatedAt: Date().addingTimeInterval(-3600)),
        NotebookSummary(id: UUID(), title: "Sketches",
                        coverColorHex: "#34C759", coverTexture: "dot",
                        pageCount: 7, updatedAt: Date().addingTimeInterval(-86400))
    ]
}
