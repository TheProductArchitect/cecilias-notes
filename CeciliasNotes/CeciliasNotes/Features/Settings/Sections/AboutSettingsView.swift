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
                privacyPolicyLink
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

    // MARK: Privacy policy

    /// Navigates to a dedicated privacy-policy screen rendered
    /// in-app. The full version is hosted at the URL in the screen
    /// itself; we also surface the short, plain-language version
    /// up front so a user who lands here for App Store compliance
    /// can see the gist without leaving the app.
    private var privacyPolicyLink: some View {
        NavigationLink {
            PrivacyPolicyView()
        } label: {
            HStack {
                Text("privacy policy")
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
        let address = "feedback@ceciliasnotes.app"
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
                shortcutRow("New Notebook",     keys: "⌘N")
                shortcutRow("Search Library",   keys: "⌘F")
                shortcutRow("Settings",         keys: "⌘,")
                if DeviceCapabilities.supportsGridKeyboardNavigation {
                    shortcutRow("Focus Notebook", keys: "↑ or ↓")
                    shortcutRow("Open Notebook",  keys: "↩")
                    shortcutRow("Open Notebook",  keys: "Space", footnote: "Library grid only")
                }
            }
            Section("Editor") {
                shortcutRow("Undo",               keys: "⌘Z")
                shortcutRow("Redo",               keys: "⌘⇧Z")
                shortcutRow("Export",             keys: "⌘⇧E")
                shortcutRow("Find in Notebook",   keys: "⌘⇧F")
                shortcutRow("Print",              keys: "⌘P")
                shortcutRow("Close Notebook",     keys: "⌘W")
                shortcutRow("Scroll Up",          keys: "⌘←", footnote: "One viewport in continuous canvas")
                shortcutRow("Scroll Down",        keys: "⌘→", footnote: "One viewport in continuous canvas")
                shortcutRow("Toggle Toolbar",     keys: "Space", footnote: "While editing")
                shortcutRow("Focus Mode",         keys: "⌃⌘F")
                shortcutRow("Close Editor",       keys: "Esc")
            }
            if DeviceCapabilities.canDraw {
                Section {
                    Text("Number keys select tools; your colour and width settings are restored.")
                        .font(.ceciliasNotesCaption)
                        .foregroundColor(theme.foregroundMuted)
                } header: {
                    Text("Drawing Tools (iPad)")
                }
                shortcutRow("Pen",                keys: "1")
                shortcutRow("Fountain Pen",       keys: "2")
                shortcutRow("Brush",              keys: "3")
                shortcutRow("Marker",             keys: "4")
                shortcutRow("Pencil",             keys: "5")
                shortcutRow("Highlighter",        keys: "6")
                shortcutRow("Eraser",             keys: "7")
                shortcutRow("Lasso",              keys: "8")
                shortcutRow("Ruler",              keys: "9")
                shortcutRow("Text Tool",          keys: "T")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Keyboard Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func shortcutRow(_ name: String, keys: String, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
            if let footnote {
                Text(footnote)
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundMuted)
            }
        }
    }
}
