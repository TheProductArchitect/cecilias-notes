import AppKit
import Foundation

/// Outcome of a Mac export — used by the export sheet and recent exports list.
struct MacExportResult: Sendable, Equatable {
    let url: URL
    let format: MacExportFormat
    let pageCount: Int
    let fileSizeBytes: Int64
    let notebookId: UUID
    let notebookTitle: String
    let exportedAt: Date

    var displayName: String { url.lastPathComponent }

    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var formatLabel: String { format.label }

    static var exportsFolderLabel: String {
        "Cecilia's Notes → Exports"
    }

    var friendlyPath: String {
        Self.friendlyPath(for: url)
    }

    static func friendlyPath(for url: URL) -> String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    var exportRecord: ExportRecord {
        ExportRecord(
            notebookId: notebookId,
            notebookTitle: notebookTitle,
            fileURL: url,
            fileSizeBytes: fileSizeBytes,
            pageCount: pageCount,
            exportedAt: exportedAt
        )
    }
}

enum MacExportReveal {
    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openExportsFolder() {
        let dir = StorageService.globalExportsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    static func openParentFolder(of url: URL) {
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
}

struct MacImportFeedback: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var openExportsFolder: Bool = false
}
