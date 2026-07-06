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
    @EnvironmentObject private var storageService: StorageService

    @Query private var pages: [Page]
    @State private var isShowingSummarize = false
    @State private var isShowingCoverEditor = false
    @StateObject private var lectureRecorder = LectureRecorder()
    @State private var isLecturePresented = false
    @State private var isShowingAskAboutPage = false
    @State private var isShowingPageTemplate = false
    @State private var isShowingInNotebookSearch = false
    @State private var isVoiceMemoPresented = false
    @State private var editingStickyElement: PageElement?
    @StateObject private var textEditingController = MacTextEditingController()

    /// Mac writing surface: `.doc` renders the notebook as a linear
    /// Google-Docs-style document (default on Mac); `.canvas` mirrors the
    /// iPad's page-with-floating-elements layout. Persisted per-user so
    /// the preference survives launches, not per-notebook — a user who
    /// prefers Doc Mode wants it everywhere.
    @AppStorage("mac.editor.writingMode") private var writingMode: MacWritingMode = .doc

    init(notebook: Notebook, state: MacLibraryState, libraryVM: LibraryViewModel) {
        self.notebook = notebook
        self.state = state
        self.libraryVM = libraryVM
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
        ZStack(alignment: .bottom) {
            editorContent
            if state.editingTextElement != nil {
                MacFloatingTextToolbar(controller: textEditingController)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: state.editingTextElement?.id)
        .navigationTitle(notebook.title)
        .accessibilityLabel(A11y.notebookLabel(
            title: notebook.title,
            subjectName: nil,
            pageCount: pages.count,
            modified: notebook.updatedAt
        ))
        .toolbar(state.isFocusMode ? .hidden : .visible, for: .windowToolbar)
        .toolbar { if !state.isFocusMode { editorToolbar } }
        .background(theme.pageBackground.opacity(0.08))
        .onAppear {
            MacStateUpdates.deferred {
                if state.selectedPageID == nil {
                    state.selectedPageID = pages.first?.id
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
        .onDisappear {
            publishHandoff()
        }
        .onDrop(of: [.fileURL, .image, .pdf], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        switch writingMode {
        case .doc:
            MacDocModeView(notebook: notebook, pages: pages)
                .environmentObject(storageService)
        case .canvas:
            editorCanvasStack
        }
    }

    private var editorCanvasStack: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 0) {
                MacContinuousCanvasView(
                    notebook: notebook,
                    pages: pages,
                    zoom: $state.editorZoom,
                    selectedPageID: $state.selectedPageID,
                    selectedElementID: $state.selectedElementID,
                    editingTextElementID: state.editingTextElement?.id,
                    textEditingController: textEditingController,
                    onEditText: { element in
                        MacStateUpdates.deferred { beginTextEditing(element) }
                    },
                    onEndTextEditing: {
                        MacStateUpdates.deferred { endTextEditing() }
                    },
                    onEditSticky: { element in
                        MacStateUpdates.deferred { editingStickyElement = element }
                    },
                    onScrollOffsetCommit: { offset in
                        state.editorScrollOffset = offset
                    }
                )

                if !state.isFocusMode {
                    MacPageStripView(
                        notebook: notebook,
                        pages: pages,
                        selectedPageID: pageSelection,
                        storage: storageService,
                        onPagesChanged: { newPageID in
                            if let newPageID {
                                MacStateUpdates.deferred { state.selectedPageID = newPageID }
                            }
                        }
                    )
                    .frame(width: 88)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            if state.editorZoom > 1.25, !state.isFocusMode {
                MacMinimapView(pages: pages, selectedPageID: pageSelection)
                    .padding(16)
                    .transition(.opacity)
            }
        }
    }

    private func beginTextEditing(_ element: PageElement) {
        if state.editingTextElement?.id != element.id {
            endTextEditing(resignOnly: true)
        }
        state.selectedElementID = element.id
        state.editingTextElement = element
    }

    private func endTextEditing(resignOnly: Bool = false) {
        if let textView = textEditingController.activeTextView {
            textView.window?.makeFirstResponder(nil)
        }
        if !resignOnly {
            textEditingController.detach()
            if state.editingTextElement?.kind == .text {
                state.selectedElementID = nil
            }
            state.editingTextElement = nil
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .navigation) {
                Picker("Mode", selection: $writingMode) {
                    Text("doc").tag(MacWritingMode.doc)
                    Text("canvas").tag(MacWritingMode.canvas)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .help("Doc mode: linear document. Canvas mode: iPad-style page layout.")
                Button {
                    MacDictationTrigger.start()
                } label: {
                    Label("Dictate", systemImage: "mic")
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .help("Start system dictation in the focused text block (⌥⌘V)")
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Insert Image…") { insertImageOnCurrentPage() }
                    Button("Insert Sticky Note") { insertStickyOnCurrentPage() }
                } label: {
                    Label("Insert", systemImage: "plus.square.on.square")
                }
                .help("Insert image or sticky note")
                .disabled(currentPage == nil)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    MacStateUpdates.deferred { isShowingPageTemplate = true }
                } label: {
                    Label("Template", systemImage: "square.grid.2x2")
                }
                .help("Change page template")
            }
            ToolbarItem(placement: .automatic) {
                if IntelligenceService.shared.canRun {
                    Button {
                        MacStateUpdates.deferred { isShowingAskAboutPage = true }
                    } label: {
                        Label("Ask Page", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .help("Ask about this page")
                    .disabled(currentPage == nil)
                }
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Rectangle") { insertShape(.rectangle) }
                    Button("Ellipse") { insertShape(.ellipse) }
                    Button("Arrow") { insertShape(.arrow) }
                } label: {
                    Label("Insert Shape", systemImage: "square.on.circle")
                }
                .help("Insert a shape on the current page")
                .disabled(currentPage == nil)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    MacStateUpdates.deferred { isShowingCoverEditor = true }
                } label: {
                    Label("Cover", systemImage: "paintpalette")
                }
                .help("Edit notebook cover and title")
            }
            ToolbarItem(placement: .automatic) {
                if IntelligenceService.shared.canRun {
                    Button {
                        NotificationCenter.default.post(
                            name: .macGenerateQuiz,
                            object: nil,
                            userInfo: [CeciliasNotesIntentKeys.notebookId: notebook.id]
                        )
                    } label: {
                        Label("Generate Quiz", systemImage: "checklist")
                    }
                    .help("Generate a quiz from this notebook")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    MacStateUpdates.deferred { isShowingInNotebookSearch = true }
                } label: {
                    Label("Find in Notebook", systemImage: "magnifyingglass")
                }
                .help("Search within this notebook (⌘⇧F)")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    MacStateUpdates.deferred { copyCurrentPage() }
                } label: {
                    Label("Copy Page", systemImage: "doc.on.doc")
                }
                .help("Copy current page as image (⌘⇧C)")
                .disabled(currentPage == nil)
            }
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    MacStateUpdates.deferred { isVoiceMemoPresented = true }
                } label: {
                    Label("Voice Memo", systemImage: "waveform")
                }
                .help("Record a short voice memo on this page")
                .disabled(currentPage == nil)

                Button {
                    Task { @MainActor in
                        guard let page = currentPage else { return }
                        do {
                            try await lectureRecorder.start(pageId: page.id, notebookId: notebook.id)
                            isLecturePresented = true
                        } catch {
                            #if DEBUG
                            dlog("[MacLecture] start failed: \(error)")
                            #endif
                        }
                    }
                } label: {
                    Label("Lecture", systemImage: "mic")
                }
                .help("Long-form recording with live transcript")
                .disabled(currentPage == nil)
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
        .sheet(isPresented: $isShowingCoverEditor) {
            MacNotebookCoverSheet(notebook: notebook, libraryVM: libraryVM)
                .environment(\.theme, theme)
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
        .sheet(isPresented: $isLecturePresented) {
            if let page = currentPage {
                MacLectureRecordingView(
                    page: page,
                    notebook: notebook,
                    recorder: lectureRecorder,
                    onFinished: { isLecturePresented = false },
                    onCancel: {
                        Task { @MainActor in _ = await lectureRecorder.stop() }
                        isLecturePresented = false
                    }
                )
                .environment(\.theme, theme)
            }
        }
        .sheet(isPresented: $isVoiceMemoPresented) {
            if let page = currentPage {
                MacVoiceMemoRecordingView(
                    page: page,
                    notebook: notebook,
                    onFinished: { isVoiceMemoPresented = false },
                    onCancel: { isVoiceMemoPresented = false }
                )
                .environment(\.theme, theme)
            }
        }
    }

    @ViewBuilder
    private func attachEditorNotifications<V: View>(_ view: V) -> some View {
        attachEditorNotificationsB(attachEditorNotificationsA(view))
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
        .onReceive(NotificationCenter.default.publisher(for: .macToggleFocusMode)) { _ in
            MacStateUpdates.deferred {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                    state.isFocusMode.toggle()
                }
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
        .onReceive(NotificationCenter.default.publisher(for: .macCopyHandwritingOCR)) { _ in
            MacStateUpdates.deferred { Task { await copyHandwritingAsText() } }
        }
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
            sortBy: [SortDescriptor(\.zIndex)]
        )
        let items = (try? storageService.context.fetch(descriptor)) ?? []
            .filter { $0.kind != .stroke && $0.kind != .highlight }
        guard !items.isEmpty else { return }
        if let current = state.selectedElementID,
           let idx = items.firstIndex(where: { $0.id == current }) {
            let next = forward
                ? items[(idx + 1) % items.count]
                : items[(idx - 1 + items.count) % items.count]
            state.selectedElementID = next.id
        } else {
            state.selectedElementID = forward ? items.first?.id : items.last?.id
        }
    }

    private func deleteSelectedElement() {
        guard let id = state.selectedElementID else { return }
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.id == id }
        )
        guard let element = try? storageService.context.fetch(descriptor).first else { return }
        MacElementEditing.softDelete(element, context: storageService.context)
        state.selectedElementID = nil
    }

    private func importPDFIntoNotebook() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            _ = await MacImportService.importPDFIntoNotebook(
                from: url,
                notebook: notebook,
                after: currentPage,
                storage: storageService
            )
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
        guard let id = state.selectedPageID else { return pages.first }
        return pages.first { $0.id == id } ?? pages.first
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

    private func addPage(afterCurrent: Bool) {
        let after = afterCurrent ? currentPage : pages.last
        if let newPage = MacPageEditing.addPage(in: notebook, after: after, storage: storageService) {
            MacStateUpdates.deferred { state.selectedPageID = newPage.id }
        }
    }

    private func deleteCurrentPage() {
        guard let page = currentPage else { return }
        let pages = storageService.fetchPages(in: notebook)
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

    private func copyCurrentPage() {
        guard let page = currentPage else { return }
        MacCopyPageService.copyPage(page, notebook: notebook, storage: storageService)
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

struct MacPageStripView: View {
    let notebook: Notebook
    let pages: [Page]
    @Binding var selectedPageID: UUID?
    let storage: StorageService
    var onPagesChanged: (UUID?) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    MacPageThumbnail(page: page, index: index + 1, isSelected: selectedPageID == page.id)
                        .onTapGesture {
                            MacStateUpdates.deferred { selectedPageID = page.id }
                        }
                        .draggable(MacPageDragItem(pageId: page.id, fromPageNumber: page.pageNumber))
                        .dropDestination(for: MacPageDragItem.self) { items, _ in
                            guard let item = items.first,
                                  item.pageId != page.id,
                                  let source = pages.first(where: { $0.id == item.pageId })
                            else { return false }
                            guard MacPageEditing.movePage(source, to: page.pageNumber, storage: storage) else {
                                return false
                            }
                            onPagesChanged(source.id)
                            return true
                        }
                        .contextMenu {
                            Button("Insert Page After") {
                                if let newPage = MacPageEditing.addPage(in: notebook, after: page, storage: storage) {
                                    onPagesChanged(newPage.id)
                                }
                            }
                            Button("Duplicate Page") {
                                if let copy = MacPageEditing.duplicatePage(page, storage: storage) {
                                    onPagesChanged(copy.id)
                                }
                            }
                            Divider()
                            Button("Delete Page", role: .destructive) {
                                guard MacPageEditing.deletePage(page, notebook: notebook, storage: storage) else { return }
                                let remaining = storage.fetchPages(in: notebook)
                                onPagesChanged(remaining.first?.id)
                            }
                            .disabled(pages.count <= 1)
                        }
                }

                Button {
                    if let newPage = MacPageEditing.addPage(in: notebook, after: pages.last, storage: storage) {
                        onPagesChanged(newPage.id)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .frame(width: 64, height: 32)
                        .background(theme.hairline.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Add page")
            }
            .padding(8)
        }
        .background(theme.surface)
    }
}

private struct MacPageDragItem: Transferable, Codable {
    let pageId: UUID
    let fromPageNumber: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

private struct MacPageThumbnail: View {
    let page: Page
    let index: Int
    let isSelected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.pageBackground)
                .frame(width: 64, height: 84)
                .shadow(radius: isSelected ? 2 : 0)
            Text("\(index)")
                .font(.caption2)
                .padding(4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? theme.accent : Color.clear, lineWidth: 2)
        }
        .accessibilityLabel("Page \(index)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct MacContinuousCanvasView: View {
    let notebook: Notebook
    let pages: [Page]
    @Binding var zoom: CGFloat
    @Binding var selectedPageID: UUID?
    @Binding var selectedElementID: UUID?
    var editingTextElementID: UUID?
    @ObservedObject var textEditingController: MacTextEditingController
    var onEditText: (PageElement) -> Void
    var onEndTextEditing: () -> Void
    var onEditSticky: (PageElement) -> Void
    var onScrollOffsetCommit: (CGFloat) -> Void

    @State private var localScrollOffset: CGFloat = 0
    @State private var pinchBaseZoom: CGFloat = 1

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    ForEach(pages) { page in
                        MacPageView(
                            notebook: notebook,
                            page: page,
                            zoom: zoom,
                            selectedElementID: elementSelection,
                            editingTextElementID: editingTextElementID,
                            textEditingController: textEditingController,
                            onEditText: onEditText,
                            onEndTextEditing: onEndTextEditing,
                            onEditSticky: onEditSticky
                        )
                        .id(page.id)
                    }
                }
                .padding()
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { scale in
                        zoom = min(4, max(0.25, pinchBaseZoom * scale))
                    }
                    .onEnded { _ in
                        pinchBaseZoom = zoom
                    }
            )
            .onAppear { pinchBaseZoom = zoom }
            .onChange(of: zoom) { _, newValue in
                if abs(newValue - pinchBaseZoom) > 0.001 {
                    pinchBaseZoom = newValue
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, offset in
                localScrollOffset = offset
            }
            .onChange(of: selectedPageID) { _, pageID in
                guard let pageID else { return }
                withAnimation { proxy.scrollTo(pageID, anchor: .top) }
            }
            .onDisappear {
                onScrollOffsetCommit(localScrollOffset)
            }
        }
    }

    private var elementSelection: Binding<UUID?> {
        Binding(
            get: { selectedElementID },
            set: { id in
                MacStateUpdates.deferred { selectedElementID = id }
            }
        )
    }
}

struct MacPageView: View {
    let notebook: Notebook
    let page: Page
    let zoom: CGFloat
    @Binding var selectedElementID: UUID?
    var editingTextElementID: UUID?
    @ObservedObject var textEditingController: MacTextEditingController
    var onEditText: (PageElement) -> Void
    var onEndTextEditing: () -> Void
    var onEditSticky: (PageElement) -> Void
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storageService: StorageService

    @Query private var elements: [PageElement]

    init(
        notebook: Notebook,
        page: Page,
        zoom: CGFloat,
        selectedElementID: Binding<UUID?>,
        editingTextElementID: UUID?,
        textEditingController: MacTextEditingController,
        onEditText: @escaping (PageElement) -> Void,
        onEndTextEditing: @escaping () -> Void,
        onEditSticky: @escaping (PageElement) -> Void
    ) {
        self.notebook = notebook
        self.page = page
        self.zoom = zoom
        _selectedElementID = selectedElementID
        self.editingTextElementID = editingTextElementID
        self.textEditingController = textEditingController
        self.onEditText = onEditText
        self.onEndTextEditing = onEndTextEditing
        self.onEditSticky = onEditSticky
        let pageID = page.id
        _elements = Query(
            filter: #Predicate<PageElement> { element in
                element.pageId == pageID && element.deletedAt == nil
            },
            sort: \PageElement.zIndex
        )
    }

    private var pageSize: CGSize {
        let base = page.pageSize.pointSize
        return CGSize(width: base.width * zoom, height: base.height * zoom)
    }

    private var pdfParents: [UUID: PageElement] {
        Dictionary(uniqueKeysWithValues: elements.compactMap { el -> (UUID, PageElement)? in
            guard el.kind == .pdfPage, let id = el.pdfPageContent?.id else { return nil }
            return (id, el)
        })
    }

    private func elementFrame(for element: PageElement) -> CGRect {
        CGRect(
            x: element.normalizedX * pageSize.width,
            y: element.normalizedY * pageSize.height,
            width: max(1, element.normalizedWidth * pageSize.width),
            height: max(1, element.normalizedHeight * pageSize.height)
        )
    }

    private func topElement(at location: CGPoint) -> PageElement? {
        elements
            .filter { $0.kind != .highlight }
            .reversed()
            .first { elementFrame(for: $0).contains(location) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.pageBackground)
                .shadow(radius: 2)

            MacTemplateBackground(template: page.backgroundTemplate, theme: theme)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            ForEach(elements.filter { $0.kind != .highlight }) { element in
                MacElementView(
                    element: element,
                    pageSize: pageSize,
                    pdfParents: pdfParents,
                    isSelected: selectedElementID == element.id,
                    isEditingText: editingTextElementID == element.id,
                    editingTextController: textEditingController,
                    onSelect: { id in
                        MacStateUpdates.deferred {
                            if editingTextElementID != nil, editingTextElementID != id {
                                onEndTextEditing()
                            }
                            selectedElementID = id
                        }
                    },
                    onEditText: onEditText,
                    onEndTextEditing: onEndTextEditing,
                    onEditSticky: onEditSticky
                )
            }

            ForEach(elements.filter { $0.kind == .highlight }) { element in
                MacElementView(
                    element: element,
                    pageSize: pageSize,
                    pdfParents: pdfParents,
                    isSelected: selectedElementID == element.id,
                    isEditingText: false,
                    editingTextController: nil,
                    onSelect: { id in
                        MacStateUpdates.deferred {
                            if editingTextElementID != nil {
                                onEndTextEditing()
                            }
                            selectedElementID = id
                        }
                    },
                    onEditText: onEditText,
                    onEndTextEditing: onEndTextEditing,
                    onEditSticky: onEditSticky
                )
            }

            if let strokeData = storageService.strokeData(for: page), !strokeData.isEmpty,
               let drawing = try? PKDrawing(data: strokeData) {
                let scale = max(2, zoom * 2)
                let rendered = drawing.image(from: CGRect(origin: .zero, size: pageSize), scale: scale)
                Image(nsImage: rendered)
                    .resizable()
                    .frame(width: pageSize.width, height: pageSize.height)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Handwriting")
                    .accessibilityHint("Read only on Mac. Edit on iPad.")
                    .accessibilityAddTraits(.isImage)
            }

            // Empty-page hint. When the page has zero elements the user
            // needs a signal that Mac IS a typing surface — the hint
            // sits at the standard text-element insertion point (8%
            // from top, 8% from left) so a double-click there lands
            // exactly where the hint reads.
            if elements.isEmpty {
                Text("click to type — handwriting stays on iPad")
                    .font(.system(size: 11, weight: .regular).italic())
                    .foregroundStyle(theme.foregroundSubtle)
                    .padding(.leading, pageSize.width * 0.08)
                    .padding(.top, pageSize.width * 0.08)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .contentShape(Rectangle())
        .onTapGesture { location in
            if let editingId = editingTextElementID,
               let editing = elements.first(where: { $0.id == editingId }),
               elementFrame(for: editing).contains(location) {
                return
            }
            if editingTextElementID != nil {
                onEndTextEditing()
                return
            }
            guard topElement(at: location) == nil else { return }
            insertTextElement(at: location)
        }
        .onExitCommand {
            if editingTextElementID != nil {
                onEndTextEditing()
            }
        }
    }

    /// Insert a new text element and start inline editing immediately.
    private func insertTextElement(at location: CGPoint) {
        let normalizedY = min(max(0.05, location.y / pageSize.height), 0.88)
        let width = 0.84
        let rect = CGRect(
            x: (1 - width) / 2,
            y: normalizedY,
            width: width,
            height: 0.12
        )
        guard let element = TextElementCommit.create(
            text: "",
            source: .typed,
            pageId: page.id,
            notebookId: notebook.id,
            normalizedRect: rect,
            context: storageService.context
        ) else { return }
        MacStateUpdates.deferred {
            selectedElementID = element.id
            onEditText(element)
        }
    }
}

struct MacTemplateBackground: View {
    let template: PageTemplate
    let theme: Theme

    var body: some View {
        switch template {
        case .blank:
            theme.pageBackground
        case .narrowRuled, .wideRuled, .collegeRuled, .twoColumn:
            ruledBackground(spacing: 24)
        case .dotGrid5, .dotGrid10, .isoDots:
            dotBackground(spacing: 24)
        case .squareGrid5, .squareGrid10, .engineeringGrid:
            gridBackground(spacing: 24)
        default:
            theme.pageBackground
        }
    }

    private func ruledBackground(spacing: CGFloat) -> some View {
        Canvas { context, size in
            var y = spacing
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(theme.pageLines), lineWidth: 0.5)
                y += spacing
            }
        }
    }

    private func dotBackground(spacing: CGFloat) -> some View {
        Canvas { context, size in
            var y = spacing
            while y < size.height {
                var x = spacing
                while x < size.width {
                    let dot = Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    context.fill(dot, with: .color(theme.pageDots))
                    x += spacing
                }
                y += spacing
            }
        }
    }

    private func gridBackground(spacing: CGFloat) -> some View {
        Canvas { context, size in
            var y = spacing
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(theme.pageLines.opacity(0.8)), lineWidth: 0.5)
                y += spacing
            }
            var x = spacing
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(theme.pageLines.opacity(0.8)), lineWidth: 0.5)
                x += spacing
            }
        }
    }
}

/// Persisted writing surface preference for the Mac editor.
enum MacWritingMode: String, CaseIterable {
    case doc
    case canvas
}
