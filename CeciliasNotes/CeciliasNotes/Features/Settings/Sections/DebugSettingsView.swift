#if DEBUG
import SwiftUI

/// Debug-only Settings panel for local performance testing. Compiled
/// out of release builds via the file-level `#if DEBUG` guard, and
/// the `.debug` `SettingsSection` is itself DEBUG-gated, so users on
/// shipped builds never see this rail entry or detail surface.
///
/// Generators bulk-insert synthetic notebooks to exercise the library
/// grid, sidebar count badges, and search at scale. The wipe entry is
/// destructive and clears every notebook and subject in the store —
/// it's labelled accordingly.
struct DebugSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var isGenerating = false
    @State private var statusLine: String?

    private static let hairlineColour = Color(
        light: Color(hex: "#f5f5f5"),
        dark:  Color(hex: "#1f1f1d")
    )
    private static let labelColour = Color(
        light: Color(hex: "#999999"),
        dark:  Color(hex: "#6a6a67")
    )
    private static let captionColour = Color(
        light: Color(hex: "#aaaaaa"),
        dark:  Color(hex: "#5e5e5c")
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                themeSection
                generatorsSection
                wipeSection
                if let statusLine {
                    Text(statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Self.captionColour)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(Color(.systemBackground))
        .overlay {
            if isGenerating {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.5)
                            .tint(.white)
                    }
            }
        }
    }

    // MARK: Theme switcher (Phase B verification)

    /// Temporary debug-only theme toggle. Lets us verify the new
    /// ThemeManager + Theme value type flips chrome correctly before
    /// Phase D migrates the ~542 call sites off the inkX namespace.
    /// The proper Theme picker lives in Settings → Appearance and will
    /// be wired to the new manager in Phase F (or earlier — it's
    /// already routed in Phase B). This row stays so we have a fast
    /// in-app switch during development.
    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("theme (Phase B debug)")
            VStack(spacing: 0) {
                ForEach(Theme.all) { theme in
                    let isSelected = viewModel.themeManager.current.id == theme.id
                    Button {
                        withAnimation {
                            viewModel.themeManager.setTheme(theme)
                        }
                    } label: {
                        HStack {
                            Text(theme.displayName)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.inkTextPrimary)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.brandAccent)
                            }
                        }
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Self.hairlineColour)
                                .frame(height: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Generators

    private var generatorsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("synthetic data")
            VStack(spacing: 0) {
                debugRow(label: "Generate 100 notebooks") { runGenerate(100) }
                debugRow(label: "Generate 500 notebooks") { runGenerate(500) }
                debugRow(label: "Generate 1000 notebooks") { runGenerate(1000) }
            }
        }
    }

    private var wipeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("danger zone")
            debugRow(label: "Wipe all data", isDestructive: true) {
                runWipe()
            }
        }
    }

    // MARK: Row

    private func debugRow(
        label: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(isDestructive ? Color.red : Color.inkTextPrimary)
                Spacer()
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(Self.hairlineColour).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
    }

    // MARK: Actions

    private func runGenerate(_ count: Int) {
        guard !isGenerating else { return }
        isGenerating = true
        statusLine   = nil
        let start    = Date()
        Task {
            await viewModel.generateSyntheticData(notebookCount: count)
            let elapsed = Date().timeIntervalSince(start)
            isGenerating = false
            statusLine   = String(format: "generated %d notebooks in %.2fs", count, elapsed)
        }
    }

    private func runWipe() {
        guard !isGenerating else { return }
        isGenerating = true
        statusLine   = nil
        let start    = Date()
        Task {
            await viewModel.wipeAllSyntheticData()
            let elapsed = Date().timeIntervalSince(start)
            isGenerating = false
            statusLine   = String(format: "wiped all data in %.2fs", elapsed)
        }
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(Self.labelColour)
    }
}
#endif
