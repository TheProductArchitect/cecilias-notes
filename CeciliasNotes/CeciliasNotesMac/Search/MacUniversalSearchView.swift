import SwiftUI

struct MacUniversalSearchView: View {
    @ObservedObject var state: MacLibraryState
    let notebooks: [Notebook]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search all notebooks", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runSearch() }
                .onChange(of: query) { _, newValue in
                    if newValue.isEmpty { results = [] }
                }

            if isSearching {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty && !query.isEmpty {
                ContentUnavailableView("No results", systemImage: "magnifyingglass")
            } else {
                List(results, id: \.self) { result in
                    Button {
                        open(result)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notebookTitle(for: result.notebookId))
                                .font(.headline)
                            if let pageNumber = result.pageNumber {
                                Text("Page \(pageNumber)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(result.context)
                                .font(.callout)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .frame(width: 560, height: 420)
        .onAppear { runSearch() }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; return }
        isSearching = true
        Task {
            let found = await SearchIndexService.shared.combinedSearch(query: trimmed)
            await MainActor.run {
                results = found
                isSearching = false
            }
        }
    }

    private func open(_ result: SearchResult) {
        MacStateUpdates.deferred {
            state.selectedNotebookID = result.notebookId
            if let pageId = result.pageId {
                state.selectedPageID = pageId
            }
        }
        dismiss()
    }

    private func notebookTitle(for id: UUID) -> String {
        notebooks.first { $0.id == id }?.title ?? "Notebook"
    }
}

extension SearchResult: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(notebookId)
        hasher.combine(pageId)
        hasher.combine(context)
        hasher.combine(type)
    }

    public static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.notebookId == rhs.notebookId
            && lhs.pageId == rhs.pageId
            && lhs.context == rhs.context
            && lhs.type == rhs.type
    }
}
