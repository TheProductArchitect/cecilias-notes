import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var themeManager:     ThemeManager
    @EnvironmentObject private var cloudSyncManager: CloudSyncManager
    @EnvironmentObject private var deepLink:         DeepLinkRouter

    @StateObject private var viewModel        = LibraryViewModel()
    @StateObject private var keyboardObserver = KeyboardObserver.shared

    /// Sidebar visibility — toggled by the leading action-strip button.
    /// Persisted across launches so a user who collapsed it stays
    /// collapsed.
    @AppStorage("library.sidebar.visible") private var isSidebarVisible: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The notebook currently being edited (if any). Drives the full-screen Editor cover.
    @State private var editingNotebook: Notebook?

    @State private var isShowingRecentExports = false
    @State private var isShowingSettings      = false
    @State private var reExportNotebookId: UUID?

    // Image-picker presentation is now driven by
    // `viewModel.pendingImageImport`. The editor signals intent
    // via NotificationCenter; LibraryViewModel observes and
    // flips that state; the `.sheet(item:)` below presents from
    // this view (the cover's host, outside the cover destination).

    private static let sidebarWidth: CGFloat = 240

    // Onboarding routing now lives in `RootView` (the launch
    // coordinator) — when this view mounts the user is guaranteed to
    // have either completed onboarding or skipped it via a route
    // outside the Library's control. No onboarding cover here.

    var body: some View {
        contentLayer
            .onAppear {
                #if DEBUG
                print("[ImageInsert] 4. LibraryView.onAppear — cover dismissed, library is back on top (editingNotebook=\(editingNotebook?.id.uuidString ?? "nil"))")
                #endif
            }
            .onChange(of: viewModel.pendingExportNotebookId) { _, id in
                guard let id, let notebook = viewModel.notebook(id: id) else { return }
                DispatchQueue.main.async {
                    viewModel.pendingExportNotebookId = nil
                    deepLink.pendingExport = true
                }
                editingNotebook = notebook
            }
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
            // Every `viewModel.*` mutation inside `.onReceive` is
            // deferred to the next runloop tick via `Task { @MainActor
            // in }`. Notification publishers can fire synchronously
            // during an active SwiftUI view-update transaction (e.g.
            // foreground notifications during sheet dismissal), and a
            // direct `@Published` write there triggers the "Publishing
            // changes from within view updates is not allowed"
            // warning. Repeated occurrences cascade into a render
            // loop that has crashed the app with SIGKILL under memory
            // pressure.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { @MainActor in viewModel.refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                Task { @MainActor in viewModel.clearTagFilters() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inkCommandNewNotebook)) { _ in
                guard viewModel.selectedSubjectId != nil else { return }
                Task { @MainActor in viewModel.createUntitledNotebookAndOpen() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inkCommandSearch)) { _ in
                Task { @MainActor in
                    withAnimation(.inkSpring(CeciliasNotesSpring.smooth)) { viewModel.isSearchActive = true }
                }
            }
            .onChange(of: deepLink.pendingQuickCapture) { _, pending in
                guard pending else { return }
                DispatchQueue.main.async { deepLink.pendingQuickCapture = false }
                viewModel.createUntitledNotebookAndOpen()
            }
            .task { handleQuickCaptureOnLaunch() }
    }

    private var contentLayer: some View {
        VStack(spacing: 0) {
            actionStrip
            LibraryHeaderView(viewModel: viewModel)
            HStack(spacing: 0) {
                if isSidebarVisible {
                    SubjectSidebarView(viewModel: viewModel)
                        .frame(width: Self.sidebarWidth)
                        .background(Color(.systemBackground))
                        .transition(.move(edge: .leading))
                }
                NotebookGridView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard keyboardObserver.isKeyboardVisible else { return }
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
        )
        .overlay(alignment: .top) {
            if let message = viewModel.error?.errorDescription {
                MediaErrorBanner(message: message) { viewModel.error = nil }
                    .padding(.top, CeciliasNotes.Spacing.md)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(99)
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.isImporting {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("importing \(viewModel.importProgressCompleted) of \(viewModel.importProgressTotal) PDF\(viewModel.importProgressTotal == 1 ? "" : "s")…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.inkRecessivePrimary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 24)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .zIndex(98)
            }
        }
        .animation(.inkSpring(CeciliasNotesSpring.smooth), value: viewModel.isImporting)
        .alert(
            "Couldn't import",
            isPresented: Binding(
                get: { viewModel.importError != nil },
                set: { if !$0 { viewModel.importError = nil } }
            ),
            presenting: viewModel.importError
        ) { _ in
            Button("OK", role: .cancel) { viewModel.importError = nil }
        } message: { err in
            Text(err.errorDescription ?? "Some PDFs couldn't be imported.")
        }
        .animation(.inkSpring(CeciliasNotesSpring.smooth), value: viewModel.error)
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: keyboardObserver.isFloatingKeyboard ? .bottom : [])
        .animation(reduceMotion ? nil : .inkSpring(CeciliasNotesSpring.snappy), value: isSidebarVisible)
        .sheet(isPresented: $isShowingRecentExports) {
            RecentExportsView { notebookId in
                isShowingRecentExports = false
                reExportNotebookId = notebookId
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(cloudSyncManager: cloudSyncManager, themeManager: themeManager) {
                isShowingSettings = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: reExportNotebookId) { _, id in
            guard let id, let notebook = viewModel.notebook(id: id) else { return }
            DispatchQueue.main.async { reExportNotebookId = nil }
            editingNotebook = notebook
        }
        .onChange(of: viewModel.selectedNotebookId) { _, id in
            #if DEBUG
            print("[Library] onChange(selectedNotebookId) → \(id?.uuidString ?? "nil")")
            #endif
            guard let id, let notebook = viewModel.notebook(id: id) else {
                #if DEBUG
                if id != nil { print("[Library] notebook(id:) returned nil — id stale?") }
                #endif
                return
            }
            editingNotebook = notebook
        }
        .onChange(of: viewModel.pendingOpenAfterImport) { _, nb in
            guard let nb else { return }
            viewModel.pendingOpenAfterImport = nil
            editingNotebook = nb
        }
        .fullScreenCover(item: $editingNotebook) { notebook in
            EditorView(
                notebook: notebook,
                deepLinkPageId: viewModel.deepLinkPageId,
                onDismiss: {
                    // `editingNotebook = nil` triggers the cover
                    // dismiss animation; the remaining viewModel
                    // writes + refresh are deferred to the next
                    // runloop tick so they don't fire @Published
                    // mutations during the cover's own dismiss
                    // transaction. Refresh in particular touches
                    // half a dozen @Published arrays and was a
                    // primary source of the "Publishing changes
                    // from within view updates" warning on every
                    // back-from-editor tap.
                    editingNotebook = nil
                    Task { @MainActor in
                        viewModel.selectedNotebookId = nil
                        viewModel.deepLinkPageId = nil
                        viewModel.refresh()
                    }
                }
            )
        }
        .onChange(of: editingNotebook) { _, new in
            if new == nil { viewModel.selectedNotebookId = nil }
        }
        // Image-import picker is presented via `MediaPickerPresenter`
        // (UIKit-direct present-on-topmost-VC) wired in
        // `LibraryViewModel.subscribeToImageImports`. The previous
        // SwiftUI `.sheet(item: $viewModel.pendingImageImport)` here
        // collapsed the editor's `.fullScreenCover` ("only presenting
        // a single sheet is supported") and was the cause of the
        // "image insert tears down the editor" bug. See Phase 3b §E.
        .background(
            VStack(spacing: 0) {
                Button("Settings") { isShowingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        )
    }

    private func handleQuickCaptureOnLaunch() {
        if deepLink.pendingQuickCapture {
            deepLink.pendingQuickCapture = false
            viewModel.createUntitledNotebookAndOpen()
        }
    }

    // MARK: Action strip (replaces the system nav bar)

    private var actionStrip: some View {
        HStack(spacing: 0) {
            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.inkRecessiveTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")

            Menu {
                Button {
                    isShowingRecentExports = true
                } label: {
                    Label("Recent Exports", systemImage: "doc.richtext")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.inkRecessiveTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
    }
}
