import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var themeManager:     ThemeManager
    @EnvironmentObject private var cloudSyncManager: CloudSyncManager
    @EnvironmentObject private var deepLink:         DeepLinkRouter

    @StateObject private var viewModel = LibraryViewModel()
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
            ZStack(alignment: .top) {
                NotebookGridView(viewModel: viewModel)

                // Error banner — slides from top when a storage mutation fails.
                if let message = viewModel.error?.errorDescription {
                    MediaErrorBanner(message: message) {
                        viewModel.error = nil
                    }
                    .padding(.top, Ink.Spacing.md)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(99)
                }
            }
            .animation(.inkSpring(InkSpring.smooth), value: viewModel.error)
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
        .sheet(isPresented: $isShowingRecentExports) {
            RecentExportsView { notebookId in
                isShowingRecentExports = false
                reExportNotebookId = notebookId
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                cloudSyncManager: cloudSyncManager,
                themeManager:     themeManager
            ) {
                isShowingSettings = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // Each .onChange below mutates the publisher it observes (sets the
        // trigger property back to nil/false). SwiftUI considers re-entrant
        // publisher mutations during an .onChange handler to be "during view
        // updates", which emits the runtime warning. Defer those write-backs
        // to the next runloop tick so the warning never fires.
        .onChange(of: reExportNotebookId) { _, id in
            guard let id, let notebook = viewModel.notebook(id: id) else { return }
            DispatchQueue.main.async { reExportNotebookId = nil }
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
            DispatchQueue.main.async {
                viewModel.pendingExportNotebookId = nil
                deepLink.pendingExport = true
            }
            editingNotebook = notebook
        }
        // Deep-link routing — Spotlight, ink:// URLs, widgets
        .onChange(of: deepLink.openNotebookId) { _, id in
            guard let id, let notebook = viewModel.notebook(id: id) else { return }
            DispatchQueue.main.async { deepLink.openNotebookId = nil }
            editingNotebook = notebook
        }
        .onChange(of: deepLink.openSettings) { _, open in
            guard open else { return }
            DispatchQueue.main.async { deepLink.openSettings = false }
            isShowingSettings = true
        }
        .fullScreenCover(item: $editingNotebook) { notebook in
            EditorView(notebook: notebook) {
                editingNotebook = nil
                viewModel.selectedNotebookId = nil
                viewModel.refresh()       // pull updated thumbnails / titles
            }
        }
        // Real keyboard shortcuts come through the .commands modifier on the
        // WindowGroup (see InkCommands). The ⌘, settings shortcut stays here
        // because Apple reserves ⌘, for app preferences and the .commands menu
        // structure can't slot it cleanly.
        .background(
            VStack(spacing: 0) {
                Button("Settings") { isShowingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        )
        // Listen for menu-bar / discoverability commands from InkCommands.
        .onReceive(NotificationCenter.default.publisher(for: .inkCommandNewNotebook)) { _ in
            viewModel.createUntitledNotebookAndOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkCommandSearch)) { _ in
            withAnimation(.inkSpring(InkSpring.smooth)) {
                viewModel.isSearchActive = true
            }
        }
        // Quick Capture lock-screen widget — create a fresh notebook and dive
        // straight into the editor. The flag is read once and cleared.
        .onChange(of: deepLink.pendingQuickCapture) { _, pending in
            guard pending else { return }
            DispatchQueue.main.async { deepLink.pendingQuickCapture = false }
            viewModel.createUntitledNotebookAndOpen()
        }
        .task {
            // Cold-launch case: pendingQuickCapture may already be true by the
            // time the view first appears, before any onChange would fire.
            if deepLink.pendingQuickCapture {
                deepLink.pendingQuickCapture = false
                viewModel.createUntitledNotebookAndOpen()
            }
        }
    }
}
