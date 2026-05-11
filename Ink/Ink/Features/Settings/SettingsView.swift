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

    private static let railWidth: CGFloat = 220
    private static let hairlineColour = Color(
        light: Color(hex: "#f5f5f5"),
        dark:  Color(hex: "#1f1f1d")
    )
    private static let sectionLabelColour = Color(
        light: Color(hex: "#999999"),
        dark:  Color(hex: "#6a6a67")
    )

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
        VStack(spacing: 0) {
            header

            HStack(spacing: 0) {
                rail
                    .frame(width: Self.railWidth)
                    .background(Color(.systemBackground))

                Rectangle()
                    .fill(Self.hairlineColour)
                    .frame(width: 0.5)

                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            }
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
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

    // MARK: Header (editorial)

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("settings")
                .font(.system(size: 22, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(Color.inkNearBlack)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Text("done")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.brandAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.inkNearBlack)
                .frame(height: 1.5)
        }
    }

    // MARK: Rail (left)

    /// `SettingsSection.allCases` minus rows that should be absent on
    /// the current device. `.intelligence` is suppressed when the
    /// Foundation Models framework is missing or Apple Intelligence
    /// is off in iOS settings — graceful absence, not a disabled
    /// state.
    private var visibleSections: [SettingsSection] {
        SettingsSection.allCases.filter { section in
            section != .intelligence || IntelligenceService.shared.isAvailable
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
                    isSelected ? Color.inkNearBlack : Color.inkRecessivePrimary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .overlay(alignment: .leading) {
                    if isSelected {
                        Rectangle()
                            .fill(Color.inkNearBlack)
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
        case .pencil:
            PencilSettingsView(viewModel: viewModel)
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
        #if DEBUG
        case .debug:
            DebugSettingsView(viewModel: viewModel)
        #endif
        }
    }
}
