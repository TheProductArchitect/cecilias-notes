#if DEBUG
import SwiftUI

struct MacDebugSettingsView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var storageService: StorageService
    @Environment(\.theme) private var theme

    @State private var isGenerating = false
    @State private var statusLine: String?

    var body: some View {
        Form {
            Section("Synthetic data") {
                Button("Generate 10 notebooks") { runGenerate(10) }
                Button("Generate 100 notebooks") { runGenerate(100) }
                Button("Wipe all notebooks & subjects", role: .destructive) { runWipe() }
                    .disabled(isGenerating)
            }
            if let statusLine {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(theme.foregroundMuted)
            }
        }
        .formStyle(.grouped)
        .overlay {
            if isGenerating {
                ProgressView()
            }
        }
    }

    private func runGenerate(_ count: Int) {
        guard !isGenerating else { return }
        isGenerating = true
        statusLine = nil
        Task {
            let start = Date()
            try? await storageService.generateSyntheticNotebooks(count: count)
            isGenerating = false
            statusLine = String(format: "generated %d in %.1fs", count, Date().timeIntervalSince(start))
        }
    }

    private func runWipe() {
        guard !isGenerating else { return }
        isGenerating = true
        statusLine = nil
        Task {
            try? await storageService.wipeAllSyntheticData()
            isGenerating = false
            statusLine = "wiped"
        }
    }
}
#endif
