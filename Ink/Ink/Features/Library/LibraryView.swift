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

    private static let sidebarWidth: CGFloat = 240

    // Onboarding routing now lives in `RootView` (the launch
    // coordinator) — when this view mounts the user is guaranteed to
    // have either completed onboarding or skipped it via a route
    // outside the Library's control. No onboarding cover here.

    var body: some View {
        // Three-band home: action strip across the top, masthead full
        // width below, then a sidebar + grid HStack underneath. Puts
        // identity (date eyebrow + wordmark + bottom rule) in the top
        // zone, with subjects and notebooks in a balanced split below.
        // Earlier the sidebar started at the masthead's top edge,
        // burying SUBJECTS under the wordmark.
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
        // Tap anywhere outside an active inline title edit (or
        // search field) to commit and dismiss the keyboard. Sits on
        // the background layer so cards, sidebar rows and buttons
        // still claim their own taps; only "empty" hits land here.
        // Gated on keyboard visibility so we don't intercept stray
        // taps when nothing is being edited.
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
            // Error banner — slides from top when a storage mutation
            // fails. Sits above everything so it's always
            // attention-grabbing.
            if let message = viewModel.error?.errorDescription {
                MediaErrorBanner(message: message) {
                    viewModel.error = nil
                }
                .padding(.top, Ink.Spacing.md)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(99)
            }
        }
        .overlay(alignment: .bottom) {
            // PDF batch import progress — small capsule toast so the
            // user sees "3 of 7" rather than a frozen-looking library
            // while a multi-PDF import runs.
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
        .animation(.inkSpring(InkSpring.smooth), value: viewModel.isImporting)
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
        .animation(.inkSpring(InkSpring.smooth), value: viewModel.error)
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.container, edges: .bottom)
        // Floating keyboards on iPad are narrow (~370pt) and don't
        // occupy a full-width band at the bottom — letting SwiftUI
        // reflow the layout to "avoid" them looks broken (the sidebar
        // buttons jump up). Opt out of keyboard-driven safe-area inset
        // exactly when the floating keyboard is up; docked/split
        // keyboards keep the default avoidance.
        .ignoresSafeArea(
            .keyboard,
            edges: keyboardObserver.isFloatingKeyboard ? .bottom : []
        )
        .animation(reduceMotion ? nil : .inkSpring(InkSpring.snappy), value: isSidebarVisible)
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
        .onChange(of: reExportNotebookId) { _, id in
            guard let id, let notebook = viewModel.notebook(id: id) else { return }
            DispatchQueue.main.async { reExportNotebookId = nil }
            editingNotebook = notebook
        }
        .onChange(of: viewModel.selectedNotebookId) { _, id in
            guard let id, let notebook = viewModel.notebook(id: id) else { return }
            editingNotebook = notebook
        }
        .onChange(of: viewModel.pendingOpenAfterImport) { _, nb in
            // Single-PDF import auto-opens the new notebook. Multi-PDF
            // import leaves the user in the library with the batch
            // visible — `pendingOpenAfterImport` stays nil in that case.
            guard let nb else { return }
            viewModel.pendingOpenAfterImport = nil
            editingNotebook = nb
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
        .fullScreenCover(item: $editingNotebook) { notebook in
            EditorView(
                notebook: notebook,
                deepLinkPageId: viewModel.deepLinkPageId,
                onDismiss: {
                    editingNotebook = nil
                    viewModel.selectedNotebookId = nil
                    viewModel.deepLinkPageId = nil
                    viewModel.refresh()       // pull updated thumbnails / titles
                }
            )
        }
        // Real keyboard shortcuts — settings ⌘, , new notebook ⌘N etc
        // come through the .commands modifier on the WindowGroup
        // (see InkCommands). The ⌘, settings shortcut stays here
        // because Apple reserves ⌘, for app preferences and the
        // .commands menu structure can't slot it cleanly.
        .background(
            VStack(spacing: 0) {
                Button("Settings") { isShowingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        )
        // Refresh on app foreground — covers cross-session writes
        // (notebooks created in another window, future iCloud sync
        // arriving while backgrounded) without waiting for the next
        // user-driven create/delete to trigger refresh.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            viewModel.refresh()
        }
        // Tag filter is session-only — drop it whenever the app
        // goes into the background so a fresh foreground starts
        // unfiltered.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            viewModel.clearTagFilters()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkCommandNewNotebook)) { _ in
            guard viewModel.selectedSubjectId != nil else { return }
            viewModel.createUntitledNotebookAndOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkCommandSearch)) { _ in
            withAnimation(.inkSpring(InkSpring.smooth)) {
                viewModel.isSearchActive = true
            }
        }
        .onChange(of: deepLink.pendingQuickCapture) { _, pending in
            guard pending else { return }
            DispatchQueue.main.async { deepLink.pendingQuickCapture = false }
            viewModel.createUntitledNotebookAndOpen()
        }
        .task {
            if deepLink.pendingQuickCapture {
                deepLink.pendingQuickCapture = false
                viewModel.createUntitledNotebookAndOpen()
            }
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
