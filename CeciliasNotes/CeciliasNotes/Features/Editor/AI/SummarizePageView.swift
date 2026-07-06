import SwiftUI

/// Result sheet for the "Summarize this page" capability. Presented
/// from the editor's more-menu via `ModalPresenter`. Owns the full
/// flow: build the `PageContext`, call `AIService.summarizePage`,
/// and render one of three phases — loading, the summary with
/// actions, or an error with the appropriate user message.
///
/// The capability is intentionally simple in v1: no streaming, no
/// history, no editing the summary in place. The actions mirror the
/// spec — Insert as text, Copy, Try again, Done.
struct SummarizePageView: View {

    /// The page being summarised. Held to (a) build the context and
    /// (b) receive the inserted text element.
    let page: Page
    let notebookTitle: String
    let notebookId: UUID

    /// Called to tear the sheet down. Wired by the presenter caller
    /// so swipe-dismiss and the Done button share one path.
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var phase: Phase = .loading
    /// Set true once the summary is inserted so a second tap on the
    /// (briefly visible) Insert button can't create a duplicate.
    @State private var didInsert = false

    private enum Phase {
        case loading
        case ready(String)
        case failed(SummarizeFailure)
    }

    /// User-facing failure variants. Each maps an `AIError` (or an
    /// unexpected throw) to a headline + message + whether a retry
    /// makes sense.
    private enum SummarizeFailure {
        case disabled
        case emptyPage
        case tooLong
        case modelError

        var headline: String {
            switch self {
            case .disabled:   return "AI features are off"
            case .emptyPage:  return "Nothing to summarize"
            case .tooLong:    return "Page is too long"
            case .modelError: return "Couldn’t summarize"
            }
        }

        var message: String {
            switch self {
            case .disabled:
                return "Turn on Apple Intelligence in Settings to use AI features."
            case .emptyPage:
                return "This page has no text, sticky notes, or highlights to summarize."
            case .tooLong:
                return "There’s too much text on this page for an on-device summary. Try a page with less content."
            case .modelError:
                return "The summary couldn’t be generated. Please try again."
            }
        }

        /// Only model errors are worth retrying — a disabled toggle,
        /// an empty page, and an over-long page won't change on a
        /// second attempt.
        var canRetry: Bool {
            if case .modelError = self { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.hairline)
            content
        }
        .background(theme.surface)
#if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
#endif
        .task { await runSummary() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Summarize Page", systemImage: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Spacer()
            Button("Done") { onDismiss() }
                .font(.system(size: 15))
                .foregroundStyle(theme.accent)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.lg)
        .padding(.vertical, CeciliasNotes.Spacing.md)
    }

    // MARK: - Phase content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            loadingView
        case .ready(let summary):
            readyView(summary)
        case .failed(let failure):
            failureView(failure)
        }
    }

    private var loadingView: some View {
        VStack(spacing: CeciliasNotes.Spacing.md) {
            ProgressView()
            Text("Reading this page…")
                .font(.system(size: 13))
                .foregroundStyle(theme.foregroundSubtle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(CeciliasNotes.Spacing.lg)
    }

    private func readyView(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.lg) {
            ScrollView {
                Text(summary)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            VStack(spacing: CeciliasNotes.Spacing.sm) {
                primaryButton(
                    didInsert ? "Inserted" : "Insert as Text",
                    systemImage: didInsert ? "checkmark" : "text.badge.plus",
                    disabled: didInsert
                ) {
                    insertAsText(summary)
                }

                HStack(spacing: CeciliasNotes.Spacing.sm) {
                    secondaryButton("Copy", systemImage: "doc.on.doc") {
                        PlatformClipboard.copy(summary)
                    }
                    secondaryButton("Try Again", systemImage: "arrow.clockwise") {
                        Task { await runSummary() }
                    }
                }
            }
        }
        .padding(CeciliasNotes.Spacing.lg)
    }

    private func failureView(_ failure: SummarizeFailure) -> some View {
        VStack(spacing: CeciliasNotes.Spacing.md) {
            Image(systemName: "sparkles.slash")
                .font(.system(size: 28))
                .foregroundStyle(theme.foregroundSubtle)
            Text(failure.headline)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Text(failure.message)
                .font(.system(size: 13))
                .foregroundStyle(theme.foregroundSubtle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if failure.canRetry {
                secondaryButton("Try Again", systemImage: "arrow.clockwise") {
                    Task { await runSummary() }
                }
                .padding(.top, CeciliasNotes.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(CeciliasNotes.Spacing.lg)
    }

    // MARK: - Buttons

    private func primaryButton(
        _ title: String,
        systemImage: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .background(theme.accent.opacity(disabled ? 0.4 : 1))
        .foregroundStyle(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .disabled(disabled)
    }

    private func secondaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .foregroundStyle(theme.foreground)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.hairline, lineWidth: 1)
        )
    }

    // MARK: - Flow

    private func runSummary() async {
        phase = .loading
        didInsert = false

        let context = PageContextBuilder.build(
            page: page,
            notebookTitle: notebookTitle
        )

        do {
            let summary = try await AIService.shared.summarizePage(context)
            phase = .ready(summary)
        } catch let error as AIError {
            phase = .failed(Self.map(error))
        } catch {
            phase = .failed(.modelError)
        }
    }

    private func insertAsText(_ summary: String) {
        guard !didInsert else { return }
        // Top-left placement, comfortably wide. The text element
        // renderer sizes its own content; this rect is the initial
        // bounds the user can then move / resize like any text box.
        let rect = CGRect(x: 0.08, y: 0.10, width: 0.62, height: 0.22)
        TextElementCommit.create(
            text: summary,
            source: .ai,
            pageId: page.id,
            notebookId: notebookId,
            normalizedRect: rect
        )
        didInsert = true
    }

    private static func map(_ error: AIError) -> SummarizeFailure {
        switch error {
        case .unavailable:                       return .disabled
        case .empty:                             return .emptyPage
        case .tooLong:                           return .tooLong
        case .modelFailure, .unsupportedOperation: return .modelError
        }
    }
}
