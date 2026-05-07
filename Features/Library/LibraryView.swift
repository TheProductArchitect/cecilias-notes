import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var themeManager:     ThemeManager
    @EnvironmentObject private var cloudSyncManager: CloudSyncManager
    @EnvironmentObject private var deepLink:         DeepLinkRouter

    @StateObject private var viewModel = LibraryViewModel()
    // Sidebar is never collapsible on iPad — held at .all via binding guard.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The notebook currently being edited (if any). Drives the full-screen Editor cover.
    @State private var editingNotebook: Notebook?

    @State private var isShowingRecentExports = false
    @State private var isShowingSettings      = false
    @State private var reExportNotebookId: UUID?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SubjectSidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 260, ideal: 260, max: 260)
        } detail: {
            NotebookGridView(viewModel: viewModel)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            isShowingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 17, weight: .medium))
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button {
                                isShowingRecentExports = true
                            } label: {
                                Label("Recent Exports", systemImage: "doc.richtext")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 17, weight: .medium))
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: columnVisibility) { _, new in
            // Prevent the user from collapsing the sidebar
            if new != .all { columnVisibility = .all }
        }
        .sheet(isPresented: $viewModel.isShowingNewNotebook, onDismiss: {
            viewModel.refresh()
        }) {
            NewNotebookSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingRecentExports) {
            RecentExportsView { notebookId in
                isShowingRecentExports = false
                reExportNotebookId = notebookId
            }
        }
        .fullScreenCover(isPresented: $isShowingSettings) {
            SettingsView(
                cloudSyncManager: cloudSyncManager,
                themeManager:     themeManager
            ) {
                isShowingSettings = false
            }
        }
        .onChange(of: reExportNotebookId) { _, id in
            guard let id, let notebook = viewModel.notebook(id: id) else { return }
            reExportNotebookId = nil
            editingNotebook = notebook
        }
        // Open editor when a notebook is selected
        .onChange(of: viewModel.selectedNotebookId) { _, id in
            guard let id, let notebook = viewModel.notebook(id: id) else { return }
            editingNotebook = notebook
        }
        // Library "Share as PDF…" — open the editor with export pre-armed
        .onChange(of: viewModel.pendingExportNotebookId) { _, id in
            guard let id, let notebook = viewModel.notebook(id: id) else { return }
            viewModel.pendingExportNotebookId = nil
            deepLink.pendingExport = true
            editingNotebook = notebook
        }
        // Deep-link routing — Spotlight, ink:// URLs, widgets
        .onChange(of: deepLink.openNotebookId) { _, id in
            guard let id, let notebook = viewModel.notebook(id: id) else { return }
            deepLink.openNotebookId = nil
            editingNotebook = notebook
        }
        .onChange(of: deepLink.openSettings) { _, open in
            guard open else { return }
            deepLink.openSettings = false
            isShowingSettings = true
        }
        .fullScreenCover(item: $editingNotebook) { notebook in
            EditorView(notebook: notebook) {
                editingNotebook = nil
                viewModel.selectedNotebookId = nil
                viewModel.refresh()       // pull updated thumbnails / titles
            }
        }
        // Keyboard shortcuts (external keyboard)
        .background(
            VStack(spacing: 0) {
                Button("New Notebook") { viewModel.isShowingNewNotebook = true }
                    .keyboardShortcut("n", modifiers: .command)
                // ⌘F is owned by the search button in NotebookGridView (toolbar).
                Button("Settings")     { isShowingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        )
    }
}

// Make Notebook conform to Identifiable for fullScreenCover(item:) — it already has an id,
// but SwiftData's Identifiable conformance must be re-asserted in the editor module.
extension Notebook: Identifiable {}
