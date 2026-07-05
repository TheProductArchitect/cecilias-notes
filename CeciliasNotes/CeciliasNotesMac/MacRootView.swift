import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MacRootView: View {
    @Binding var showOnboarding: Bool
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storageService: StorageService
    @EnvironmentObject private var cloudSync: CloudSyncManager

    @StateObject private var libraryVM = LibraryViewModel()
    @StateObject private var editorState = MacLibraryState()
    @State private var editingNotebook: Notebook?

    var body: some View {
        // Full-plane composition mirroring the iPad `LibraryView`:
        // masthead spans the full width above the sidebar/content
        // split, sidebar sits inline (not a `NavigationSplitView`
        // column so the 1.5pt hairline from `LibraryHeaderView` reads
        // as one strict rule across identity + content). The editor
        // opens as a `.sheet` — same "cover" affordance as the iPad,
        // adapted to Mac's window model.
        VStack(spacing: 0) {
            LibraryHeaderView(viewModel: libraryVM)
            // Sync banner slots between masthead and content — reads
            // as a subtitle to the 1.5pt black rule the masthead ends
            // with, not a floating warning stripe covering the title
            // bar. Silent (EmptyView) when sync is healthy.
            MacSyncBanner()
            HStack(spacing: 0) {
                SubjectSidebarView(viewModel: libraryVM)
                    .frame(width: 240)
                    .background(theme.surface)
                libraryContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.background)
        .onDrop(of: [.fileURL, .pdf], isTargeted: nil) { providers in
            handleLibraryDrop(providers)
        }
        .sheet(item: $editingNotebook) { notebook in
            MacEditorView(notebook: notebook, state: editorState)
                .environmentObject(storageService)
                .environmentObject(cloudSync)
                .environment(\.theme, theme)
                .frame(minWidth: 900, minHeight: 640)
        }
        .toolbar {
            MacToolbarContent(libraryVM: libraryVM, editorState: editorState, editingNotebook: editingNotebook)
        }
        .sheet(isPresented: $editorState.isExportPresented) {
            MacExportSheet(notebook: editingNotebook, state: editorState)
                .environmentObject(storageService)
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $showOnboarding) {
            MacOnboardingView(isPresented: $showOnboarding)
                .environment(\.theme, theme)
        }
        .onAppear {
            MacStateUpdates.deferred {
                if let raw = UserDefaults.standard.string(forKey: "mac.export.defaultFormat"),
                   let format = MacExportFormat(rawValue: raw) {
                    editorState.exportFormat = format
                }
                storageService.purgeDuplicateRows()
                storageService.reconcileSoftDeleteFlags()
                Task { await SearchIndexService.shared.loadAsync() }
            }
        }
        .onChange(of: libraryVM.selectedNotebookId) { _, id in
            MacStateUpdates.deferred {
                guard let id, let notebook = libraryVM.notebook(id: id) else { return }
                editingNotebook = notebook
                editorState.selectedNotebookID = notebook.id
                RecentNotebooksTracker.markOpened(notebook.id)
            }
        }
        .onChange(of: editorState.exportFormat) { _, format in
            UserDefaults.standard.set(format.rawValue, forKey: "mac.export.defaultFormat")
        }
        .onReceive(NotificationCenter.default.publisher(for: .macOpenHandoffPage)) { note in
            MacStateUpdates.deferred {
                guard let notebookID = note.userInfo?[MacHandoff.notebookIdKey] as? UUID else { return }
                if let notebook = libraryVM.notebook(id: notebookID) {
                    editingNotebook = notebook
                    editorState.selectedNotebookID = notebookID
                }
                editorState.selectedPageID = note.userInfo?[MacHandoff.pageIdKey] as? UUID
                if let zoom = note.userInfo?[MacHandoff.zoomKey] as? CGFloat {
                    editorState.editorZoom = zoom
                }
                if let offset = note.userInfo?[MacHandoff.scrollOffsetKey] as? CGFloat {
                    editorState.editorScrollOffset = offset
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macExport)) { _ in
            MacStateUpdates.deferred { editorState.isExportPresented = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macInsertText)) { _ in
            NotificationCenter.default.post(name: .macInsertTextOnPage, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macNewNotebook)) { _ in
            MacStateUpdates.deferred { libraryVM.createNotebookWithFallback() }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if libraryVM.isShowingTrash {
            TrashView(viewModel: libraryVM)
        } else if libraryVM.selectedContext == .allSubjects {
            MacEmptyState(
                icon: "folder",
                title: "All subjects",
                message: "Subject management is coming to Mac. Use your iPad to bulk-edit subjects."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if libraryVM.selectedContext == .allQuizzes {
            MacEmptyState(
                icon: "checklist",
                title: "All quizzes",
                message: "Quizzes are iPad-first today. Open them on your iPad."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if libraryVM.selectedQuizID != nil {
            MacEmptyState(
                icon: "checklist",
                title: "Quiz detail",
                message: "Take and edit quizzes on your iPad."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NotebookGridView(viewModel: libraryVM)
        }
    }

    private func handleLibraryDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        if url.pathExtension.lowercased() == "pdf" {
                            if let id = await MacImportService.importPDFAsNotebook(
                                from: url,
                                subjectId: libraryVM.selectedContext.subjectId,
                                storage: storageService
                            ) {
                                MacStateUpdates.deferred {
                                    libraryVM.refresh()
                                    if let notebook = libraryVM.notebook(id: id) {
                                        editingNotebook = notebook
                                        editorState.selectedNotebookID = id
                                    }
                                }
                            }
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}

/// Editorial hairline banner that reads the CloudKit container's
/// resolved status and surfaces the two states the user should know
/// about: local-only fallback (sign-in required) and first-run sync
/// (progress). Everything else stays silent — the chrome should
/// never scream at the user when things are working.
///
/// Visual language matches the sidebar's section labels: 8pt tracked
/// uppercase, `theme.recessive*` colours, hairline separator on the
/// bottom edge. Same aesthetic as `DateEyebrow` — the banner reads as
/// a subtitle to the masthead rather than a warning strip.
private struct MacSyncBanner: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch CloudKitContainerState.status {
            case .localOnlyFallback:
                editorialRow(
                    icon: "icloud.slash",
                    tint: theme.recessiveTertiary,
                    text: "not signed in to icloud — your notes won't sync"
                )
            case .uninitialized:
                editorialRow(
                    icon: "icloud",
                    tint: theme.recessiveTertiary,
                    text: "syncing library"
                )
            default:
                EmptyView()
            }
        }
    }

    private func editorialRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 8, weight: .regular))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
        }
    }
}

extension Notification.Name {
    static let macCreateNotebook = Notification.Name("app.ceciliasnotes.mac.createNotebook")
    static let macInsertTextOnPage = Notification.Name("app.ceciliasnotes.mac.insertTextOnPage")
}
