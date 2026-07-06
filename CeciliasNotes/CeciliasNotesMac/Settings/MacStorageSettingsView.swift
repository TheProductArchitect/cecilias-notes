import SwiftUI

/// Storage tab for macOS Settings — mirrors iPad totals without SettingsViewModel.
struct MacStorageSettingsView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storageService: StorageService

    @State private var storageInfo: StorageInfo?
    @State private var exportedPDFsBytes: Int64 = 0
    @State private var isLoading = false
    @State private var showClearExportsAlert = false
    @State private var clearError: String?

    var body: some View {
        Form {
            if let storageInfo {
                LabeledContent("Total used") {
                    Text(byteLabel(storageInfo.totalBytes))
                }
                LabeledContent("Audio") {
                    Text(byteLabel(storageInfo.audioBytes))
                }
                LabeledContent("Images & media") {
                    Text(byteLabel(storageInfo.mediaBytes))
                }
                LabeledContent("Database") {
                    Text(byteLabel(storageInfo.dbBytes))
                }
            } else if isLoading {
                ProgressView()
            } else {
                Text("Calculating…")
                    .foregroundStyle(theme.foregroundMuted)
            }

            if exportedPDFsBytes > 0 {
                Button("Clear exported PDFs (\(byteLabel(exportedPDFsBytes)))", role: .destructive) {
                    showClearExportsAlert = true
                }
            }

            Button("Reveal documents folder") {
                PlatformApp.revealDocumentsFolder()
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .alert("Clear exported PDFs?", isPresented: $showClearExportsAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await clearExports() }
            }
        } message: {
            Text("All exported PDF files will be deleted. This cannot be undone.")
        }
        .alert("Error", isPresented: Binding(
            get: { clearError != nil },
            set: { if !$0 { clearError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(clearError ?? "")
        }
    }

    private func refresh() async {
        isLoading = true
        let info = await storageService.localStorageUsed()
        storageInfo = info
        exportedPDFsBytes = storageService.exportedPDFsSizeBytes()
        isLoading = false
    }

    private func clearExports() async {
        do {
            try await storageService.clearExportedPDFs()
            exportedPDFsBytes = 0
            storageInfo = await storageService.localStorageUsed()
        } catch {
            clearError = error.localizedDescription
        }
    }

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
