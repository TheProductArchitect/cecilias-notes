import SwiftUI

/// Scoped search inside the open notebook — ⌘⇧F from the editor.
struct MacInNotebookSearchView: View {
    let notebook: Notebook
    @Binding var selectedPageID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("search this notebook")
                .font(.system(size: 8, weight: .regular))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveTertiary)

            TextField("find in \(notebook.title.lowercased())", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runSearch() }
                .onChange(of: query) { _, newValue in
                    if newValue.isEmpty { results = [] }
                }

            if isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty && !query.isEmpty {
                Text("no matches in this notebook.")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(theme.recessiveTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(results.enumerated()), id: \.offset) { _, result in
                    Button {
                        if let pageId = result.pageId {
                            selectedPageID = pageId
                        }
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let pageNumber = result.pageNumber {
                                Text("page \(pageNumber)")
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(theme.foreground)
                            }
                            Text(result.context)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.recessiveSecondary)
                                .lineLimit(3)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
        .background(theme.surfaceElevated)
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; return }
        isSearching = true
        Task {
            let found = await SearchIndexService.shared.search(
                inNotebook: notebook.id,
                query: trimmed
            )
            await MainActor.run {
                results = found
                isSearching = false
            }
        }
    }
}
