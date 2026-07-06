import SwiftUI

/// Full-screen settings sheet — Phase D redesign.
///
/// Flat-white surface, editorial 22pt heavy "settings" title with a
/// 1.5pt black bottom rule (same as the home masthead), typography-only
/// rows on the left rail, and the existing per-section detail views on
/// the right. The system grouped-table look is gone — every row is
/// 14pt SF Pro on white, no icons, with a leading 2pt black rule on
/// the active section.
struct SettingsView: View {
    let onDismiss: () -> Void

    @StateObject private var viewModel: SettingsViewModel
    @State private var selectedSection: SettingsSection = .appearance
    @Environment(\.theme) private var theme

    private static let railWidth: CGFloat = 220

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
        Group {
#if os(iOS)
            if DeviceCapabilities.isPhoneIdiom {
                phoneBody
            } else {
                tabletBody
            }
#else
            tabletBody
#endif
        }
        .background(theme.surface)
#if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
#endif
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

    /// iPad master-detail. 220pt rail + hairline + detail; the
    /// composition that was here before iPhone support landed and
    /// is left unchanged so the regression risk on iPad is zero.
    private var tabletBody: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                rail
                    .frame(width: Self.railWidth)
                    .background(theme.surface)

                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: 0.5)

                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.surface)
            }
        }
    }

    /// iPhone NavigationStack — iOS only.
#if os(iOS)
    private var phoneBody: some View {
        NavigationStack {
            List {
                ForEach(visibleSections) { section in
                    NavigationLink(value: section) {
                        Text(section.rawValue.lowercased())
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(theme.foreground)
                            .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.surface)
            .navigationTitle("settings")
            .largeNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") { onDismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
            .navigationDestination(for: SettingsSection.self) { section in
                phoneDetail(for: section)
                    .background(theme.surface)
                    .navigationTitle(section.rawValue.lowercased())
                    .inlineNavigationBarTitle()
            }
        }
    }

    @ViewBuilder
    private func phoneDetail(for section: SettingsSection) -> some View {
        switch section {
        case .appearance:   AppearanceSettingsView(viewModel: viewModel)
        case .pencil:       PencilSettingsView(viewModel: viewModel)
        case .audio:        AudioSettingsView(viewModel: viewModel)
        case .cloud:        CloudSettingsView(viewModel: viewModel)
        case .storage:      StorageSettingsView(viewModel: viewModel)
        case .intelligence: IntelligenceSettingsView()
        case .about:        AboutSettingsView(viewModel: viewModel)
        }
    }
#endif

    // MARK: Header (editorial)

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("settings")
                .font(.system(size: 22, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(theme.foreground)
            Spacer()
#if !os(macOS)
            Button {
                onDismiss()
            } label: {
                Text("done")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
#endif
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.foreground)
                .frame(height: 1.5)
        }
    }

    // MARK: Rail (left)

    /// `.intelligence` is always shown now: it hosts the quiz controls
    /// (generation toggle, engine picker, MCP status), and quiz
    /// generation works on-device regardless of Apple Intelligence
    /// availability. It used to be suppressed when Foundation Models
    /// was missing — that hid the quiz settings entirely.
    private var visibleSections: [SettingsSection] {
        SettingsSection.allCases.filter { section in
            if section == .pencil, !DeviceCapabilities.canDraw { return false }
            return true
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleSections) { section in
                        railRow(section)
                    }
                }
                .padding(.top, 24)
            }
            Spacer(minLength: 0)
        }
    }

    private func railRow(_ section: SettingsSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            Text(section.rawValue.lowercased())
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(
                    isSelected ? theme.foreground : theme.recessivePrimary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .overlay(alignment: .leading) {
                    if isSelected {
                        Rectangle()
                            .fill(theme.foreground)
                            .frame(width: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .appearance:
            AppearanceSettingsView(viewModel: viewModel)
#if os(iOS)
        case .pencil:
            PencilSettingsView(viewModel: viewModel)
#else
        case .pencil:
            EmptyView()
#endif
        case .audio:
            AudioSettingsView(viewModel: viewModel)
        case .cloud:
            CloudSettingsView(viewModel: viewModel)
        case .storage:
            StorageSettingsView(viewModel: viewModel)
        case .intelligence:
            IntelligenceSettingsView()
        case .about:
            AboutSettingsView(viewModel: viewModel)
        }
    }
}
