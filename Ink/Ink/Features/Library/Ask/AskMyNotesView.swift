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
        .onAppear { inputFocused = true }
        .onDisappear { streamTask?.cancel() }
    }

    // MARK: Header

    private var header: some View {
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
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    // MARK: Scrollable answer area

    private var scrollableAnswer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !hasSubmitted {
                    emptyState
                } else if noMatches {
                    Text("I couldn't find anything in your notes about that.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.inkRecessivePrimary)
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
                .disabled(isStreaming)

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
                        .foregroundStyle(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.inkRecessiveQuaternary
                            : Color.brandAccent
                        )
                }
                .buttonStyle(.plain)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Self.hairlineColour).frame(height: 0.5)
        }
    }

    // MARK: Submit + stream

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        hasSubmitted = true
        noMatches    = false
        answer       = ""
        citations    = []
        isStreaming  = true

        // Retrieve relevant page-level context from the index.
        let retrieved = AskRetrieval.retrieve(query: trimmed, limit: 5)
        guard !retrieved.isEmpty else {
            // No relevant notes — short-circuit before invoking the
            // model. Spec is explicit about this empty-state copy.
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

    static func retrieve(query: String, limit: Int) -> [Hit] {
        let storage = StorageService.shared
        let raw     = SearchIndexService.shared.search(query: query)
        let titleById = Dictionary(
            uniqueKeysWithValues: storage.fetchAllNotebooks().map { ($0.id, $0.title) }
        )

        let hits = raw
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
