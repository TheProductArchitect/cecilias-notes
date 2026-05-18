import SwiftUI

/// Grouped search results — notebooks, then text blocks, then audio
/// transcripts, then handwriting (OCR is the lowest-confidence
/// surface, so it sits at the bottom and is labelled "handwriting"
/// in recessive grey).
struct SearchResultsView: View {
    let results: GroupedSearchResults
    let query: String
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if results.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if !results.notebookMatches.isEmpty {
                            resultSection(title: "Notebooks",
                                          results: results.notebookMatches,
                                          showHandwritingBadge: false)
                        }
                        if !results.textBlockMatches.isEmpty {
                            resultSection(title: "Notes",
                                          results: results.textBlockMatches,
                                          showHandwritingBadge: false)
                        }
                        if !results.transcriptionMatches.isEmpty {
                            resultSection(title: "Transcripts",
                                          results: results.transcriptionMatches,
                                          showHandwritingBadge: false)
                        }
                        if !results.handwritingMatches.isEmpty {
                            resultSection(title: "Handwriting",
                                          results: results.handwritingMatches,
                                          showHandwritingBadge: true)
                        }
                    }
                    .padding(.bottom, CeciliasNotes.Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 80)
            Text("nothing found")
                .font(.system(size: 13).italic())
                .foregroundStyle(theme.recessiveTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Section

    private func resultSection(
        title: String,
        results: [SearchResult],
        showHandwritingBadge: Bool
    ) -> some View {
        Section {
            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                SearchResultRow(
                    result: result,
                    query: query,
                    showHandwritingBadge: showHandwritingBadge,
                    viewModel: viewModel
                )
                CeciliasNotesDivider()
                    .padding(.leading, 56)
            }
        } header: {
            Text(title)
                .font(.ceciliasNotesCaption)
                .foregroundColor(theme.foregroundSubtle)
                .padding(.horizontal, CeciliasNotes.Spacing.lg)
                .padding(.vertical, CeciliasNotes.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.background)
        }
    }
}

// MARK: - Single result row

private struct SearchResultRow: View {
    let result: SearchResult
    let query: String
    let showHandwritingBadge: Bool
    @Environment(\.theme) private var theme
    @ObservedObject var viewModel: LibraryViewModel

    private var notebook: Notebook? { viewModel.notebook(id: result.notebookId) }

    var body: some View {
        Button {
            // Page-scoped matches deep-link to the specific page.
            // Notebook-title matches just open the notebook at its
            // last position (handled by the editor's resume logic).
            if let pageId = result.pageId {
                viewModel.deepLinkPageId = pageId
            }
            viewModel.selectedNotebookId = result.notebookId
            viewModel.deactivateSearch()
        } label: {
            HStack(alignment: .top, spacing: 0) {
                // 2pt leading rule in the notebook's cover colour —
                // the same accent the cards on the home grid wear,
                // so the rows feel like they belong to specific
                // notebooks rather than a flat list.
                Rectangle()
                    .fill(notebook.flatMap { Color(UIColor(hex: $0.coverColorHex)) }
                          ?? theme.foregroundSubtle)
                    .frame(width: 2)
                    .padding(.trailing, CeciliasNotes.Spacing.md)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(notebook?.title ?? "Unknown")
                            .font(.ceciliasNotesSubhead)
                            .foregroundColor(theme.foreground)
                            .lineLimit(1)

                        if let pageNumber = result.pageNumber {
                            Text("page \(pageNumber)")
                                .font(.system(size: 11))
                                .foregroundColor(theme.foregroundSubtle)
                                .monospacedDigit()
                        }

                        Spacer()
                    }

                    if result.type != .notebookTitle {
                        // Snippet, plus an inline italic "— handwriting"
                        // suffix when the match came from OCR.
                        // Inline italic recessive copy — not a chip
                        // or filled label — matches the design
                        // language's use of italic copy for supporting
                        // information throughout the app.
                        Text(snippetWithOCRSuffix())
                            .font(.ceciliasNotesFootnote)
                            .foregroundColor(theme.foregroundMuted)
                            .lineLimit(2)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .fontWeight(.medium)
                    .foregroundColor(theme.foregroundSubtle)
                    .padding(.leading, CeciliasNotes.Spacing.sm)
            }
            .padding(.horizontal, CeciliasNotes.Spacing.lg)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
    }

    /// Builds the per-row snippet:
    ///   • the ±40-char window around the query, with every match
    ///     bolded + accent-coloured.
    ///   • a recessive italic "— handwriting" suffix when the row
    ///     came from OCR. Lives inline rather than as a chip so the
    ///     chrome stays consistent with the rest of the app's
    ///     italic-recessive supporting-copy pattern.
    private func snippetWithOCRSuffix() -> AttributedString {
        var attributed = highlightedSnippet(text: result.context, query: query)
        if showHandwritingBadge {
            var suffix = AttributedString("  — handwriting")
            suffix.font = .system(size: 11).italic()
            suffix.foregroundColor = UIColor(ThemeManager.shared.current.foregroundSubtle)
            attributed.append(suffix)
        }
        return attributed
    }

    /// Bolds every occurrence of `query` (case-insensitive) in the
    /// snippet. Multiple hits in a single ±40-char window all get
    /// highlighted — useful when a transcript repeats the term.
    private func highlightedSnippet(text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let lower      = text.lowercased()
        let needle     = query.lowercased()
        guard !needle.isEmpty else { return attributed }

        var searchStart = lower.startIndex
        while let r = lower.range(of: needle, range: searchStart..<lower.endIndex) {
            if let start = AttributedString.Index(r.lowerBound, within: attributed),
               let end   = AttributedString.Index(r.upperBound, within: attributed) {
                attributed[start..<end].font = .ceciliasNotesFootnote.bold()
                attributed[start..<end].foregroundColor = UIColor(ThemeManager.shared.current.accent)
            }
            searchStart = r.upperBound
        }
        return attributed
    }
}
