import Combine
import Foundation

/// Single source of truth for deep-link targets. Library surfaces
/// observe and react — iOS via `LibraryView`, Mac via `MacRootView`.
@MainActor
final class DeepLinkRouter: ObservableObject {

    /// When set, the Library should open this notebook in the editor.
    @Published var openNotebookId: UUID?

    /// Optional page to scroll to when opening `openNotebookId`.
    @Published var openPageId: UUID?

    /// When true (and `openNotebookId` is also set), the editor should present
    /// the export sheet immediately on appear.
    @Published var pendingExport: Bool = false

    /// When true, the Library should present the settings sheet.
    @Published var openSettings: Bool = false

    /// When true, the Library should immediately create a new playful-named
    /// notebook and open it in the editor — the Quick Capture flow.
    @Published var pendingQuickCapture: Bool = false

    /// Pulsed when an inbound deep link explicitly targets
    /// `ceciliasnotes://library`. The Library observes this and
    /// dismisses any active editor cover so the user lands on the
    /// home surface.
    @Published var forceLibraryHome: Bool = false

    /// Parses `ceciliasnotes://open/{uuid}`, `ceciliasnotes://notebook/{id}/page/{id}`,
    /// `ceciliasnotes://library`, `ceciliasnotes://settings`, `ceciliasnotes://quick-capture`,
    /// `ceciliasnotes://inbox` (bring-to-foreground only — share
    /// extension uses this for `.ceciliabook` so the inbox watcher
    /// can open the imported notebook without first forcing the
    /// library home surface).
    func handle(_ url: URL) {
        // Tap-to-open a `.ceciliabook` file (Files, AirDrop, Drive,
        // Mail attachment). Import it as a fresh editable copy, then
        // route the Library to open it. Files delivered from outside
        // the sandbox need a security scope while we read them.
        if url.isFileURL,
           url.pathExtension.lowercased() == NotebookArchive.fileExtension {
            // Read the bytes under the security scope NOW (one fast
            // file read), decode + reconstruct async — the old
            // synchronous import decoded up to 32 MB of JSON inside
            // `onOpenURL` on the main thread, a guaranteed
            // multi-second ANR for a media-heavy notebook.
            let scoped = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let data else { return }
            Task { @MainActor [weak self] in
                if let notebook = await NotebookArchiveIO.importArchiveAsync(data: data) {
                    self?.openNotebookId = notebook.id
                    self?.openPageId = nil
                }
            }
            return
        }
        guard url.scheme == "ceciliasnotes" else { return }
        switch url.host {
        case "open":
            let raw = url.lastPathComponent
            if let uuid = UUID(uuidString: raw) {
                openNotebookId = uuid
                openPageId = nil
            }
        case "notebook":
            let parts = url.pathComponents.filter { $0 != "/" }
            if let pageIndex = parts.firstIndex(of: "page"),
               pageIndex > 0,
               pageIndex + 1 < parts.count,
               let notebookId = UUID(uuidString: parts[pageIndex - 1]),
               let pageId = UUID(uuidString: parts[pageIndex + 1]) {
                openNotebookId = notebookId
                openPageId = pageId
            } else if let first = parts.first, let notebookId = UUID(uuidString: first) {
                openNotebookId = notebookId
                openPageId = nil
            }
        case "settings":
            openSettings = true
        case "library":
            openNotebookId = nil
            openPageId = nil
            openSettings = false
            forceLibraryHome = true
        case "inbox":
            // Share extension handed us a `.ceciliabook`. Just bring
            // the app forward — ShareInboxWatcher imports and posts
            // `.ceciliasNotesOpenNotebook` once the copy is ready.
            // Intentionally does NOT set forceLibraryHome (that was
            // the "shared into library, never opened" bug).
            break
        case "quick-capture":
            pendingQuickCapture = true
        default:
            break
        }
    }
}
