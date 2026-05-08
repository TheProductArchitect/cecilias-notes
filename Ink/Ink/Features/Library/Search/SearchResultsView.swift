import SwiftUI

struct SearchResultsView: View {
    let results: GroupedSearchResults
    let query: String
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if !results.notebookMatches.isEmpty {
                    resultSection(
                        title: "Notebooks",
                        results: results.notebookMatches
                    )
                }
                if !results.textBlockMatches.isEmpty {
                    resultSection(
                        title: "Notes",
                        results: results.textBlockMatches
                    )
                }
                if !results.transcriptionMatches.isEmpty {
                    resultSection(
                        title: "Transcriptions",
                        results: results.transcriptionMatches
                    )
                }
            }
            .padding(.bottom, Ink.Spacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Section

    private func resultSection(title: String, results: [SearchResult]) -> some View {
        Section {
            ForEach(results, id: \.notebookId) { result in
                SearchResultRow(result: result, query: query, viewModel: viewModel)
                InkDivider()
                    .padding(.leading, 56)
            }
        } header: {
            Text(title)
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
                .padding(.horizontal, Ink.Spacing.lg)
                .padding(.vertical, Ink.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.inkBackgroundPrimary)
        }
    }
}

// MARK: - Single result row

private struct SearchResultRow: View {
    let result: SearchResult
    let query: String
    @ObservedObject var viewModel: LibraryViewModel

    private var notebook: Notebook? { viewModel.notebook(id: result.notebookId) }

    var body: some View {
        Button {
            viewModel.selectedNotebookId = result.notebookId
            viewModel.deactivateSearch()
        } label: {
            HStack(spacing: Ink.Spacing.md) {
                // Cover colour circle
                Circle()
                    .fill(notebook.flatMap { Color(UIColor(hex: $0.coverColorHex)) } ?? Color.inkTextTertiary)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: Ink.Spacing.micro) {
                    // Notebook title
                    Text(notebook?.title ?? "Unknown")
                        .font(.inkSubhead)
                        .foregroundColor(.inkTextPrimary)
                        .lineLimit(1)

                    // Context snippet with matched text highlighted
                    if result.type != .notebookTitle {
                        Text(highlightedSnippet(text: result.context, query: query))
                            .font(.inkFootnote)
                            .foregroundColor(.inkTextSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .fontWeight(.medium)
                    .foregroundColor(.inkTextTertiary)
            }
            .padding(.horizontal, Ink.Spacing.lg)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.inkPressable)
    }

    /// Returns an AttributedString with the first occurrence of `query`
    /// coloured in accent.primary.
    private func highlightedSnippet(text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let lower      = text.lowercased()
        let needle     = query.lowercased()
        guard let range = lower.range(of: needle) else { return attributed }

        // Map String.Index range to AttributedString range
        let start = AttributedString.Index(range.lowerBound, within: attributed)
        let end   = AttributedString.Index(range.upperBound, within: attributed)
        if let start, let end {
            attributed[start..<end].foregroundColor = UIColor.inkAccentPrimary
        }
        return attributed
    }
}
