import Foundation

// MARK: - WidgetDataWriter

/// Bridges the SwiftData store (main app, sandboxed) to the WidgetKit extension
/// (separate sandbox, no SwiftData access). Writes a small JSON snapshot to
/// the shared App Group container after every notebook save (debounced 2s).
///
/// **Required Xcode setup:**
/// - Both the main app and the `CeciliasNotesWidget` extension target must list the same
///   App Group (`group.app.ceciliasnotes`) under
///   "Signing & Capabilities → App Groups".
/// - The bundle identifier inside `Self.appGroup` must be the one configured.
///   Update the constant here to match.
actor WidgetDataWriter {

    static let shared = WidgetDataWriter()

    /// Replace with your App Group identifier. Used by both targets.
    static let appGroup = "group.app.ceciliasnotes"
    private static let fileName = "ink_widget_data.json"

    private var pendingTask: Task<Void, Never>?

    // MARK: Container URL

    /// Shared file URL inside the App Group. Returns nil if the App Group is
    /// not configured (e.g. debug build without entitlements).
    static var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    // MARK: Public API

    /// Coalesces rapid saves into a single write 2s after the last call.
    func scheduleWrite(_ summaries: [NotebookSummary]) {
        pendingTask?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.write(summaries)
        }
        pendingTask = task
    }

    /// Immediate write — call from `applicationWillTerminate` / app-background.
    func write(_ summaries: [NotebookSummary]) async {
        guard let url = Self.containerURL else { return }
        do {
            let data = try JSONEncoder().encode(summaries)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort. Widget will fall back to its placeholder.
        }
    }

    /// Reads the snapshot. Used by `CeciliasNotesWidgetProvider`.
    static func read() -> [NotebookSummary] {
        guard let url = containerURL,
              let data = try? Data(contentsOf: url),
              let arr  = try? JSONDecoder().decode([NotebookSummary].self, from: data)
        else { return [] }
        return arr
    }
}

// MARK: - NotebookSummary

/// The widget's view of a notebook. Intentionally tiny — keep this struct stable;
/// the widget extension decodes it. Coupled to whatever properties the small +
/// medium widget templates need to render.
struct NotebookSummary: Codable, Identifiable, Sendable, Hashable {
    let id:             UUID
    let title:          String
    let coverColorHex:  String
    let coverTexture:   String   // CoverTexture.rawValue (decouples the widget from the enum)
    let pageCount:      Int
    let updatedAt:      Date
}
