import AppKit
import SwiftData
import SwiftUI

/// Linear document view for Mac — presents an entire notebook as one
/// continuous doc that grows top-to-bottom, wraps to a Google-Docs-style
/// reading column, and treats every page's elements as inline blocks
/// in reading order.
///
/// Behaviour by element kind:
///   text / stickyNote   → editable rich text (reuses `MacRichTextEditor`).
///   image                → inline image, right-click to delete / open.
///   stroke / shape       → read-only render of the iPad ink (Mac cannot
///                          author strokes); block is dimmed with a
///                          "handwritten on iPad" eyebrow.
///   pdfPage              → inline PDF thumbnail; opens Canvas view on tap.
///   audio                → inline mini-player + transcript block.
///   highlight            → inline text run with the annotation colour.
///
/// The block editor's writing surface is one big NSTextView (via
/// MacRichTextEditor); system dictation (`fn fn` / Edit → Start Dictation)
/// works there out of the box. The toolbar Dictate button posts
/// `.macStartDictation` which the active text block converts to
/// `NSApp.sendAction("startDictation:")`.
struct MacDocModeView: View {
    let notebook: Notebook
    let pages: [Page]

    @Environment(\.theme) private var theme
    @EnvironmentObject private var storage: StorageService

    @State private var editingTextID: UUID?
    @State private var focusedBlockID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(pages) { page in
                    MacDocPageSection(
                        page: page,
                        notebook: notebook,
                        editingTextID: $editingTextID,
                        focusedBlockID: $focusedBlockID
                    )
                }
                addPageFooter
            }
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 64)
            .padding(.vertical, 48)
        }
        .background(theme.background)
    }

    private var addPageFooter: some View {
        Button {
            _ = try? storage.createPage(in: notebook, after: pages.last?.pageNumber)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 10))
                Text("add page")
                    .font(.system(size: 10))
                    .tracking(0.12)
                    .textCase(.uppercase)
            }
            .foregroundStyle(theme.recessiveTertiary)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

/// One page's worth of blocks, headed by a hairline eyebrow.
private struct MacDocPageSection: View {
    let page: Page
    let notebook: Notebook
    @Binding var editingTextID: UUID?
    @Binding var focusedBlockID: UUID?

    @Environment(\.theme) private var theme
    @EnvironmentObject private var storage: StorageService
    @Query private var elements: [PageElement]

    init(page: Page, notebook: Notebook, editingTextID: Binding<UUID?>, focusedBlockID: Binding<UUID?>) {
        self.page = page
        self.notebook = notebook
        _editingTextID = editingTextID
        _focusedBlockID = focusedBlockID
        let pid = page.id
        _elements = Query(
            filter: #Predicate<PageElement> { $0.pageId == pid && $0.isDeleted == false },
            sort: [
                SortDescriptor(\PageElement.normalizedY),
                SortDescriptor(\PageElement.normalizedX),
                SortDescriptor(\PageElement.zIndex),
            ]
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageEyebrow
            if elements.isEmpty {
                emptyPageBlock
            } else {
                ForEach(elements) { element in
                    MacDocBlock(
                        element: element,
                        page: page,
                        notebook: notebook,
                        isFocused: focusedBlockID == element.id
                    )
                    .onTapGesture { focusedBlockID = element.id }
                }
            }
            appendTextBlockButton
        }
    }

    private var pageEyebrow: some View {
        HStack(spacing: 10) {
            Text("page \(page.pageNumber)")
                .font(.system(size: 8, weight: .regular))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveTertiary)
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
        }
    }

    private var emptyPageBlock: some View {
        Text("start writing…")
            .font(.system(size: 15).italic())
            .foregroundStyle(theme.foregroundSubtle)
            .padding(.vertical, 8)
            .onTapGesture { appendTextBlock() }
    }

    private var appendTextBlockButton: some View {
        Button {
            appendTextBlock()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.append")
                    .font(.system(size: 10))
                Text("add block")
                    .font(.system(size: 10))
                    .tracking(0.12)
                    .textCase(.uppercase)
            }
            .foregroundStyle(theme.recessiveQuaternary)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func appendTextBlock() {
        let lastY = elements.map(\.normalizedY).max() ?? 0.05
        let newElement = TextElementCommit.create(
            text: "",
            source: .typed,
            pageId: page.id,
            notebookId: notebook.id,
            normalizedRect: CGRect(
                x: 0.08,
                y: min(0.95, lastY + 0.12),
                width: 0.84,
                height: 0.08
            ),
            context: storage.context
        )
        if let id = newElement?.id {
            focusedBlockID = id
        }
    }
}
