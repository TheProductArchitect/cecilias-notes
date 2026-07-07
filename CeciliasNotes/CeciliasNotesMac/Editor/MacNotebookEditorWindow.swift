import SwiftUI

/// Dedicated window for editing one notebook (`WindowGroup(id:for:)`),
/// or inline in the library window when `onClose` is provided.
struct MacNotebookEditorWindow: View {
    let notebookID: UUID
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var storageService: StorageService
    @EnvironmentObject private var cloudSync: CloudSyncManager
    @EnvironmentObject private var deepLink: DeepLinkRouter
    @Environment(\.theme) private var theme

    @StateObject private var editorState = MacLibraryState()

    private var notebook: Notebook? { libraryVM.notebook(id: notebookID) }

    var body: some View {
        Group {
            if let notebook {
                MacEditorView(
                    notebook: notebook,
                    state: editorState,
                    libraryVM: libraryVM,
                    onClose: onClose
                )
                    .environmentObject(storageService)
                    .environmentObject(cloudSync)
            } else {
                ContentUnavailableView(
                    "Notebook not found",
                    systemImage: "book.closed",
                    description: Text("It may have been deleted on another device.")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .background {
            if onClose == nil {
                MacWindowTag(identifier: "notebook-editor")
            }
        }
        .onChange(of: libraryVM.deepLinkPageId) { _, pageID in
            guard pageID != nil else { return }
            MacStateUpdates.deferred { applyPendingDeepLinkIfNeeded() }
        }
        .onAppear {
            editorState.selectedNotebookID = notebookID
            applyPendingDeepLinkIfNeeded()
            restoreResumePageIfNeeded()
            if let raw = UserDefaults.standard.string(forKey: "mac.export.defaultFormat"),
               let format = MacExportFormat(rawValue: raw) {
                editorState.exportFormat = format
            }
            if deepLink.pendingExport {
                deepLink.pendingExport = false
                editorState.isExportPresented = true
            }
            MacMenuState.shared.refresh()
            persistResumeState(pageID: editorState.selectedPageID)
        }
        .onChange(of: editorState.exportFormat) { _, format in
            UserDefaults.standard.set(format.rawValue, forKey: "mac.export.defaultFormat")
        }
        .onChange(of: editorState.selectedPageID) { _, pageID in
            persistResumeState(pageID: pageID)
        }
        .sheet(isPresented: $editorState.isExportPresented) {
            if let notebook {
                MacExportSheet(notebook: notebook, state: editorState)
                    .environmentObject(storageService)
                    .environment(\.theme, theme)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macExport)) { _ in
            MacStateUpdates.deferred { editorState.isExportPresented = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macPrint)) { _ in
            MacStateUpdates.deferred {
                guard let notebook else { return }
                MacPrintService.printNotebook(notebook, storage: storageService)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macOpenHandoffPage)) { note in
            MacStateUpdates.deferred { applyHandoff(note) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macZoomReset)) { _ in
            MacStateUpdates.deferred { editorState.editorZoom = 1.0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macZoomIn)) { _ in
            MacStateUpdates.deferred { adjustZoom(by: zoomStep) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macZoomOut)) { _ in
            MacStateUpdates.deferred { adjustZoom(by: -zoomStep) }
        }
    }

    private var zoomStep: CGFloat {
        let stored = UserDefaults.standard.double(forKey: "mac.editor.zoomStep")
        return stored > 0 ? CGFloat(stored) : 0.1
    }

    private func adjustZoom(by delta: CGFloat) {
        editorState.editorZoom = min(2, max(0.75, editorState.editorZoom + delta))
    }

    /// Search / Ask citations set `deepLinkPageId` before the editor mounts.
    private func applyPendingDeepLinkIfNeeded() {
        guard let pageID = libraryVM.deepLinkPageId else { return }
        libraryVM.deepLinkPageId = nil
        editorState.selectedPageID = pageID
        persistResumeState(pageID: pageID)
    }

    /// When resume is on, reopen the last page for this notebook.
    private func restoreResumePageIfNeeded() {
        guard editorState.selectedPageID == nil else { return }
        let resumeOn = UserDefaults.standard.object(forKey: "ceciliasnotes.resume.enabled") as? Bool ?? true
        guard resumeOn,
              UserDefaults.standard.string(forKey: "ceciliasnotes.resume.lastNotebookId") == notebookID.uuidString,
              let raw = UserDefaults.standard.string(forKey: "ceciliasnotes.resume.lastPageId"),
              let pageID = UUID(uuidString: raw) else { return }
        editorState.selectedPageID = pageID
    }

    private func persistResumeState(pageID: UUID?) {
        let resumeOn = UserDefaults.standard.object(forKey: "ceciliasnotes.resume.enabled") as? Bool ?? true
        guard resumeOn else { return }
        UserDefaults.standard.set(notebookID.uuidString, forKey: "ceciliasnotes.resume.lastNotebookId")
        if let pageID {
            UserDefaults.standard.set(pageID.uuidString, forKey: "ceciliasnotes.resume.lastPageId")
        }
    }

    private func applyHandoff(_ note: Notification) {
        guard let id = note.userInfo?[MacHandoff.notebookIdKey] as? UUID,
              id == notebookID else { return }
        editorState.selectedPageID = note.userInfo?[MacHandoff.pageIdKey] as? UUID
        if let zoom = note.userInfo?[MacHandoff.zoomKey] as? CGFloat {
            editorState.editorZoom = zoom
        }
        if let offset = note.userInfo?[MacHandoff.scrollOffsetKey] as? CGFloat {
            editorState.editorScrollOffset = offset
            editorState.pendingHandoffScrollOffset = offset
        }
    }
}
