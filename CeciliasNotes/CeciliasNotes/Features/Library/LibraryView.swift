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
    /// collapsed. iPhone uses a separate key so the iPad default
    /// (visible) doesn't push a cramped 240pt sidebar onto a 390pt
    /// screen.
    @AppStorage("library.sidebar.visible") private var isSidebarVisibleTablet: Bool = true
    @AppStorage("library.sidebar.visible.phone") private var isSidebarVisiblePhone: Bool = false

    private var isSidebarVisible: Bool {
        get { DeviceCapabilities.prefersTabletLayout ? isSidebarVisibleTablet : isSidebarVisiblePhone }
    }
    private func setSidebarVisible(_ value: Bool) {
        if DeviceCapabilities.prefersTabletLayout { isSidebarVisibleTablet = value }
        else { isSidebarVisiblePhone = value }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme

    /// The notebook currently being edited (if any). Drives the full-screen Editor cover.
    @State private var editingNotebook: Notebook?

    @State private var isShowingRecentExports = false
    @State private var isShowingSettings      = false
    @State private var isICloudBannerDismissed  = false
    @State private var reExportNotebookId: UUID?
    /// PDF from the share extension's inbox, presented through the
    /// shared `PDFPagePickerSheet` in library mode. Wrapped in an
    /// Identifiable so SwiftUI's `.sheet(item:)` can drive
    /// presentation/dismissal off it.
    @State private var sharedPDFURL: SharedPDFURL?
    /// Image from the share extension's inbox. Same lifecycle as
    /// `sharedPDFURL`; presented through `ShareImagePickerSheet`.
    @State private var sharedImageURL: SharedImageURL?
    /// Holding pens for inbox arrivals that came in while the editor
    /// cover was up. iPadOS can't present a `.sheet` and a
    /// `.fullScreenCover` from the same view at the same time —
    /// trying it locks the entire presentation stack and silently
    /// kills the touch system. We stash the URL here instead, then
    /// flush it as soon as the cover dismisses.
    @State private var pendingSharedPDFURL: SharedPDFURL?
    @State private var pendingSharedImageURL: SharedImageURL?

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
                dlog("[ImageInsert] 4. LibraryView.onAppear — cover dismissed, library is back on top (editingNotebook=\(editingNotebook?.id.uuidString ?? "nil"))")
                #endif
                // Drain any icon update queued during onboarding completion.
                // Idempotent + self-healing: no-ops when the icon
                // already matches the user's name, retries a swap
                // that lost the iOS 26 race on an earlier pass. See
                // the "Icon switching" section in PersonalIdentity.swift.
                reconcileAppIcon()
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
                if let pageId = deepLink.openPageId {
                    viewModel.deepLinkPageId = pageId
                    deepLink.openPageId = nil
                }
                DispatchQueue.main.async { deepLink.openNotebookId = nil }
                editingNotebook = notebook
            }
            // Step 6: tap on the persistent RecordingPill (from
            // anywhere in the app) routes through the deep-link
            // router so the editor re-presents on the recording's
            // notebook. No-op if the editor is already on screen.
            .onReceive(
                NotificationCenter.default.publisher(for: .recordingPillReturnTapped)
            ) { note in
                guard let id = note.userInfo?["notebookId"] as? UUID else { return }
                // Pass through the recording's current page id so
                // the editor scrolls to where dictation is actually
                // writing — otherwise the user lands on the
                // notebook's first page and has to hunt for the
                // live transcript.
                let pageId = note.userInfo?["pageId"] as? UUID
                DispatchQueue.main.async {
                    viewModel.deepLinkPageId = pageId
                    deepLink.openNotebookId = id
                }
            }
            .onChange(of: deepLink.openSettings) { _, open in
                guard open else { return }
                DispatchQueue.main.async { deepLink.openSettings = false }
                isShowingSettings = true
            }
            // `ceciliasnotes://library` (used by the share extension's
            // deep link) forces the editor cover down so the user
            // lands on the home surface. The share-inbox watcher's
            // notification then presents the import picker on top
            // of library — not on top of whatever notebook happened
            // to be open when the share was triggered.
            .onChange(of: deepLink.forceLibraryHome) { _, flag in
                guard flag else { return }
                DispatchQueue.main.async { deepLink.forceLibraryHome = false }
                if editingNotebook != nil {
                    editingNotebook = nil
                }
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
            .onReceive(NotificationCenter.default.publisher(for: .ceciliasNotesCommandNewNotebook)) { _ in
                guard viewModel.selectedSubjectId != nil else { return }
                Task { @MainActor in viewModel.createUntitledNotebookAndOpen() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ceciliasNotesCommandSearch)) { _ in
                Task { @MainActor in
                    withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) { viewModel.isSearchActive = true }
                }
            }
            .onChange(of: deepLink.pendingQuickCapture) { _, pending in
                guard pending else { return }
                DispatchQueue.main.async { deepLink.pendingQuickCapture = false }
                viewModel.createUntitledNotebookAndOpen()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ceciliasNotesQuickCapture)) { _ in
                Task { @MainActor in
                    deepLink.pendingQuickCapture = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ceciliasNotesOpenNotebook)) { note in
                guard let id = note.userInfo?[CeciliasNotesIntentKeys.notebookId] as? UUID else { return }
                Task { @MainActor in deepLink.openNotebookId = id }
            }
            .task { handleQuickCaptureOnLaunch() }
    }

    private var contentLayer: some View {
        VStack(spacing: 0) {
            actionStrip
            if let message = viewModel.error?.errorDescription {
                MediaErrorBanner(message: message) { viewModel.error = nil }
                    .padding(.horizontal, CeciliasNotes.Spacing.md)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if showsICloudUnavailableBanner {
                iCloudUnavailableBanner
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            LibraryHeaderView(viewModel: viewModel)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if isSidebarVisible && DeviceCapabilities.prefersTabletLayout {
                        SubjectSidebarView(viewModel: viewModel)
                            .frame(width: Self.sidebarWidth)
                            .background(theme.surface)
                            .transition(.move(edge: .leading))
                    }
                    if viewModel.isShowingTrash {
                        TrashView(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let quizID = viewModel.selectedQuizID {
                        QuizDetailView(quizID: quizID, viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if viewModel.selectedContext == .allSubjects {
                        AllSubjectsView(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if viewModel.selectedContext == .allQuizzes {
                        AllQuizzesView(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        NotebookGridView(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                // iPhone: sidebar as a drawer overlay. Tapping the
                // dimmed content area closes it; on iPad we never hit
                // this branch (sidebar is inline above).
                if isSidebarVisible && !DeviceCapabilities.prefersTabletLayout {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .onTapGesture { setSidebarVisible(false) }
                        .transition(.opacity)
                    SubjectSidebarView(viewModel: viewModel)
                        .frame(width: min(280, Self.sidebarWidth))
                        .background(theme.surface)
                        .shadow(color: .black.opacity(0.18), radius: 16, x: 2, y: 0)
                        .transition(.move(edge: .leading))
                }
            }
        }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    // Tap on empty library chrome returns the UI to
                    // its resting state — drop the keyboard, and
                    // collapse an active search.
                    if keyboardObserver.isKeyboardVisible {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                    if viewModel.isSearchActive {
                        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                            viewModel.deactivateSearch()
                        }
                    }
                }
        )
        .overlay(alignment: .bottom) {
            if viewModel.isImporting {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("importing \(viewModel.importProgressCompleted) of \(viewModel.importProgressTotal) PDF\(viewModel.importProgressTotal == 1 ? "" : "s")…")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.recessivePrimary)
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
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: viewModel.isImporting)
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
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: viewModel.error)
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: showsICloudUnavailableBanner)
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.container, edges: .bottom)
        // Always ignore the keyboard's safe-area inset. The library
        // has no text fields whose visibility depends on
        // keyboard-avoiding reflow (the only typing surface — the
        // subject rename — lives in the sidebar, which already
        // ignores). The previous conditional `.isFloatingKeyboard ?
        // .bottom : []` lost the race against `KeyboardObserver`'s
        // `Task { @MainActor }` defer: SwiftUI had already reflowed
        // around the docked-keyboard height (leaving a white band
        // sized to the full keyboard) by the time `isFloatingKeyboard`
        // became true. Unconditional ignore matches what the editor
        // does and removes that reservation entirely.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(reduceMotion ? nil : .ceciliasNotesSpring(CeciliasNotesSpring.snappy), value: isSidebarVisible)
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
        .sheet(isPresented: $viewModel.isShowingQuizBuilder) {
            QuizBuilderView(viewModel: viewModel)
        }
        // Share-inbox PDF picker. Lives at the library level (above
        // the editor cover) so a PDF arriving from outside the app
        // can be filed into a brand-new notebook or appended to an
        // existing one without the user needing to be inside an
        // editor first.
        .sheet(item: $sharedPDFURL) { wrapper in
            PDFPagePickerSheet(
                sourceURL: wrapper.url,
                onConfirm: { indices, destination in
                    let url = wrapper.url
                    sharedPDFURL = nil
                    Task { @MainActor in
                        if let nbId = await PDFReferenceImporter
                            .importPagesFromLibrary(
                                from: url,
                                pageIndices: indices,
                                destination: destination
                            ) {
                            ShareInboxWatcher.shared.consume(url)
                            viewModel.refresh()
                            if let notebook = viewModel.notebook(id: nbId) {
                                // Wait one runloop tick before swapping
                                // the cover so the picker sheet has fully
                                // dismissed first. Presenting the editor
                                // cover while a sheet is still dismissing
                                // races UIKit's window-level gesture state
                                // and freezes touch on the whole app.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    editingNotebook = notebook
                                }
                            }
                        }
                    }
                },
                onCancel: {
                    // Consume on cancel too — leaving the file in
                    // the inbox made it pop up again on every
                    // foreground sweep, which read as "the app
                    // keeps nagging me about a PDF I already
                    // dismissed." If the user wants to import it
                    // they can re-share from the source app.
                    let url = wrapper.url
                    sharedPDFURL = nil
                    ShareInboxWatcher.shared.consume(url)
                },
                mode: .library(
                    subjects: viewModel.subjects,
                    notebooks: viewModel.notebooks
                )
            )
        }
        // Share-inbox image picker. Smaller than the PDF picker —
        // no page selection step — but the same destination chooser
        // (new notebook + subject / existing notebook).
        .sheet(item: $sharedImageURL) { wrapper in
            ShareImagePickerSheet(
                sourceURL: wrapper.url,
                subjects: viewModel.subjects,
                notebooks: viewModel.notebooks,
                onConfirm: { destination in
                    let url = wrapper.url
                    sharedImageURL = nil
                    Task { @MainActor in
                        if let nbId = await ShareImageImporter.importImage(
                            from: url,
                            destination: destination
                        ) {
                            ShareInboxWatcher.shared.consume(url)
                            viewModel.refresh()
                            if let notebook = viewModel.notebook(id: nbId) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    editingNotebook = notebook
                                }
                            }
                        }
                    }
                },
                onCancel: {
                    let url = wrapper.url
                    sharedImageURL = nil
                    ShareInboxWatcher.shared.consume(url)
                }
            )
        }
        .onChange(of: reExportNotebookId) { _, id in
            guard let id, let notebook = viewModel.notebook(id: id) else { return }
            DispatchQueue.main.async { reExportNotebookId = nil }
            editingNotebook = notebook
        }
        .onChange(of: viewModel.selectedNotebookId) { _, id in
            #if DEBUG
            dlog("[Library] onChange(selectedNotebookId) → \(id?.uuidString ?? "nil")")
            #endif
            guard let id, let notebook = viewModel.notebook(id: id) else {
                #if DEBUG
                if id != nil { dlog("[Library] notebook(id:) returned nil — id stale?") }
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
        // PDF import "new notebook" destination posts this from
        // inside the editor cover. Flipping `editingNotebook` to
        // the freshly-created notebook reads as a single binding
        // swap to SwiftUI — the cover content replaces in one
        // transition rather than dismissing back to the library
        // and re-presenting.
        .onReceive(
            NotificationCenter.default.publisher(
                for: PDFReferenceImporter.requestSwitchNotebookNotification
            )
        ) { note in
            guard
                let id = note.userInfo?["notebookId"] as? UUID
            else { return }
            Task { @MainActor in
                viewModel.refresh()
                if let notebook = viewModel.notebook(id: id) {
                    editingNotebook = notebook
                }
            }
        }
        // Share extension dropped a PDF in the app-group inbox.
        // Present the PDF page picker in library mode so the user
        // can pick pages, a destination notebook (new or existing),
        // and a subject (for new). This mirrors the in-editor PDF
        // import workflow — same picker UI, same selection model,
        // just different destination chips.
        .onReceive(
            NotificationCenter.default.publisher(for: .shareInboxPDFArrived)
        ) { note in
            guard let url = note.userInfo?["fileURL"] as? URL else { return }
            // If the editor cover is up, force-dismiss it back to the
            // library so the import picker sits on the home surface
            // instead of stranding the user inside whatever notebook
            // they last had open. The pending stash is drained by
            // the `.onChange(of: editingNotebook)` handler below once
            // the cover finishes dismissing.
            if editingNotebook == nil {
                sharedPDFURL = SharedPDFURL(url: url)
            } else {
                pendingSharedPDFURL = SharedPDFURL(url: url)
                editingNotebook = nil
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .shareInboxImageArrived)
        ) { note in
            guard let url = note.userInfo?["fileURL"] as? URL else { return }
            if editingNotebook == nil {
                sharedImageURL = SharedImageURL(url: url)
            } else {
                pendingSharedImageURL = SharedImageURL(url: url)
                editingNotebook = nil
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .shareInboxCaptureArrived)
        ) { note in
            guard let url = note.userInfo?["fileURL"] as? URL else { return }
            ingestShareCaptureFile(url)
        }
        // When the editor cover dismisses, drain any inbox arrival
        // that came in while it was up. One runloop tick of slack so
        // SwiftUI finishes the cover's dismiss transition before we
        // ask it to present a sheet.
        .onChange(of: editingNotebook) { _, new in
            guard new == nil else { return }
            DispatchQueue.main.async {
                if let pending = pendingSharedPDFURL {
                    pendingSharedPDFURL = nil
                    sharedPDFURL = pending
                } else if let pending = pendingSharedImageURL {
                    pendingSharedImageURL = nil
                    sharedImageURL = pending
                }
            }
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

    /// Identifiable URL wrapper so the share-inbox PDF can drive a
    /// `.sheet(item:)` binding. Equality is by URL path so a second
    /// arrival with the same path doesn't immediately re-present
    /// after dismiss.
    private struct SharedPDFURL: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    /// Same shape as `SharedPDFURL`, separate type so the two
    /// `.sheet(item:)` bindings stay independent.
    private struct SharedImageURL: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private func handleQuickCaptureOnLaunch() {
        if deepLink.pendingQuickCapture {
            deepLink.pendingQuickCapture = false
            viewModel.createUntitledNotebookAndOpen()
        }
    }

    private func ingestShareCaptureFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(ShareCapturePayload.self, from: data),
              let notebookId = QuickCaptureSave.save(title: payload.title, body: payload.body)
        else { return }
        ShareInboxWatcher.shared.consume(url)
        viewModel.refresh()
        if let notebook = viewModel.notebook(id: notebookId) {
            if editingNotebook == nil {
                editingNotebook = notebook
            } else {
                editingNotebook = nil
                DispatchQueue.main.async {
                    self.editingNotebook = notebook
                }
            }
        }
    }

    // MARK: iCloud unavailable banner

    private var showsICloudUnavailableBanner: Bool {
        CloudKitContainerState.status == .localOnlyFallback && !isICloudBannerDismissed
    }

    /// User-visible explanation when the SwiftData CloudKit container
    /// failed to come up and the app is running on its local-only
    /// fallback. Sits *below* the action strip so the settings gear
    /// stays tappable — the old top overlay covered the whole strip.
    private var iCloudUnavailableBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 13, weight: .medium))
                .accessibilityHidden(true)

            Text("iCloud sync off — notes from other devices won't appear here.")
                .font(.system(size: 12, weight: .regular))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                isShowingSettings = true
            } label: {
                Text("settings")
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.lowercase)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open settings")

            Button {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                    isICloudBannerDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.recessiveTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss iCloud sync notice")
        }
        .foregroundStyle(theme.foreground)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.danger.opacity(0.4), lineWidth: 1)
                )
        )
        .padding(.horizontal, CeciliasNotes.Spacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("iCloud sync unavailable. Notes from other devices won't appear here.")
    }

    // MARK: Action strip (replaces the system nav bar)

    private var actionStrip: some View {
        HStack(spacing: 0) {
            // iPhone-only: hamburger to summon the sidebar drawer.
            // iPad keeps the always-on sidebar so it doesn't need one.
            if !DeviceCapabilities.prefersTabletLayout {
                Button {
                    withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                        setSidebarVisible(!isSidebarVisible)
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(theme.recessiveTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
            }

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(theme.recessiveTertiary)
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
                    .foregroundStyle(theme.recessiveTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
    }
}
