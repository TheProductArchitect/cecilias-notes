import SwiftData
import SwiftUI

/// Drag-to-reorder notebook pages — mirrors iPad page-strip reordering.
struct MacPageOrderSheet: View {
    let notebook: Notebook
    @Binding var selectedPageID: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storage: StorageService

    @State private var pages: [Page] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("page order")
                .font(.system(size: 8))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveTertiary)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            List {
                ForEach(pages) { page in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.recessiveQuaternary)
                        Text("Page \(page.pageNumber)")
                            .font(.system(size: 13))
                        if pageIsPDFBacked(page) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.recessiveTertiary)
                                .help("PDF-backed page")
                        }
                        Spacer()
                        if selectedPageID == page.id {
                            Image(systemName: "eye")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedPageID = page.id
                    }
                }
                .onMove(perform: movePages)
            }
            .listStyle(.inset)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 360, height: 440)
        .onAppear { reloadPages() }
    }

    private func reloadPages() {
        pages = storage.fetchPages(in: notebook)
    }

    private func pageIsPDFBacked(_ page: Page) -> Bool {
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )
        return ((try? storage.context.fetch(descriptor)) ?? []).contains { $0.kind == .pdfPage }
    }

    private func movePages(from source: IndexSet, to destination: Int) {
        guard let fromIndex = source.first else { return }
        let moving = pages[fromIndex]
        var updated = pages
        updated.move(fromOffsets: source, toOffset: destination)
        guard let newIndex = updated.firstIndex(where: { $0.id == moving.id }) else { return }
        let targetNumber = newIndex + 1
        guard MacPageEditing.movePage(moving, to: targetNumber, storage: storage) else { return }
        reloadPages()
        selectedPageID = moving.id
    }
}
