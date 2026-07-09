import AppKit
import PencilKit
import SwiftData
import SwiftUI

/// Linear document view for Mac — one continuous Google-Docs-style
/// column. iPad-created elements appear inline in reading order.
struct MacDocModeView: View {
    let notebook: Notebook
    let pages: [Page]
    @Binding var selectedPageID: UUID?
    @Binding var editingBlockID: UUID?
    @Binding var selectedElementID: UUID?
    var editorScrollOffset: Binding<CGFloat>
    var pendingHandoffScrollOffset: Binding<CGFloat?>
    var editorZoom: CGFloat
    var topChromeInset: CGFloat = 0
    var onWritingBegan: () -> Void = {}

    @Environment(\.theme) private var theme
    @EnvironmentObject private var storage: StorageService

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        if index > 0 {
                            pageBreak(before: page)
                        }
                        MacDocPageSection(
                            page: page,
                            notebook: notebook,
                            selectedPageID: $selectedPageID,
                            editingBlockID: $editingBlockID,
                            selectedElementID: $selectedElementID,
                            editorZoom: editorZoom,
                            onInsertTextAt: { location in insertTextBlock(on: page, at: location) },
                            onWritingBegan: onWritingBegan
                        )
                        .id(page.id)
                    }
                    addPageFooter
                }
                .frame(maxWidth: MacDocLayout.contentColumnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, MacDocLayout.horizontalGutter)
                .padding(.top, topChromeInset + 48)
                .padding(.bottom, 64)
            }
            .background(theme.background)
            .background(
                MacDocScrollBridge(
                    scrollOffset: editorScrollOffset,
                    applyOffset: pendingHandoffScrollOffset.wrappedValue
                )
            )
            .onAppear {
                if selectedPageID == nil {
                    selectedPageID = pages.first?.id
                }
            }
            .onChange(of: selectedPageID) { _, pageID in
                guard let pageID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(pageID, anchor: .top)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macTranscriptionStarted)) { note in
                guard let elementID = note.userInfo?[MacTranscriptionKeys.elementId] as? UUID else { return }
                MacStateUpdates.deferred {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(elementID, anchor: .center)
                    }
                }
            }
            .onChange(of: pendingHandoffScrollOffset.wrappedValue) { _, offset in
                guard offset != nil else { return }
                MacStateUpdates.deferred {
                    pendingHandoffScrollOffset.wrappedValue = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macScrollToRecordingPage)) { note in
                MacStateUpdates.deferred {
                    let pageID = note.userInfo?[MacHandoff.pageIdKey] as? UUID
                    let elementID = note.userInfo?[MacTranscriptionKeys.elementId] as? UUID
                    if let pageID {
                        selectedPageID = pageID
                    }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        if let elementID {
                            proxy.scrollTo(elementID, anchor: .center)
                        } else if let pageID {
                            proxy.scrollTo(pageID, anchor: .top)
                        }
                    }
                    if let elementID {
                        selectedElementID = elementID
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macFocusTextBlock)) { note in
                guard let elementID = note.userInfo?[MacTranscriptionKeys.elementId] as? UUID else { return }
                MacStateUpdates.deferred {
                    editingBlockID = elementID
                    selectedElementID = elementID
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(elementID, anchor: .center)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macInsertTextOnPage)) { _ in
            MacStateUpdates.deferred { insertTextOnCurrentPage() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macInsertText)) { _ in
            MacStateUpdates.deferred { insertTextOnCurrentPage() }
        }
    }

    private func insertTextOnCurrentPage() {
        let pageID = selectedPageID ?? pages.first?.id
        guard let pageID, let page = pages.first(where: { $0.id == pageID }) else { return }
        insertTextBlock(on: page)
    }

    private func insertTextBlock(on page: Page, at location: CGPoint? = nil) {
        _ = location
        selectedPageID = page.id

        let pageWidth = page.pageSize.pointSize.width
        let pageHeight = page.pageSize.pointSize.height
        let normalizedY = MacDictationFlowCommit.openYOnPage(
            pageId: page.id,
            pageSize: CGSize(width: pageWidth, height: pageHeight)
        )

        let newElement = TextElementCommit.create(
            text: "",
            source: .typed,
            pageId: page.id,
            notebookId: notebook.id,
            normalizedRect: CGRect(
                x: MacDocPageLayout.normalizedHorizontalMargin(pageWidth: pageWidth),
                y: normalizedY,
                width: MacDocPageLayout.normalizedContentWidth(pageWidth: pageWidth),
                height: 0.08
            ),
            context: storage.context
        )
        if let id = newElement?.id {
            editingBlockID = id
            selectedElementID = id
        }
    }

    private func displaySize(for page: Page) -> CGSize {
        let base = page.pageSize.pointSize
        let scale = (680 / base.width) * editorZoom
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    private func pageBreak(before page: Page) -> some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
            Text("\(page.pageNumber)")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(theme.recessiveQuaternary)
                .monospacedDigit()
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
        }
        .padding(.vertical, 28)
        .accessibilityLabel("Page \(page.pageNumber)")
    }

    private var addPageFooter: some View {
        MacAddPageControl(
            onAddPage: {
                if let newPage = try? storage.createPage(in: notebook, after: pages.last?.pageNumber) {
                    MacStateUpdates.deferred {
                        selectedPageID = newPage.id
                        editingBlockID = nil
                    }
                }
            }
        )
    }
}

/// One page section — fixed page dimensions with elements placed
/// by normalized coordinates (matches iPad page bounds).
private struct MacDocPageSection: View {
    let page: Page
    let notebook: Notebook
    @Binding var selectedPageID: UUID?
    @Binding var editingBlockID: UUID?
    @Binding var selectedElementID: UUID?
    let editorZoom: CGFloat
    let onInsertTextAt: (CGPoint) -> Void
    var onWritingBegan: () -> Void = {}

    @Environment(\.theme) private var theme
    @EnvironmentObject private var storage: StorageService
    @Query private var elements: [PageElement]
    @State private var measuredHeights: [UUID: CGFloat] = [:]

    private static let fitWidth: CGFloat = 680

    init(
        page: Page,
        notebook: Notebook,
        selectedPageID: Binding<UUID?>,
        editingBlockID: Binding<UUID?>,
        selectedElementID: Binding<UUID?>,
        editorZoom: CGFloat,
        onInsertTextAt: @escaping (CGPoint) -> Void,
        onWritingBegan: @escaping () -> Void = {}
    ) {
        self.page = page
        self.notebook = notebook
        _selectedPageID = selectedPageID
        _editingBlockID = editingBlockID
        _selectedElementID = selectedElementID
        self.editorZoom = editorZoom
        self.onInsertTextAt = onInsertTextAt
        self.onWritingBegan = onWritingBegan
        let pid = page.id
        _elements = Query(
            filter: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil },
            sort: [
                SortDescriptor(\PageElement.normalizedY),
                SortDescriptor(\PageElement.normalizedX),
                SortDescriptor(\PageElement.zIndex),
            ]
        )
    }

    private var contentElements: [PageElement] {
        elements.filter { $0.kind != .stroke }
    }

    private var displaySize: CGSize {
        let base = page.pageSize.pointSize
        let scale = (Self.fitWidth / base.width) * editorZoom
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    private var contentWidth: CGFloat {
        max(40, displaySize.width - 2 * MacDocPageLayout.horizontalMargin)
    }

    private var contentBottom: CGFloat {
        displaySize.height - MacDocPageLayout.topMargin
    }

    private func stackTopOffset(for elementId: UUID) -> CGFloat {
        var offset = MacDocPageLayout.topMargin
        for element in contentElements {
            if element.id == elementId { break }
            let height = measuredHeights[element.id]
                ?? CGFloat(element.normalizedHeight) * displaySize.height
            offset += height + MacDocPageLayout.blockSpacing
        }
        return offset
    }

    private func maxBlockHeight(for elementId: UUID) -> CGFloat {
        max(24, contentBottom - stackTopOffset(for: elementId) - 6)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MacTemplateBackground(template: page.backgroundTemplate, theme: theme)
                .frame(width: displaySize.width, height: displaySize.height)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: MacDocPageLayout.blockSpacing) {
                ForEach(contentElements) { element in
                    flowBlock(element)
                }

                if let strokeElement = elements.first(where: { $0.kind == .stroke }) {
                    MacDocStrokeBlock(element: strokeElement)
                        .frame(maxWidth: contentWidth, alignment: .leading)
                } else if pageHasHandwriting {
                    MacDocLegacyStrokeBlock(page: page)
                        .frame(maxWidth: contentWidth, alignment: .leading)
                }

                Color.clear
                    .frame(minHeight: 48)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        MacStateUpdates.deferred {
                            selectedElementID = nil
                            editingBlockID = nil
                            onWritingBegan()
                            onInsertTextAt(CGPoint(x: contentWidth * 0.5, y: displaySize.height * 0.85))
                        }
                    }
            }
            .padding(.horizontal, MacDocPageLayout.horizontalMargin)
            .padding(.vertical, MacDocPageLayout.topMargin)
            .frame(width: displaySize.width, alignment: .topLeading)
            .onPreferenceChange(MacDocBlockHeightKey.self) { heights in
                measuredHeights.merge(heights) { _, new in new }
            }
        }
        .frame(width: displaySize.width)
        .frame(minHeight: displaySize.height, alignment: .topLeading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(theme.borderSubtle, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Page \(page.pageNumber)")
        .onAppear {
            MacStateUpdates.deferred { MacPageOverflow.reconcilePage(page.id) }
        }
    }

    @ViewBuilder
    private func flowBlock(_ element: PageElement) -> some View {
        let blockSelected = selectedElementID == element.id || editingBlockID == element.id
        let blockEditing = editingBlockID == element.id

        MacDocBlock(
            element: element,
            page: page,
            notebook: notebook,
            isEditing: blockEditing,
            isSelected: blockSelected,
            onBeginEdit: {
                MacStateUpdates.deferred {
                    selectedPageID = page.id
                    selectedElementID = element.id
                    editingBlockID = element.id
                }
            },
            onEndEdit: {
                MacStateUpdates.deferred {
                    if editingBlockID == element.id {
                        editingBlockID = nil
                    }
                }
            },
            onSelect: {
                MacStateUpdates.deferred {
                    selectedPageID = page.id
                    selectedElementID = element.id
                    editingBlockID = nil
                }
            },
            onWritingBegan: onWritingBegan,
            pageDisplayHeight: displaySize.height,
            stackTopOffset: stackTopOffset(for: element.id),
            maxBlockHeight: maxBlockHeight(for: element.id)
        )
        .frame(maxWidth: contentWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: MacDocBlockHeightKey.self,
                    value: [element.id: geo.size.height]
                )
            }
        )
        .id(element.id)
        .zIndex(blockEditing ? 50 : Double(element.zIndex))
    }

    private var pageHasHandwriting: Bool {
        if elements.contains(where: { $0.kind == .stroke }) { return true }
        guard let data = storage.strokeData(for: page), !data.isEmpty else { return false }
        return (try? PKDrawing(data: data))?.bounds.isEmpty == false
    }
}

private struct MacDocStrokeBlock: View {
    let element: PageElement
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("handwriting from iPad")
                .font(.system(size: 8))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveQuaternary)
            if let image = renderedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 420, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    private var renderedImage: NSImage? {
        guard let data = element.strokeContent?.strokeData,
              !data.isEmpty else { return nil }
        return MacStrokeThumbnailCache.image(
            cacheKey: element.id.uuidString,
            strokeData: data
        )
    }
}

private struct MacDocLegacyStrokeBlock: View {
    let page: Page
    @EnvironmentObject private var storage: StorageService
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("handwriting from iPad")
                .font(.system(size: 8))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveQuaternary)
            if let image = renderedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 420, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    private var renderedImage: NSImage? {
        guard let data = storage.strokeData(for: page),
              !data.isEmpty else { return nil }
        return MacStrokeThumbnailCache.image(
            cacheKey: "legacy-\(page.id.uuidString)",
            strokeData: data
        )
    }
}

/// Footer affordance — only creates a page on ⌃-click (or via menu/shortcut).
private struct MacAddPageControl: View {
    let onAddPage: () -> Void
    @Environment(\.theme) private var theme
    @State private var isControlPressed = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 10))
            Text(isControlPressed ? "add page" : "⌃-click to add page")
                .font(.system(size: 10))
                .tracking(0.12)
                .textCase(.uppercase)
        }
        .foregroundStyle(theme.recessiveTertiary)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: isControlPressed = NSEvent.modifierFlags.contains(.control)
            case .ended: isControlPressed = false
            }
        }
        .onTapGesture {
            guard NSEvent.modifierFlags.contains(.control) else { return }
            onAddPage()
        }
        .accessibilityLabel("Control-click to add page")
    }
}
