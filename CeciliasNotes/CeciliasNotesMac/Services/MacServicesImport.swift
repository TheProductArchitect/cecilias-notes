import Foundation

/// macOS Services menu — "New Note from Selection".
@MainActor
enum MacServicesImport {
    static func createNote(from selection: String) {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = String(lines.first ?? "Selection")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed

        let notebookTitle = title.isEmpty ? "Selection" : String(title.prefix(80))
        _ = MacQuickCaptureSave.save(title: notebookTitle, body: body)
    }
}
