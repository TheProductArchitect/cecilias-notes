import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Ink.Spacing.lg) {
                infoCard
                privacyCard
                actionsCard
            }
            .padding(Ink.Spacing.lg)
        }
        .background(Color.inkBackgroundSecondary.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: App info

    private var infoCard: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Version", systemImage: "info.circle")
                    .font(.inkBody)
                    .foregroundColor(.inkTextPrimary)
                Spacer()
                Text(viewModel.appVersion)
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, Ink.Spacing.md)
            .padding(.vertical, Ink.Spacing.sm)

            InkDivider()

            NavigationLink {
                KeyboardShortcutsView()
            } label: {
                HStack {
                    Label("Keyboard Shortcuts", systemImage: "keyboard")
                        .font(.inkBody)
                        .foregroundColor(.inkTextPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.inkRowLabel)
                        .foregroundColor(.inkTextTertiary)
                }
                .padding(.horizontal, Ink.Spacing.md)
                .padding(.vertical, Ink.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.inkPressable)
        }
        .inkCard()
    }

    // MARK: Privacy note

    private var privacyCard: some View {
        HStack(spacing: Ink.Spacing.md) {
            Image(systemName: "lock.shield")
                .font(.inkSectionIcon)
                .foregroundColor(.inkTextSecondary)
                .frame(width: 24)
            Text("Ink has no backend. All data stays on your device.")
                .font(.inkBody)
                .foregroundColor(.inkTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    // MARK: Actions

    private var actionsCard: some View {
        VStack(spacing: 0) {
            // Send Feedback
            Button {
                sendFeedback()
            } label: {
                HStack {
                    Label("Send Feedback", systemImage: "envelope")
                        .font(.inkBody)
                        .foregroundColor(.inkAccentPrimary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.inkTag)
                        .foregroundColor(.inkTextTertiary)
                }
                .padding(.horizontal, Ink.Spacing.md)
                .padding(.vertical, Ink.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.inkPressable)

            InkDivider()

            // Rate Ink
            Button {
                viewModel.requestReviewIfEligible()
            } label: {
                HStack {
                    Label("Rate Ink", systemImage: "star")
                        .font(.inkBody)
                        .foregroundColor(.inkAccentPrimary)
                    Spacer()
                }
                .padding(.horizontal, Ink.Spacing.md)
                .padding(.vertical, Ink.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.inkPressable)
        }
        .inkCard()
    }

    private func sendFeedback() {
        let address = "feedback@ink.app"
        let subject = "Ink Feedback — \(viewModel.appVersion)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "mailto:\(address)?subject=\(subject)") else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - KeyboardShortcutsView

/// Placeholder for Stage 10. Lists shortcuts when populated.
struct KeyboardShortcutsView: View {
    var body: some View {
        List {
            Section("Library") {
                shortcutRow("New Notebook",   keys: "⌘N")
                shortcutRow("Search",         keys: "⌘F")
                shortcutRow("Settings",       keys: "⌘,")
            }
            Section("Editor") {
                shortcutRow("Undo",           keys: "⌘Z")
                shortcutRow("Redo",           keys: "⌘⇧Z")
                shortcutRow("Export",         keys: "⌘E")
                shortcutRow("Print",          keys: "⌘P")
                shortcutRow("Previous Page",  keys: "⌘←")
                shortcutRow("Next Page",      keys: "⌘→")
                shortcutRow("Toggle Toolbar", keys: "Space")
                shortcutRow("Close Editor",   keys: "Esc")
            }
            Section("Tools") {
                shortcutRow("Pen",            keys: "1")
                shortcutRow("Highlighter",    keys: "2")
                shortcutRow("Pencil",         keys: "3")
                shortcutRow("Eraser",         keys: "4")
                shortcutRow("Lasso",          keys: "5")
                shortcutRow("Ruler",          keys: "6")
                shortcutRow("Text Tool",      keys: "T")
            }
            Section("Settings") {
                shortcutRow("Close",          keys: "⌘W or Esc")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Keyboard Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func shortcutRow(_ name: String, keys: String) -> some View {
        HStack {
            Text(name)
                .font(.inkBody)
                .foregroundColor(.inkTextPrimary)
            Spacer()
            Text(keys)
                .font(.inkMono)
                .foregroundColor(.inkTextSecondary)
                .padding(.horizontal, Ink.Spacing.xs)
                .padding(.vertical, Ink.Spacing.micro)
                .background(Color.inkBackgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous))
        }
    }
}
