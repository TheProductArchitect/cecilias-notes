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
                    .foregroundStyle(isDestructive ? Color.red : Color.inkNearBlack)
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
