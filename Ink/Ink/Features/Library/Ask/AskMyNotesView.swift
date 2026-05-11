import SwiftUI

/// Conversational search over the user's notes — entirely on-device
/// via Apple's Foundation Models framework. No network, no third-
/// party AI APIs. The retrieval step uses the local search index;
/// the answer is streamed from the on-device language model with
/// only the user's notes as context.
///
/// Editorial style matches Settings — heavy 22pt lowercase title,
/// plain text response (no bubbles), recessive citation pills below.
/// Designed to feel like reading notes, not chatting with an
/// assistant.
struct AskMyNotesView: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var answer: String = ""
    @State private var citations: [AskCitation] = []
    @State private var hasSubmitted: Bool = false
    @State private var isStreaming: Bool = false
    @State private var noMatches: Bool = false
    /// Tracks the most recent submit's scope. `nil` means
    /// search-everywhere; non-nil means the user picked a notebook
    /// from the empty-state picker and we re-ran scoped. Used to
    /// decide between the two empty-state copies.
    @State private var lastSubmitScopedNotebookId: UUID?
    /// Mirrors `SearchIndexService.shared.isLoaded`. Flipped on the
    /// `.searchIndexLoaded` notification so the "still indexing…"
    /// placeholder transitions to the live input without polling.
    @State private var indexLoaded: Bool = SearchIndexService.shared.isLoaded
    @State private var streamTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    private static let hairlineColour = Color(
        light: Color(hex: "#f5f5f5"),
        dark:  Color(hex: "#1f1f1d")
    )

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Self.hairlineColour)
            scrollableAnswer
            inputBar
        }
        .background(Color(.systemBackground))
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            inputFocused = true
            // Re-read in case the index loaded between the parent
            // showing this sheet and the sheet's first body
            // evaluation. The notification observer below covers
            // the live transition.
            indexLoaded = SearchIndexService.shared.isLoaded
        }
        .onDisappear { streamTask?.cancel() }
        .onReceive(
            NotificationCenter.default.publisher(for: .searchIndexLoaded)
        ) { _ in indexLoaded = true }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ask your notes")
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(Color.inkNearBlack)
                Spacer()
                Button("done") { dismiss() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.brandAccent)
            }
            // Honest disclosure of what the index covers. Sits
            // directly under the heading, always visible, so the
            // user never wonders whether handwritten ink is in
            // scope (it is, via OCR — but not perfect realtime
            // reading).
            Text("searches typed notes, transcripts, and recognised handwriting")
                .font(.system(size: 11).italic())
                .foregroundStyle(Color.inkRecessiveTertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    // MARK: Scrollable answer area

    private var scrollableAnswer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !indexLoaded {
                    // Pre-load gate. The persisted index is read off
                    // the main actor by `SearchIndexService.loadAsync`
                    // from the library's `.task`; the user can land
                    // here before that completes on a cold launch.
                    // Disabling the input prevents a confusing
                    // "I couldn't find anything" against an empty
                    // in-memory dict.
                    Text("still indexing your notes, try again in a moment")
                        .font(.system(size: 13).italic())
                        .foregroundStyle(Color.inkRecessiveTertiary)
                } else if !hasSubmitted {
                    emptyState
                } else if noMatches {
                    if lastSubmitScopedNotebookId == nil {
                        // First failed search — global. Offer the
                        // notebook picker so the user can retry with
                        // a narrower scope (a specific notebook
                        // sometimes has matches the global keyword
                        // path missed because they were spread thin).
                        Text("I couldn't find anything across all your notes. Want me to search a specific notebook?")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.inkRecessivePrimary)
                        notebookPicker
                    } else {
                        // Scoped retry also empty — game over.
                        Text("I couldn't find anything in that notebook either.")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.inkRecessivePrimary)
                    }
                } else {
                    // Plain text response — 15pt regular, no bubble,
                    // no card. Reads like prose, matches the editorial
                    // tone of the rest of the chrome.
                    Text(answer)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.inkNearBlack)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if !citations.isEmpty {
                        citationsRow
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Notebook picker (empty-state fallback)

    /// Scrollable list of notebook pills sorted by most-recently
    /// opened. Tapping one re-runs the same query scoped to that
    /// notebook only.
    private var notebookPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("notebooks")
                .font(.system(size: 8))
                .tracking(0.08)
                .textCase(.uppercase)
                .foregroundStyle(Color.inkRecessiveTertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pickerNotebooks, id: \.id) { nb in
                        Button {
                            retryScoped(to: nb.id)
                        } label: {
                            Text(nb.title)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.inkRecessivePrimary)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .strokeBorder(Self.hairlineColour, lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Source list for the picker pills. `fetchRecentNotebooks`
    /// returns by last-opened first; we backfill with the rest of
    /// the library at the tail so users can still drill into a
    /// rarely-opened notebook if the query lives there.
    private var pickerNotebooks: [Notebook] {
        let storage = StorageService.shared
        var ordered = storage.fetchRecentNotebooks(limit: 50)
        let seen = Set(ordered.map(\.id))
        let rest = storage.fetchAllNotebooks().filter { !seen.contains($0.id) }
        ordered.append(contentsOf: rest)
        return ordered
    }

    /// Re-run the current query scoped to a specific notebook.
    /// Carries the query text forward; clears the picker by
    /// flipping `lastSubmitScopedNotebookId` so the empty-state
    /// branch resolves to the final "in that notebook either"
    /// copy if this retrieval also misses.
    private func retryScoped(to notebookId: UUID) {
        submit(scopedTo: notebookId)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ask anything you've written down.")
                .font(.system(size: 13).italic())
                .foregroundStyle(Color.inkRecessiveTertiary)
            Text("answers cite the notebooks and pages they came from.")
                .font(.system(size: 11).italic())
                .foregroundStyle(Color.inkRecessiveQuaternary)
        }
        .padding(.top, 12)
    }

    // MARK: Citations

    private var citationsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("sources")
                .font(.system(size: 8))
                .tracking(0.08)
                .textCase(.uppercase)
                .foregroundStyle(Color.inkRecessiveTertiary)

            FlowLayout(spacing: 6) {
                ForEach(citations) { citation in
                    Button {
                        openCitation(citation)
                    } label: {
                        Text("\(citation.notebookTitle), p.\(citation.pageNumber)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.inkRecessivePrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .strokeBorder(Self.hairlineColour, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("what do you want to know?", text: $query)
                .font(.system(size: 14))
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { submit() }
                .disabled(isStreaming || !indexLoaded)

            if isStreaming {
                Button { streamTask?.cancel(); isStreaming = false } label: {
                    Text("stop")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.inkRecessiveTertiary)
                }
                .buttonStyle(.plain)
            } else {
                Button { submit() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !indexLoaded)
                                ? Color.inkRecessiveQuaternary
                                : Color.brandAccent
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !indexLoaded
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Self.hairlineColour).frame(height: 0.5)
        }
    }

    // MARK: Submit + stream

    private func submit(scopedTo notebookId: UUID? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        // Index-readiness gate. Should be rare — the library
        // kicks off `loadAsync` from its first frame — but a user
        // who opens Ask before the disk read completes shouldn't
        // see "couldn't find anything" against an empty in-memory
        // dict.
        guard indexLoaded else { return }
        hasSubmitted = true
        noMatches    = false
        answer       = ""
        citations    = []
        isStreaming  = true
        lastSubmitScopedNotebookId = notebookId

        // Retrieve relevant page-level context from the index.
        // Scope filter is `nil` for the first submit; populated by
        // the empty-state notebook picker for retries.
        let retrieved = AskRetrieval.retrieve(
            query: trimmed,
            limit: 5,
            scopedTo: notebookId
        )
        guard !retrieved.isEmpty else {
            // No relevant notes — short-circuit before invoking the
            // model. The view body branches on
            // `lastSubmitScopedNotebookId` to pick the right
            // empty-state copy (offer-picker vs final).
            noMatches    = true
            isStreaming  = false
            return
        }

        // Map the retrieval result into citations for the source row
        // BEFORE the model starts streaming — they're already known
        // from the retrieval pass, no reason to wait.
        citations = retrieved.map { hit in
            AskCitation(
                notebookId:    hit.notebookId,
                notebookTitle: hit.notebookTitle,
                pageId:        hit.pageId,
                pageNumber:    hit.pageNumber
            )
        }

        let context = retrieved.map { hit in
            """
            [\(hit.notebookTitle), Page \(hit.pageNumber)]
            \(hit.snippet)
            """
        }.joined(separator: "\n\n---\n\n")

        // Stream the response. The spec is explicit: no spinner during
        // retrieval; just begin streaming as soon as the model
        // produces output. The empty `answer` while waiting for the
        // first token reads as "thinking" without any chrome.
        streamTask?.cancel()
        streamTask = Task { @MainActor in
            let stream = IntelligenceService.shared.askMyNotesStream(
                question: trimmed,
                context:  context
            )
            for await partial in stream {
                answer = partial
            }
            isStreaming = false
        }
    }

    private func openCitation(_ citation: AskCitation) {
        // Wire to the existing deep-link mechanism: setting
        // `deepLinkPageId` then `selectedNotebookId` opens the
        // notebook scrolled to that page on the Library's existing
        // observer.
        libraryViewModel.deepLinkPageId = citation.pageId
        libraryViewModel.selectedNotebookId = citation.notebookId
        dismiss()
    }
}

// MARK: - Citation model

struct AskCitation: Identifiable, Hashable {
    var id: String { "\(notebookId.uuidString)-\(pageNumber)" }
    let notebookId: UUID
    let notebookTitle: String
    let pageId: UUID?
    let pageNumber: Int
}

// MARK: - Retrieval helper

/// Pulls the top-N most relevant pages for an Ask query out of the
/// search index. Each hit carries the notebook title + page number
/// for citation and a ≤200-char snippet for the model prompt
/// context. Runs synchronously — keyword path only — so the UI can
/// branch to "I couldn't find anything" before deciding to invoke
/// the model.
enum AskRetrieval {

    struct Hit {
        let notebookId:    UUID
        let notebookTitle: String
        let pageId:        UUID?
        let pageNumber:    Int
        let snippet:       String
    }

    static func retrieve(
        query: String,
        limit: Int,
        scopedTo notebookId: UUID? = nil
    ) -> [Hit] {
        let storage = StorageService.shared
        let raw     = SearchIndexService.shared.search(query: query)
        let titleById = Dictionary(
            uniqueKeysWithValues: storage.fetchAllNotebooks().map { ($0.id, $0.title) }
        )

        // Scope filter is applied BEFORE the limit so a "search a
        // specific notebook" follow-up gets the top-N hits from
        // that notebook rather than the global top-N that happen
        // to fall inside it.
        let scoped: [SearchResult] = {
            guard let notebookId else { return raw }
            return raw.filter { $0.notebookId == notebookId }
        }()

        let hits = scoped
            .filter { $0.pageNumber != nil }
            .prefix(limit)
            .map { result -> Hit in
                Hit(
                    notebookId:    result.notebookId,
                    notebookTitle: titleById[result.notebookId] ?? "Unknown",
                    pageId:        result.pageId,
                    pageNumber:    result.pageNumber ?? 0,
                    snippet:       String(result.context.prefix(200))
                )
            }
        return Array(hits)
    }
}

// MARK: - FlowLayout

/// Minimal flow-layout container — pills wrap to the next line when
/// they overflow. Used by the sources row so a long list of
/// citations doesn't push past the sheet's edge.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > maxW {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
