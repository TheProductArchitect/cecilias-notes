#if os(iOS)
import SwiftUI

/// Scoped full-text search inside the open notebook. Used from the
/// editor on iPad/iPhone (Mac uses `MacInNotebookSearchView`).
struct InNotebookSearchView: View {
    let notebook: Notebook
    var onSelectPage: (UUID) -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("nothing found in this notebook.")
                        .font(.system(size: 13).italic())
                        .foregroundStyle(theme.recessiveTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    Text("search typed notes, transcripts, and handwriting in this notebook.")
                        .font(.ceciliasNotesSubhead)
                        .foregroundStyle(theme.foregroundMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, CeciliasNotes.Spacing.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(Array(results.enumerated()), id: \.offset) { _, result in
                        Button {
                            if let pageId = result.pageId {
                                onSelectPage(pageId)
                            }
                            onDismiss()
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
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Find in Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Find in \(notebook.title)")
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: query) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results = []
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Search") { runSearch() }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; return }
        isSearching = true
        let notebookId = notebook.id
        Task {
            let found = await SearchIndexService.shared.search(
                inNotebook: notebookId,
                query: trimmed
            )
            await MainActor.run {
                results = found
                isSearching = false
            }
        }
    }
}
#endif
