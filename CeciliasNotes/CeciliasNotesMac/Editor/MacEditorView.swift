import PencilKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MacEditorView: View {
    let notebook: Notebook
    @ObservedObject var state: MacLibraryState
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storageService: StorageService

    @Query private var pages: [Page]

    init(notebook: Notebook, state: MacLibraryState) {
        self.notebook = notebook
        self.state = state
        let notebookID = notebook.id
        _pages = Query(
            filter: #Predicate<Page> { page in
                page.notebookId == notebookID && !page.isDeleted
            },
            sort: \Page.pageNumber
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            MacContinuousCanvasView(
                notebook: notebook,
                pages: pages,
                zoom: $state.editorZoom,
                selectedPageID: $state.selectedPageID,
                selectedElementID: $state.selectedElementID,
                onEditText: { element in
                    MacStateUpdates.deferred { state.editingTextElement = element }
                },
                onScrollOffsetCommit: { offset in
                    state.editorScrollOffset = offset
                }
            )

            MacPageStripView(pages: pages, selectedPageID: pageSelection)
                .frame(width: 88)
        }
        .navigationTitle(notebook.title)
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
        .sheet(item: editingElementBinding) { element in
            MacTextEditorSheet(element: element)
                .environmentObject(storageService)
        }
        .onDrop(of: [.fileURL, .image, .pdf], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var pageSelection: Binding<UUID?> {
        Binding(
            get: { state.selectedPageID },
            set: { id in
                MacStateUpdates.deferred { state.selectedPageID = id }
            }
        )
    }

    private var editingElementBinding: Binding<PageElement?> {
        Binding(
            get: { state.editingTextElement },
            set: { element in
                MacStateUpdates.deferred { state.editingTextElement = element }
            }
        )
    }

    private func publishHandoff() {
        guard let pageID = state.selectedPageID else { return }
        let activity = NSUserActivity(activityType: MacHandoff.activityType)
        activity.title = notebook.title
        activity.userInfo = [
            MacHandoff.notebookIdKey: notebook.id.uuidString,
            MacHandoff.pageIdKey: pageID.uuidString,
            MacHandoff.scrollOffsetKey: state.editorScrollOffset,
            MacHandoff.zoomKey: state.editorZoom,
        ]
        activity.requiredUserInfoKeys = Set([MacHandoff.notebookIdKey, MacHandoff.pageIdKey])
        activity.becomeCurrent()
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
    let pages: [Page]
    @Binding var selectedPageID: UUID?
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    MacPageThumbnail(page: page, index: index + 1, isSelected: selectedPageID == page.id)
                        .onTapGesture {
                            MacStateUpdates.deferred { selectedPageID = page.id }
                        }
                }
            }
            .padding(8)
        }
        .background(theme.surface)
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
    }
}

struct MacContinuousCanvasView: View {
    let notebook: Notebook
    let pages: [Page]
    @Binding var zoom: CGFloat
    @Binding var selectedPageID: UUID?
    @Binding var selectedElementID: UUID?
    var onEditText: (PageElement) -> Void
    var onScrollOffsetCommit: (CGFloat) -> Void

    @State private var localScrollOffset: CGFloat = 0

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
                            onEditText: onEditText
                        )
                        .id(page.id)
                    }
                }
                .padding()
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
    var onEditText: (PageElement) -> Void
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storageService: StorageService

    @Query private var elements: [PageElement]

    init(
        notebook: Notebook,
        page: Page,
        zoom: CGFloat,
        selectedElementID: Binding<UUID?>,
        onEditText: @escaping (PageElement) -> Void
    ) {
        self.notebook = notebook
        self.page = page
        self.zoom = zoom
        _selectedElementID = selectedElementID
        self.onEditText = onEditText
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
                    onSelect: { id in MacStateUpdates.deferred { selectedElementID = id } },
                    onEditText: onEditText
                )
            }

            ForEach(elements.filter { $0.kind == .highlight }) { element in
                MacElementView(
                    element: element,
                    pageSize: pageSize,
                    pdfParents: pdfParents,
                    isSelected: selectedElementID == element.id,
                    onSelect: { id in MacStateUpdates.deferred { selectedElementID = id } },
                    onEditText: onEditText
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
            }

            // Empty-page hint. When the page has zero elements the user
            // needs a signal that Mac IS a typing surface — the hint
            // sits at the standard text-element insertion point (8%
            // from top, 8% from left) so a double-click there lands
            // exactly where the hint reads.
            if elements.isEmpty {
                Text("double-click to type — handwriting stays on iPad")
                    .font(.system(size: 11, weight: .regular).italic())
                    .foregroundStyle(theme.foregroundSubtle)
                    .padding(.leading, pageSize.width * 0.08)
                    .padding(.top, pageSize.width * 0.08)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        // Double-click anywhere on the page → insert a text element
        // at the click point. Mac idiom for "type here" — matches
        // Finder's rename-on-double-click, Numbers' cell entry,
        // Notes' new-block behaviour. The primary way to add text
        // on Mac; the toolbar button + ⌘T remain as fallbacks.
        .onTapGesture(count: 2) { location in
            insertTextElement(at: location)
        }
    }

    /// Insert a new text element centred horizontally at 80% width,
    /// with its top edge at the click's Y coordinate (normalised to
    /// the page size). Selects the new element and opens the
    /// text-editor sheet immediately so the user is typing within
    /// one gesture.
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
