import SwiftUI

/// Phase D redesign: editorial About section. Cecilia's brand moment
/// lives here — the only place outside onboarding/splash where her
/// name appears. Flat white surface, no cards, no icons.
struct AboutSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                brandSection
                yourNameSection
                privacySection
                actionsSection
                shortcutsSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 28)
        }
        .background(theme.surface)
    }

    // MARK: Cecilia brand moment

    private var brandSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // About scales below the masthead's tier system, so it
            // composes its own small inline wordmark rather than going
            // through `BrandWordmark` (whose name/notes size relation
            // is calibrated for 38–72 pt names, not 17 pt).
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("cecilia's notes")
                    .font(.system(size: 17, weight: .heavy))
                    .tracking(-0.05 * 17)
                    .foregroundStyle(theme.foreground)
                Text("·")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(theme.accent)
            }
            Text(viewModel.appVersion.lowercased())
                .font(.system(size: 9))
                .foregroundStyle(theme.recessiveQuaternary)
            Text("made with care. yours to keep.")
                .font(.system(size: 11).italic())
                .foregroundStyle(theme.foregroundSubtle)
                .padding(.top, 6)
        }
    }

    // MARK: Your Name

    private var yourNameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("your name")
            YourNameCard()
        }
    }

    // MARK: Privacy line

    private var privacySection: some View {
        Text("no backend. no accounts. all data stays on your device.")
            .font(.system(size: 11).italic())
            .foregroundStyle(theme.foregroundSubtle)
            .padding(.top, 4)
    }

    // MARK: Send feedback / Rate

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionRow("send feedback") { sendFeedback() }
            Rectangle().fill(theme.hairline).frame(height: 0.5)
            actionRow("rate cecilia's notes") { viewModel.requestReviewIfEligible() }
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }

    private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accent)
                Spacer()
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Keyboard shortcuts entry

    private var shortcutsSection: some View {
        NavigationLink {
            KeyboardShortcutsView()
        } label: {
            HStack {
                Text("keyboard shortcuts")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accent)
                Spacer()
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
    }

    private func sendFeedback() {
        let address = "feedback@ink.app"
        let subject = "Cecilia's Notes Feedback — \(viewModel.appVersion)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "mailto:\(address)?subject=\(subject)") else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - KeyboardShortcutsView

/// Lists keyboard shortcuts. Layout retained from earlier work — list
/// styling matches the redesigned settings surface (flat white, no
/// grouped table chrome).
struct KeyboardShortcutsView: View {
    @Environment(\.theme) private var theme
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
                .font(.ceciliasNotesBody)
                .foregroundColor(theme.foreground)
            Spacer()
            Text(keys)
                .font(.ceciliasNotesMono)
                .foregroundColor(theme.foregroundMuted)
                .padding(.horizontal, CeciliasNotes.Spacing.xs)
                .padding(.vertical, CeciliasNotes.Spacing.micro)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous))
        }
    }
}
