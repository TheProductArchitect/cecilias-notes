import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import CoreSpotlight

struct MacRootView: View {
    @Binding var showOnboarding: Bool
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var storageService: StorageService
    @EnvironmentObject private var cloudSync: CloudSyncManager
    @EnvironmentObject private var deepLink: DeepLinkRouter
    @EnvironmentObject private var libraryVM: LibraryViewModel

    @State private var isSidebarVisible = true
    @State private var isCommandPalettePresented = false
    @State private var isLibraryFocusMode = false
    @State private var isShowingRecentExports = false
    @State private var importFeedback: MacImportFeedback?
    @State private var isICloudBannerDismissed = UserDefaults.standard
        .bool(forKey: "ceciliasnotes.mac.icloudBannerDismissed")

    var body: some View {
        macRootObservers(
            macRootSheets(macRootCore)
        )
    }

    private var macRootCore: some View {
        Group {
            if let inlineID = libraryVM.macInlineNotebookId {
                MacNotebookEditorWindow(notebookID: inlineID) {
                    libraryVM.macInlineNotebookId = nil
                }
                .onAppear { MacEditorPresentation.isInlineActive = true }
                .onDisappear { MacEditorPresentation.isInlineActive = false }
            } else {
                libraryShell
            }
        }
        .background(theme.background)
        .onDrop(of: [.fileURL, .pdf], isTargeted: nil) { providers in
            handleLibraryDrop(providers)
        }
    }

    private var libraryShell: some View {
        VStack(spacing: 0) {
            if showsICloudUnavailableBanner {
                macICloudUnavailableBanner
            }
            if !isLibraryFocusMode {
                LibraryHeaderView(
                    viewModel: libraryVM,
                    isShowingRecentExports: $isShowingRecentExports
                )
            }
            HStack(spacing: 0) {
                if isSidebarVisible, !isLibraryFocusMode {
                    SubjectSidebarView(viewModel: libraryVM)
                        .frame(width: 240)
                        .background(theme.surface)
                }
                libraryContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func macRootSheets<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $showOnboarding) {
                MacOnboardingView(isPresented: $showOnboarding)
                    .environment(\.theme, theme)
            }
            .onReceive(NotificationCenter.default.publisher(for: .macShowOnboarding)) { _ in
                showOnboarding = true
            }
            .sheet(isPresented: $isCommandPalettePresented) {
                MacCommandPaletteView(libraryVM: libraryVM)
                    .environment(\.theme, theme)
            }
            .sheet(isPresented: $libraryVM.isShowingQuizBuilder) {
                QuizBuilderView(viewModel: libraryVM)
                    .environment(\.theme, theme)
                    .frame(minWidth: 520, minHeight: 560)
            }
            .sheet(isPresented: $isShowingRecentExports) {
                MacRecentExportsView()
                    .environment(\.theme, theme)
                    .frame(minWidth: 420, minHeight: 360)
            }
            .alert(item: $importFeedback) { feedback in
                Alert(
                    title: Text(feedback.title),
                    message: Text(feedback.message),
                    dismissButton: .default(Text("OK"))
                )
            }
    }

    @ViewBuilder
    private func macRootObservers<Content: View>(_ content: Content) -> some View {
        macRootMenuObservers(
            macRootDeepLinkObservers(content)
        )
    }

    @ViewBuilder
    private func macRootDeepLinkObservers<Content: View>(_ content: Content) -> some View {
        content
            .onAppear(perform: macRootOnAppear)
            .onChange(of: libraryVM.selectedNotebookId, perform: handleSelectedNotebookChange)
            .onChange(of: libraryVM.macOpenInNewWindowId) { _, id in
                guard let id else { return }
                MacStateUpdates.deferred {
                    openNotebookWindow(id: id)
                    libraryVM.macOpenInNewWindowId = nil
                }
            }
            .onChange(of: libraryVM.pendingExportNotebookId) { _, id in
                guard let id else { return }
                MacStateUpdates.deferred {
                    libraryVM.pendingExportNotebookId = nil
                    deepLink.pendingExport = true
                    libraryVM.selectedNotebookId = id
                }
            }
            .onChange(of: deepLink.openNotebookId, perform: handleDeepLinkNotebook)
            .onChange(of: deepLink.openSettings, perform: handleDeepLinkSettings)
            .onChange(of: deepLink.forceLibraryHome, perform: handleForceLibraryHome)
            .onChange(of: deepLink.pendingQuickCapture, perform: handlePendingQuickCapture)
            .onReceive(NotificationCenter.default.publisher(for: .macIncomingDeepLinkURL)) { note in
                guard let url = note.userInfo?["url"] as? URL else { return }
                MacStateUpdates.deferred {
                    NSApp.activate(ignoringOtherApps: true)
                    deepLink.handle(url)
                }
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                MacStateUpdates.deferred {
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                          let uuid = SpotlightService.notebookId(fromIdentifier: id) else { return }
                    libraryVM.selectedNotebookId = uuid
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macOpenHandoffPage)) { note in
                MacStateUpdates.deferred {
                    guard let notebookID = note.userInfo?[MacHandoff.notebookIdKey] as? UUID else { return }
                    if let pageId = note.userInfo?[MacHandoff.pageIdKey] as? UUID {
                        libraryVM.deepLinkPageId = pageId
                    }
                    openNotebookInline(id: notebookID)
                }
            }
    }

    @ViewBuilder
    private func macRootMenuObservers<Content: View>(_ content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .macToggleSidebar)) { _ in
                MacStateUpdates.deferred { isSidebarVisible.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macToggleFocusMode)) { _ in
                MacStateUpdates.deferred {
                    guard !MacWindowFocus.isNotebookEditorKey else { return }
                    withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                        isLibraryFocusMode.toggle()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macOpenSearch)) { _ in
                MacStateUpdates.deferred {
                    withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                        libraryVM.isSearchActive = true
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macGenerateQuiz)) { note in
                MacStateUpdates.deferred {
                    guard !MacWindowFocus.isNotebookEditorKey else { return }
                    if let id = note.userInfo?[CeciliasNotesIntentKeys.notebookId] as? UUID {
                        libraryVM.quizBuilderPreselectedNotebookID = id
                    }
                    libraryVM.isShowingQuizBuilder = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macOpenCommandPalette)) { _ in
                MacStateUpdates.deferred { isCommandPalettePresented = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macOpenNotebook)) { note in
                MacStateUpdates.deferred {
                    guard let id = note.userInfo?[MacHandoff.notebookIdKey] as? UUID else { return }
                    libraryVM.selectedNotebookId = id
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macInsertText)) { _ in
                MacStateUpdates.deferred {
                    if MacWindowFocus.isNotebookEditorKey {
                        NotificationCenter.default.post(name: .macInsertTextOnPage, object: nil)
                        return
                    }
                    guard let id = MacMenuState.shared.recentNotebooks.first?.id else {
                        NSSound.beep()
                        return
                    }
                    libraryVM.selectedNotebookId = id
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        NotificationCenter.default.post(name: .macInsertTextOnPage, object: nil)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macNewNotebook)) { _ in
                MacStateUpdates.deferred { libraryVM.createNotebookWithFallback() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macNewFromTemplate)) { note in
                MacStateUpdates.deferred {
                    guard let raw = note.userInfo?[MacTemplateHandoff.templateKey] as? String,
                          let template = MacNotebookTemplate(rawValue: raw) else { return }
                    _ = MacNotebookTemplate.create(template, libraryVM: libraryVM, storage: storageService)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macNewSubject)) { _ in
                MacStateUpdates.deferred {
                    libraryVM.createSubject()
                    MacMenuState.shared.refresh()
                }
            }
    }

    private func openNotebookWindow(id: UUID) {
        openWindow(id: "notebook-editor", value: id)
        RecentNotebooksTracker.markOpened(id)
        MacMenuState.shared.refresh()
    }

    private func openNotebookInline(id: UUID) {
        guard libraryVM.notebook(id: id) != nil else { return }
        libraryVM.macInlineNotebookId = id
        RecentNotebooksTracker.markOpened(id)
        MacMenuState.shared.refresh()
        libraryVM.selectedNotebookId = nil
    }

    private func macRootOnAppear() {
        MacStateUpdates.deferred {
            reconcileAppIcon()
            MacMenuState.shared.refresh()
            storageService.purgeDuplicateRows()
            storageService.reconcileSoftDeleteFlags()
            libraryVM.refresh()
            Task {
                await SearchIndexService.shared.loadAsync()
                SearchIndexService.shared.refreshAll()
            }
            if let pendingNotebookId = deepLink.openNotebookId {
                routeDeepLinkNotebook(pendingNotebookId)
            } else if deepLink.pendingQuickCapture {
                handlePendingQuickCapture(true)
            }
            // Mac home is the library window. Resume state (last notebook /
            // page) is restored when the user opens a notebook from the
            // grid or Recents — see `MacNotebookEditorWindow`.
        }
    }

    private func handleSelectedNotebookChange(_ id: UUID?) {
        MacStateUpdates.deferred {
            guard let id, libraryVM.notebook(id: id) != nil else { return }
            openNotebookInline(id: id)
            // `deepLinkPageId` is consumed by `MacNotebookEditorWindow`
            // on appear so search hits land on the right page even when
            // the inline editor wasn't mounted yet.
        }
    }

    private func handleDeepLinkNotebook(_ id: UUID?) {
        guard let id else { return }
        MacStateUpdates.deferred {
            NSApp.activate(ignoringOtherApps: true)
            routeDeepLinkNotebook(id)
        }
    }

    /// Opens a notebook from a widget / URL scheme. Retries briefly when
    /// SwiftData hasn't finished loading the library yet (cold launch).
    private func routeDeepLinkNotebook(_ id: UUID, attempt: Int = 0) {
        if libraryVM.notebook(id: id) == nil {
            libraryVM.refresh()
        }
        guard libraryVM.notebook(id: id) != nil else {
            guard attempt < 8 else {
                deepLink.openNotebookId = nil
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                routeDeepLinkNotebook(id, attempt: attempt + 1)
            }
            return
        }
        if let pageId = deepLink.openPageId {
            libraryVM.deepLinkPageId = pageId
            deepLink.openPageId = nil
        }
        deepLink.openNotebookId = nil
        RecentNotebooksTracker.markOpened(id)
        libraryVM.selectedNotebookId = id
    }

    private func handleDeepLinkSettings(_ open: Bool) {
        guard open else { return }
        MacStateUpdates.deferred {
            deepLink.openSettings = false
            NotificationCenter.default.post(name: .macOpenSettings, object: nil)
        }
    }

    private func handleForceLibraryHome(_ flag: Bool) {
        guard flag else { return }
        MacStateUpdates.deferred {
            deepLink.forceLibraryHome = false
            deepLink.openNotebookId = nil
            deepLink.openPageId = nil
            libraryVM.selectedNotebookId = nil
            libraryVM.macInlineNotebookId = nil
            NSApp.activate(ignoringOtherApps: true)
            let libraryWindow = NSApp.windows.first { window in
                window.canBecomeMain && window.identifier?.rawValue == "library-main"
            } ?? NSApp.windows.first { $0.canBecomeMain }
            libraryWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func handlePendingQuickCapture(_ pending: Bool) {
        guard pending else { return }
        MacStateUpdates.deferred {
            deepLink.pendingQuickCapture = false
            NSApp.activate(ignoringOtherApps: true)
            libraryVM.createUntitledNotebookAndOpen()
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if libraryVM.isShowingTrash {
            TrashView(viewModel: libraryVM)
        } else if libraryVM.selectedContext == .allSubjects {
            AllSubjectsView(viewModel: libraryVM)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if libraryVM.selectedContext == .allQuizzes {
            AllQuizzesView(viewModel: libraryVM)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if libraryVM.selectedQuizID != nil, let quizID = libraryVM.selectedQuizID {
            QuizDetailView(quizID: quizID, viewModel: libraryVM)
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
                                let (notebookId, pages) = await MacPDFImport.importFromDrop(
                                    url: url,
                                    subjectId: libraryVM.selectedContext.subjectId,
                                    storage: storageService
                                )
                                MacStateUpdates.deferred {
                                    libraryVM.refresh()
                                    if let notebookId, pages > 0 {
                                        libraryVM.selectedNotebookId = notebookId
                                        importFeedback = MacImportFeedback(
                                            title: "Notebook created",
                                            message: "Imported \(pages) page\(pages == 1 ? "" : "s") from \(url.lastPathComponent). Text-based PDFs are editable; scanned PDFs appear as page images."
                                        )
                                    } else {
                                        importFeedback = MacImportFeedback(
                                            title: "Import failed",
                                            message: "Could not import \(url.lastPathComponent). The file may be empty or protected."
                                        )
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

    private var showsICloudUnavailableBanner: Bool {
        CloudKitContainerState.status == .localOnlyFallback && !isICloudBannerDismissed
    }

    private var macICloudUnavailableBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 13, weight: .medium))
                .accessibilityHidden(true)

            Text("iCloud sync paused — notes from other devices won't appear until you restore sync.")
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Settings") {
                NotificationCenter.default.post(name: .macOpenSettings, object: nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))

            Button {
                withAnimation {
                    isICloudBannerDismissed = true
                    UserDefaults.standard.set(true, forKey: "ceciliasnotes.mac.icloudBannerDismissed")
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(theme.foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.danger.opacity(0.4), lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

extension Notification.Name {
    static let macCreateNotebook = Notification.Name("app.ceciliasnotes.mac.createNotebook")
    static let macShowOnboarding = Notification.Name("app.ceciliasnotes.mac.showOnboarding")
    static let macInsertTextOnPage = Notification.Name("app.ceciliasnotes.mac.insertTextOnPage")
}
