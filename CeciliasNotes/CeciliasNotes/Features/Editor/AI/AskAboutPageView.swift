import SwiftUI

/// Contextual Q&A over the current page's typed content — uses
/// `PageContextBuilder` + on-device streaming, same stack as
/// library Ask but scoped to one page.
struct AskAboutPageView: View {
    let page: Page
    let notebookTitle: String
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var answer = ""
    @State private var hasSubmitted = false
    @State private var isStreaming = false
    @State private var isEmptyPage = false
    @State private var streamTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.hairline)
            if IntelligenceService.shared.canRun {
                scrollableAnswer
                inputBar
            } else {
                Spacer(minLength: 0)
                Text("available on iOS 26 / macOS 26 with Apple Intelligence")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(theme.recessiveTertiary)
                    .padding(.horizontal, 24)
                Spacer(minLength: 0)
            }
        }
        .background(theme.surface)
#if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
#endif
        .onAppear { inputFocused = true }
        .onDisappear { streamTask?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ask about this page")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(theme.foreground)
            Text("page \(page.pageNumber) · \(notebookTitle.lowercased())")
                .font(.system(size: 11).italic())
                .foregroundStyle(theme.recessiveTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var scrollableAnswer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isEmptyPage {
                    Text("this page has no typed content to ask about yet.")
                        .font(.system(size: 13).italic())
                        .foregroundStyle(theme.recessiveTertiary)
                } else if hasSubmitted {
                    Text(answer.isEmpty && !isStreaming ? "couldn't find an answer on this page." : answer)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.foreground)
                        .textSelection(.enabled)
                } else {
                    Text("ask a question about what's on this page.")
                        .font(.system(size: 13).italic())
                        .foregroundStyle(theme.recessiveQuaternary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

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
                        .foregroundStyle(theme.recessiveTertiary)
                }
                .buttonStyle(.plain)
            } else {
                Button { submit() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? theme.recessiveQuaternary
                                : theme.accent
                        )
                }
                .buttonStyle(.plain)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        let context = PageContextBuilder.build(page: page, notebookTitle: notebookTitle)
        guard !context.isEmpty else {
            isEmptyPage = true
            hasSubmitted = true
            return
        }

        hasSubmitted = true
        isEmptyPage = false
        answer = ""
        isStreaming = true

        streamTask?.cancel()
        streamTask = Task {
            let stream = IntelligenceService.shared.askMyNotesStream(
                question: trimmed,
                context: context.toPrompt(),
                scopeTitle: notebookTitle
            )
            for await partial in stream {
                guard !Task.isCancelled else { break }
                answer = partial
            }
            isStreaming = false
        }
    }
}
