import SwiftUI

/// One-shot dismissible badge shown the first time the user opens
/// an agent-written notebook. State is keyed per-notebook in
/// `UserDefaults` so the badge appears once per notebook even if
/// the agent later updates it. Reads as a footnote, not a modal
/// — it doesn't block any canvas interaction.
///
/// Earlier this rendered as a full-width blue strip sitting above
/// the page. It read like an OS-level banner — too loud for an
/// in-document attribution. Replaced with a compact capsule
/// (sparkles glyph + author name + close) that hugs its content
/// and sits in the editor's top-right alongside the existing pill
/// vocabulary (recording pill, undo-shape pill).
struct AgentBannerView: View {

    let notebook: Notebook
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    private var authorName: String {
        notebook.agentName?.isEmpty == false
            ? (notebook.agentName ?? "an agent")
            : "an agent"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.foregroundMuted)

            Text("by \(authorName)")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.foregroundMuted)
                .lineLimit(1)

            Button {
                AgentBannerState.markSeen(notebookId: notebook.id)
                withAnimation(.easeOut(duration: 0.18)) { onDismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.foregroundMuted.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss agent banner")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Per-notebook persistence for "has the user seen the agent banner"
/// signal. Lives in `UserDefaults` rather than on the SwiftData model
/// — purely client-side UI state, no CloudKit value in syncing it.
enum AgentBannerState {

    private static let keyPrefix = "ceciliasnotes.agent.banner.seen."

    static func hasSeen(notebookId: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: keyPrefix + notebookId.uuidString)
    }

    static func markSeen(notebookId: UUID) {
        UserDefaults.standard.set(true, forKey: keyPrefix + notebookId.uuidString)
    }
}
