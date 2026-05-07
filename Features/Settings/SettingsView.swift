import SwiftUI

/// Full-screen settings sheet. NavigationSplitView: 220pt sidebar + detail column.
/// All settings take effect immediately — no Apply/Save buttons.
struct SettingsView: View {
    let onDismiss: () -> Void

    @StateObject private var viewModel: SettingsViewModel
    @State private var selectedSection: SettingsSection? = .appearance
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(
        cloudSyncManager: CloudSyncManager,
        themeManager:     ThemeManager,
        onDismiss:        @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(
            themeManager:     themeManager,
            cloudSyncManager: cloudSyncManager
        ))
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: columnVisibility) { _, new in
            if new != .all { columnVisibility = .all }
        }
        .background(
            VStack(spacing: 0) {
                Button("Close") { onDismiss() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Close") { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        )
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(SettingsSection.allCases, selection: $selectedSection) { section in
            Label(section.rawValue, systemImage: section.icon)
                .font(.inkBody)
                .foregroundColor(.inkTextPrimary)
                .tag(section)
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { onDismiss() }
                    .font(.inkHeadline)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .appearance:
            AppearanceSettingsView(viewModel: viewModel)
        case .pencil:
            PencilSettingsView(viewModel: viewModel)
        case .newPages:
            NewPagesSettingsView(viewModel: viewModel)
        case .audio:
            AudioSettingsView(viewModel: viewModel)
        case .cloud:
            CloudSettingsView(viewModel: viewModel)
        case .storage:
            StorageSettingsView(viewModel: viewModel)
        case .about:
            AboutSettingsView(viewModel: viewModel)
        case nil:
            // Default on first open
            AppearanceSettingsView(viewModel: viewModel)
        }
    }
}
