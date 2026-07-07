import PencilKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
import AppKit

struct MacEditorView: View {
    let notebook: Notebook
    @ObservedObject var state: MacLibraryState
    @ObservedObject var libraryVM: LibraryViewModel
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storageService: StorageService
    @EnvironmentObject private var deepLink: DeepLinkRouter

    @Query private var pages: [Page]
    @StateObject private var richTextController = MacRichTextController()
    @State private var isShowingSummarize = false
    @State private var isShowingAskAboutPage = false
    @State private var isShowingPageTemplate = false
    @State private var isShowingInNotebookSearch = false
    @State private var isShowingPageOrder = false
    @State private var isShowingNotebookInfo = false
    @State private var isShowingQuizBuilder = false
    @State private var editingStickyElement: PageElement?
    @State private var transcriptionErrorMessage: String?
    @State private var importFeedback: MacImportFeedback?
    @ObservedObject private var recordingSession = MacRecordingSession.shared

    var onClose: (() -> Void)? = nil

    /// CloudKit can echo duplicate `Page` rows before the store sweep
    /// converges — dedupe before any `ForEach` sees them.
    private var displayPages: [Page] {
        pages.dedupedById()
    }

    init(
        notebook: Notebook,
        state: MacLibraryState,
        libraryVM: LibraryViewModel,
        onClose: (() -> Void)? = nil
    ) {
        self.notebook = notebook
        self.state = state
        self.libraryVM = libraryVM
        self.onClose = onClose
        let notebookID = notebook.id
        _pages = Query(
            filter: #Predicate<Page> { page in
                page.notebookId == notebookID && !page.isDeleted
            },
            sort: \Page.pageNumber
        )
    }

    var body: some View {
        attachEditorNotifications(attachEditorSheets(editorMain))
    }

    private var editorMain: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                editorTopChrome
                MacDocModeView(
                    notebook: notebook,
                    pages: displayPages,
                    selectedPageID: pageSelection,
                    editingBlockID: $state.editingBlockID,
                    selectedElementID: $state.selectedElementID,
                    editorScrollOffset: $state.editorScrollOffset,
                    pendingHandoffScrollOffset: $state.pendingHandoffScrollOffset,
                    editorZoom: state.editorZoom,
                    topChromeInset: documentTopInset,
                    onWritingBegan: { state.notifyHeaderWritingBegan(notebook: notebook) }
                )
                .environmentObject(storageService)
                .environmentObject(richTextController)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if state.isCustomisePanelOpen {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.closeCustomisePanel(notebook: notebook)
                    }
                    .zIndex(73)

                HStack(spacing: 0) {
                    MacCustomisePanel(
                        notebook: notebook,
                        state: state,
                        libraryVM: libraryVM
                    )
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(85)
            }

        }
        .navigationTitle("")
        .background(MacWindowChromeFix())
        .accessibilityLabel(A11y.notebookLabel(
            title: notebook.title,
            subjectName: nil,
            pageCount: displayPages.count,
            modified: notebook.updatedAt
        ))
        .background(theme.background)
        .onAppear {
            MacStateUpdates.deferred {
                if state.selectedPageID == nil {
                    state.selectedPageID = displayPages.first?.id
                }
                publishHandoff()
            }
        }
        .onChange(of: state.selectedPageID) { _, _ in
            MacStateUpdates.deferred { publishHandoff() }
        }
        .onChange(of: state.editorZoom) { _, _ in
            MacStateUpdates.deferred { publishHandoff() }
        }
        .onChange(of: state.editingBlockID) { _, blockID in
            if blockID == nil { richTextController.detach() }
        }
        .onDisappear {
            richTextController.detach()
            publishHandoff()
        }
        .onDrop(of: [.fileURL, .image, .pdf], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var editorTopChrome: some View {
        VStack(spacing: 0) {
            if !state.isFocusMode, !state.headerVisibility.isHeaderVisible {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(notebook.coverTone.background)
                        .frame(height: 3)
                    MacHeaderRevealOverlay(tone: notebook.coverTone) {
                        state.revealHeaderManually()
                    }
                }
            }

            if !state.isFocusMode, state.headerVisibility.isHeaderVisible {
                MacEditorHeaderView(
                    notebook: notebook,
                    state: state,
                    pageCount: displayPages.count,
                    onBack: closeEditor,
                    onShare: { state.isExportPresented = true },
                    onExportPDF: exportPDF,
                    onExportMarkdown: exportMarkdown,
                    onFindInNotebook: { isShowingInNotebookSearch = true },
                    onPrint: printNotebook,
                    onDuplicatePage: duplicateCurrentPage,
                    onDeletePage: deleteCurrentPage,
                    onSummarizePage: { isShowingSummarize = true },
                    onAskAboutPage: { isShowingAskAboutPage = true },
                    onCopyPageAsImage: copyCurrentPage,
                    onResetZoom: { state.editorZoom = 1 },
                    onPageTemplate: { isShowingPageTemplate = true },
                    onToggleFocusMode: { state.isFocusMode.toggle() },
                    onInsertImage: insertImageOnCurrentPage,
                    onInsertSticky: insertStickyOnCurrentPage,
                    onStartVoiceNote: startVoiceMemoRecording,
                    onStartTranscription: startTranscriptionRecording,
                    onAddPage: { addPage(afterCurrent: true) },
                    onNotebookInfo: { isShowingNotebookInfo = true }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if shouldShowFormatToolbar {
                MacDockedTextFormatToolbar(
                    coverTone: notebook.coverTone,
                    isEditingText: state.editingBlockID != nil,
                    controller: richTextController,
                    onNeedsTextFocus: focusSelectedTextForFormatting
                )
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .zIndex(75)
    }

    private var shouldShowFormatToolbar: Bool {
        !state.isFocusMode && !state.isCustomisePanelOpen
    }

    /// Breathing room above the first page — chrome lives in `editorTopChrome`.
    private var documentTopInset: CGFloat {
        state.isFocusMode ? 16 : 48
    }

    private func focusSelectedTextForFormatting() {
        guard state.editingBlockID == nil else { return }
        if let selected = state.selectedElementID {
            state.editingBlockID = selected
            return
        }
        guard let pageID = state.selectedPageID ?? displayPages.first?.id else { return }
        let pid = pageID
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\PageElement.normalizedY)]
        )
        let elements = (try? storageService.context.fetch(descriptor)) ?? []
        if let firstText = elements.first(where: { $0.kind == .text }) {
            state.selectedElementID = firstText.id
            state.editingBlockID = firstText.id
        }
    }

    private func closeEditor() {
        publishHandoff()
        if let onClose {
            onClose()
        } else {
            dismiss()
            MacStateUpdates.deferred {
                deepLink.forceLibraryHome = true
            }
        }
    }

    @ViewBuilder
    private func attachEditorSheets<V: View>(_ view: V) -> some View {
        view
        .sheet(item: editingStickyBinding) { element in
            MacStickyNoteEditorSheet(element: element)
                .environmentObject(storageService)
        }
        .sheet(isPresented: $isShowingSummarize) {
            if let page = currentPage {
                SummarizePageView(
                    page: page,
                    notebookTitle: notebook.title,
                    notebookId: notebook.id,
                    onDismiss: { isShowingSummarize = false }
                )
            }
        }
        .sheet(isPresented: $isShowingPageTemplate) {
            MacPageTemplateSheet(notebook: notebook, page: currentPage)
                .environmentObject(storageService)
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $isShowingAskAboutPage) {
            if let page = currentPage {
                AskAboutPageView(
                    page: page,
                    notebookTitle: notebook.title,
                    onDismiss: { isShowingAskAboutPage = false }
                )
                .environment(\.theme, theme)
            }
        }
        .sheet(isPresented: $isShowingInNotebookSearch) {
            MacInNotebookSearchView(
                notebook: notebook,
                selectedPageID: pageSelection
            )
            .environment(\.theme, theme)
        }
        .sheet(isPresented: $isShowingPageOrder) {
            MacPageOrderSheet(notebook: notebook, selectedPageID: pageSelection)
                .environmentObject(storageService)
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $isShowingNotebookInfo) {
            NotebookOriginInfoSheet(notebook: notebook)
                .environment(\.theme, theme)
                .frame(width: 400, height: 320)
        }
        .sheet(isPresented: $isShowingQuizBuilder) {
            QuizBuilderView(viewModel: libraryVM)
                .environment(\.theme, theme)
                .frame(minWidth: 520, minHeight: 560)
                .onAppear {
                    libraryVM.quizBuilderPreselectedNotebookID = notebook.id
                }
        }
        .alert("Transcription", isPresented: Binding(
            get: { transcriptionErrorMessage != nil },
            set: { if !$0 { transcriptionErrorMessage = nil } }
        )) {
            Button("OK") { transcriptionErrorMessage = nil }
        } message: {
            Text(transcriptionErrorMessage ?? "")
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
    private func attachEditorNotifications<V: View>(_ view: V) -> some View {
        attachEditorNotificationsC(attachEditorNotificationsB(attachEditorNotificationsA(view)))
    }

    @ViewBuilder
    private func attachEditorNotificationsA<V: View>(_ view: V) -> some View {
        view
        .onReceive(NotificationCenter.default.publisher(for: .macSummarizePage)) { _ in
            MacStateUpdates.deferred {
                guard currentPage != nil else { return }
                isShowingSummarize = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macAskAboutPage)) { _ in
            MacStateUpdates.deferred {
                guard currentPage != nil else { return }
                isShowingAskAboutPage = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macPageTemplate)) { _ in
            MacStateUpdates.deferred { isShowingPageTemplate = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macAddPage)) { _ in
            MacStateUpdates.deferred { addPage(afterCurrent: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macDeletePage)) { _ in
            MacStateUpdates.deferred { deleteCurrentPage() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macDuplicatePage)) { _ in
            MacStateUpdates.deferred { duplicateCurrentPage() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macReorderPages)) { _ in
            MacStateUpdates.deferred { isShowingPageOrder = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macMovePageUp)) { _ in
            MacStateUpdates.deferred { moveCurrentPage(by: -1) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macMovePageDown)) { _ in
            MacStateUpdates.deferred { moveCurrentPage(by: 1) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macInsertShape)) { note in
            MacStateUpdates.deferred {
                guard let raw = note.userInfo?[MacShapeHandoff.kindKey] as? String,
                      let kind = ShapeKind(rawValue: raw) else { return }
                insertShape(kind)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macSearchInNotebook)) { _ in
            MacStateUpdates.deferred { isShowingInNotebookSearch = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macCopyPage)) { _ in
            MacStateUpdates.deferred { copyCurrentPage() }
        }
    }

    @ViewBuilder
    private func attachEditorNotificationsC<V: View>(_ view: V) -> some View {
        view
        .onReceive(NotificationCenter.default.publisher(for: .macToggleFocusMode)) { _ in
            MacStateUpdates.deferred {
                guard MacWindowFocus.isNotebookEditorKey else { return }
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                    state.isFocusMode.toggle()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macGenerateQuiz)) { _ in
            MacStateUpdates.deferred {
                libraryVM.quizBuilderPreselectedNotebookID = notebook.id
                isShowingQuizBuilder = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macOpenSearch)) { _ in
            MacStateUpdates.deferred {
                guard MacWindowFocus.isNotebookEditorKey else { return }
                MacWindowFocus.bringLibraryForward(andPost: .macOpenSearch)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macOpenCommandPalette)) { _ in
            MacStateUpdates.deferred {
                guard MacWindowFocus.isNotebookEditorKey else { return }
                MacWindowFocus.bringLibraryForward(andPost: .macOpenCommandPalette)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macToggleSidebar)) { _ in
            MacStateUpdates.deferred {
                guard MacWindowFocus.isNotebookEditorKey else { return }
                MacWindowFocus.bringLibraryForward(andPost: .macToggleSidebar)
            }
        }
    }

    @ViewBuilder
    private func attachEditorNotificationsB<V: View>(_ view: V) -> some View {
        view
        .onReceive(NotificationCenter.default.publisher(for: .macInsertImage)) { _ in
            MacStateUpdates.deferred { insertImageOnCurrentPage() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macInsertStickyNote)) { _ in
            MacStateUpdates.deferred { insertStickyOnCurrentPage() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macSelectNextElement)) { _ in
            MacStateUpdates.deferred { cycleSelectedElement(forward: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macSelectPreviousElement)) { _ in
            MacStateUpdates.deferred { cycleSelectedElement(forward: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macDeleteSelectedElement)) { _ in
            MacStateUpdates.deferred { deleteSelectedElement() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macImportPDFPages)) { _ in
            MacStateUpdates.deferred { importPDFIntoNotebook() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macTranscriptionStarted)) { note in
            MacStateUpdates.deferred {
                guard let pageID = note.userInfo?[MacHandoff.pageIdKey] as? UUID else { return }
                let elementID = note.userInfo?[MacTranscriptionKeys.elementId] as? UUID
                state.selectedPageID = pageID
                state.selectedElementID = elementID
                state.editingBlockID = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macStartDictation)) { _ in
            MacStateUpdates.deferred { startTranscriptionRecording() }
        }
        .onChange(of: recordingSession.lastErrorMessage) { _, message in
            transcriptionErrorMessage = message
        }
        .onReceive(NotificationCenter.default.publisher(for: .macCopyHandwritingOCR)) { _ in
            MacStateUpdates.deferred { Task { await copyHandwritingAsText() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macAskAIAboutElement)) { note in
            MacStateUpdates.deferred {
                guard let elementId = note.userInfo?["elementId"] as? UUID else { return }
                state.selectedElementID = elementId
                state.editingBlockID = elementId
                isShowingAskAboutPage = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macRequestHandoffToIPad)) { note in
            MacStateUpdates.deferred { publishHandoffToIPad(note) }
        }
    }

    private func publishHandoffToIPad(_ note: Notification) {
        guard let notebookID = note.userInfo?[MacHandoff.notebookIdKey] as? UUID,
              let pageID = note.userInfo?[MacHandoff.pageIdKey] as? UUID else { return }
        state.selectedPageID = pageID
        let activity = NSUserActivity(activityType: PageHandoff.activityType)
        activity.title = notebook.title
        activity.userInfo = PageHandoff.userInfo(notebookId: notebookID, pageId: pageID)
        activity.requiredUserInfoKeys = Set([PageHandoff.notebookIdKey, PageHandoff.pageIdKey])
        activity.isEligibleForHandoff = true
        activity.becomeCurrent()
        let alert = NSAlert()
        alert.messageText = "Continue on iPad"
        alert.informativeText = "Open Cecilia's Notes on your nearby iPad to edit this page with Apple Pencil."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func copyHandwritingAsText() async {
        guard let page = currentPage,
              let data = storageService.strokeData(for: page),
              let drawing = try? PKDrawing(data: data) else { return }
        let output = await HandwritingOCRService.recognise(
            drawing: drawing,
            pageSize: page.pageSize.pointSize
        )
        guard !output.joined.isEmpty else { return }
        PlatformClipboard.copy(output.joined)
    }

    private func cycleSelectedElement(forward: Bool) {
        guard let page = currentPage else { return }
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil },
            sortBy: [
                SortDescriptor(\PageElement.normalizedY),
                SortDescriptor(\PageElement.normalizedX),
                SortDescriptor(\PageElement.zIndex),
            ]
        )
        let items = (try? storageService.context.fetch(descriptor)) ?? []
            .filter { $0.kind != .stroke && $0.kind != .highlight }
        guard !items.isEmpty else { return }
        let current = state.editingBlockID ?? state.selectedElementID
        let next: PageElement
        if let current, let idx = items.firstIndex(where: { $0.id == current }) {
            next = forward
                ? items[(idx + 1) % items.count]
                : items[(idx - 1 + items.count) % items.count]
        } else {
            next = forward ? items[0] : items[items.count - 1]
        }
        state.selectedPageID = page.id
        state.selectedElementID = next.id
        if next.kind == .text || next.kind == .stickyNote {
            state.editingBlockID = next.id
        } else {
            state.editingBlockID = nil
        }
    }

    private func deleteSelectedElement() {
        let id = state.editingBlockID ?? state.selectedElementID
        guard let id else { return }
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.id == id }
        )
        guard let element = try? storageService.context.fetch(descriptor).first else { return }
        MacElementEditing.softDelete(element, context: storageService.context)
        state.selectedElementID = nil
        state.editingBlockID = nil
    }

    private func importPDFIntoNotebook() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let count = await MacImportService.importPDFIntoNotebook(
                from: url,
                notebook: notebook,
                after: currentPage,
                storage: storageService
            )
            await MainActor.run {
                if count > 0 {
                    importFeedback = MacImportFeedback(
                        title: "Import complete",
                        message: "Added \(count) page\(count == 1 ? "" : "s") after the current page. PDFs with a text layer import as editable notes; scanned pages import as images."
                    )
                } else {
                    importFeedback = MacImportFeedback(
                        title: "Import failed",
                        message: "Could not read that PDF. Try a different file or check that it is not password-protected."
                    )
                }
            }
        }
    }

    private func insertImageOnCurrentPage() {
        guard let page = currentPage else { return }
        MacElementEditing.pickAndInsertImage(
            on: page,
            notebookId: notebook.id,
            context: storageService.context
        )
    }

    private func insertStickyOnCurrentPage() {
        guard let page = currentPage else { return }
        let size = page.pageSize.pointSize
        if let element = MacElementEditing.insertStickyNote(
            on: page,
            notebookId: notebook.id,
            pageSize: size,
            context: storageService.context
        ) {
            editingStickyElement = element
        }
    }

    private var currentPage: Page? {
        guard let id = state.selectedPageID else { return displayPages.first }
        return displayPages.first { $0.id == id } ?? displayPages.first
    }

    private var pageSelection: Binding<UUID?> {
        Binding(
            get: { state.selectedPageID },
            set: { id in
                MacStateUpdates.deferred { state.selectedPageID = id }
            }
        )
    }

    private var editingStickyBinding: Binding<PageElement?> {
        Binding(
            get: { editingStickyElement },
            set: { element in
                MacStateUpdates.deferred { editingStickyElement = element }
            }
        )
    }

    private func publishHandoff() {
        guard let pageID = state.selectedPageID else { return }
        let activity = NSUserActivity(activityType: PageHandoff.activityType)
        activity.title = notebook.title
        activity.userInfo = PageHandoff.userInfo(
            notebookId: notebook.id,
            pageId: pageID,
            scrollOffset: state.editorScrollOffset,
            zoom: state.editorZoom
        )
        activity.requiredUserInfoKeys = Set([PageHandoff.notebookIdKey, PageHandoff.pageIdKey])
        activity.isEligibleForHandoff = true
        activity.becomeCurrent()
    }

    private func insertShape(_ kind: ShapeKind) {
        guard let page = currentPage else { return }
        if let element = MacElementEditing.insertShape(
            kind: kind,
            on: page,
            notebookId: notebook.id,
            context: storageService.context
        ) {
            MacStateUpdates.deferred { state.selectedElementID = element.id }
        }
    }

    private func exportPDF() {
        state.exportFormat = .pdf
        state.isExportPresented = true
    }

    private func exportMarkdown() {
        state.exportFormat = .markdown
        state.isExportPresented = true
    }

    private func printNotebook() {
        MacPrintService.printNotebook(notebook, storage: storageService)
    }

    private func addPage(afterCurrent: Bool) {
        let after = afterCurrent ? currentPage : displayPages.last
        if let newPage = MacPageEditing.addPage(in: notebook, after: after, storage: storageService) {
            MacStateUpdates.deferred { state.selectedPageID = newPage.id }
        }
    }

    private func deleteCurrentPage() {
        guard let page = currentPage else { return }
        let pages = storageService.fetchPages(in: notebook).dedupedById()
        guard MacPageEditing.deletePage(page, notebook: notebook, storage: storageService) else { return }
        let remaining = storageService.fetchPages(in: notebook)
        let next = remaining.first { $0.pageNumber >= page.pageNumber } ?? remaining.last
        MacStateUpdates.deferred { state.selectedPageID = next?.id ?? pages.first?.id }
    }

    private func duplicateCurrentPage() {
        guard let page = currentPage,
              let copy = MacPageEditing.duplicatePage(page, storage: storageService) else { return }
        MacStateUpdates.deferred { state.selectedPageID = copy.id }
    }

    private func canMoveCurrentPage(by delta: Int) -> Bool {
        guard let page = currentPage else { return false }
        let target = page.pageNumber + delta
        return target >= 1 && target <= displayPages.count
    }

    private func moveCurrentPage(by delta: Int) {
        guard let page = currentPage else { return }
        let target = page.pageNumber + delta
        guard target >= 1, target <= displayPages.count else { return }
        guard MacPageEditing.movePage(page, to: target, storage: storageService) else { return }
        MacStateUpdates.deferred { state.selectedPageID = page.id }
    }

    private func copyCurrentPage() {
        guard let page = currentPage else { return }
        MacCopyPageService.copyPage(page, notebook: notebook, storage: storageService)
    }

    private func startVoiceMemoRecording() {
        guard let page = currentPage else { return }
        Task {
            await MacRecordingSession.shared.startVoiceMemo(page: page, notebook: notebook)
        }
    }

    private func startTranscriptionRecording() {
        guard let page = currentPage else { return }
        Task {
            _ = await recordingSession.startTranscription(page: page, notebook: notebook)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let pageID = state.selectedPageID else { return false }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        _ = await MacImportService.importImageURL(
                            url,
                            pageId: pageID,
                            notebookId: notebook.id,
                            context: storageService.context
                        )
                    }
                }
                return true
            }
        }
        return false
    }
}
