import SwiftData
import SwiftUI

struct MacToolbarContent: ToolbarContent {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var editorState: MacLibraryState
    let editingNotebook: Notebook?
    @EnvironmentObject private var storageService: StorageService

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                MacStateUpdates.deferred { editorState.isExportPresented = true }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(editingNotebook == nil)

            Button { insertText() } label: {
                Label("Insert Text", systemImage: "text.insert")
            }
            .help("Add a text box to the current page")
            .disabled(editorState.selectedPageID == nil)

            Button { deleteSelection() } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete selected element")
            .disabled(editorState.selectedElementID == nil)

            Button {
                MacStateUpdates.deferred { editorState.editorZoom = min(editorState.editorZoom + 0.1, 4) }
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("=", modifiers: .command)

            Button {
                MacStateUpdates.deferred { editorState.editorZoom = max(editorState.editorZoom - 0.1, 0.25) }
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
        }
        // The old "Handwriting is iPad-only" pill used to sit in
        // `.status` placement — a permanent floating banner across
        // the title area. Killed. That constraint isn't a runtime
        // warning; it lives in Settings → About and in the empty
        // state of an editor page. Chrome should reflect real-time
        // state, not carry a Post-It.
    }

    private func insertText() {
        guard let pageID = editorState.selectedPageID,
              let notebookID = editorState.selectedNotebookID ?? editingNotebook?.id else { return }
        let descriptor = FetchDescriptor<Page>(
            predicate: #Predicate { $0.id == pageID }
        )
        guard let page = (try? storageService.context.fetch(descriptor))?.first else { return }
        if let element = MacElementEditing.insertText(
            on: page, notebookId: notebookID, context: storageService.context
        ) {
            editorState.selectedElementID = element.id
            MacStateUpdates.deferred { editorState.editingTextElement = element }
        }
    }

    private func deleteSelection() {
        guard let elementID = editorState.selectedElementID else { return }
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.id == elementID }
        )
        guard let element = (try? storageService.context.fetch(descriptor))?.first else { return }
        MacElementEditing.softDelete(element, context: storageService.context)
        MacStateUpdates.deferred { editorState.selectedElementID = nil }
    }
}

struct MacAppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Notebook") { NotificationCenter.default.post(name: .macNewNotebook, object: nil) }
                .keyboardShortcut("n")
            Button("Export…") { NotificationCenter.default.post(name: .macExport, object: nil) }
                .keyboardShortcut("e")
        }
        CommandGroup(after: .undoRedo) {
            Button("Insert Text") { NotificationCenter.default.post(name: .macInsertText, object: nil) }
                .keyboardShortcut("t")
        }
        // Explicit "Settings…" hook so ⌘, opens the Settings scene
        // reliably even in SwiftUI-only apps. SwiftUI's `Settings { }`
        // wires this automatically on macOS 13+, but the redundant
        // group makes the menu item's title/shortcut visible in
        // accessibility diagnostics and lets us route a NotificationCenter
        // trigger from anywhere in the app if we ever need to open
        // the panel programmatically.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                NotificationCenter.default.post(name: .macOpenSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

extension Notification.Name {
    static let macNewNotebook = Notification.Name("app.ceciliasnotes.mac.newNotebook")
    static let macExport = Notification.Name("app.ceciliasnotes.mac.export")
    static let macInsertText = Notification.Name("app.ceciliasnotes.mac.insertText")
    static let macOpenSettings = Notification.Name("app.ceciliasnotes.mac.openSettings")
}
