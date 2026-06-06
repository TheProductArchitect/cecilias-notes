import SwiftUI

/// One-shot dismissible banner shown the first time the user opens
/// an agent-written notebook. State is keyed per-notebook in
/// `UserDefaults` so the banner appears once per notebook even if the
/// agent later updates it. Designed to read as a footnote, not a
/// modal — it doesn't block any canvas interaction.
struct AgentBannerView: View {

    let notebook: Notebook
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    private var label: String {
        let who = notebook.agentName?.isEmpty == false
            ? (notebook.agentName ?? "an agent")
            : "an agent"
        return "written by \(who)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .regular).italic())
                .foregroundStyle(theme.accent)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                AgentBannerState.markSeen(notebookId: notebook.id)
                withAnimation(.easeOut(duration: 0.18)) { onDismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.accent.opacity(0.7))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss agent banner")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.accent.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.2), lineWidth: 0.5)
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
