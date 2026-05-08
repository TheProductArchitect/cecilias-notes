import SwiftUI

struct StorageSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var showClearExportsAlert   = false
    @State private var showClearAudioAlert     = false
    @State private var isClearingExports       = false
    @State private var isClearingAudio         = false
    @State private var clearError:             String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: Ink.Spacing.lg) {
                metricsRow
                actionsCard
            }
            .padding(Ink.Spacing.lg)
        }
        .background(Color.inkBackgroundSecondary.ignoresSafeArea())
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.loadStorageMetrics() }
        // Only load on first appear — `loadStorageMetrics` already guards
        // re-entry, but skipping the call when data is fresh keeps the
        // initial render free of an unnecessary spinner pulse.
        .task {
            if viewModel.storageInfo == nil {
                await viewModel.loadStorageMetrics()
            }
        }
        .alert("Clear Exported PDFs?", isPresented: $showClearExportsAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                HapticManager.shared.destructiveConfirmed()
                Task { await clearExports() }
            }
        } message: {
            Text("All exported PDF files will be deleted. This cannot be undone.")
        }
        .alert("Clear Audio Recordings?", isPresented: $showClearAudioAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Recordings", role: .destructive) {
                HapticManager.shared.destructiveConfirmed()
                Task { await clearAudio() }
            }
        } message: {
            Text("All audio recordings and their annotations will be deleted. Untranscribed recordings will be lost permanently.")
        }
        .alert("Error", isPresented: Binding(
            get: { clearError != nil },
            set: { if !$0 { clearError = nil } }
        ), presenting: clearError) { _ in
            Button("OK", role: .cancel) {}
        } message: { err in
            Text(err)
        }
    }

    // MARK: Metric cards

    private var metricsRow: some View {
        HStack(spacing: Ink.Spacing.sm) {
            metricCard(
                title: "Total Used",
                bytes: viewModel.storageInfo?.totalBytes,
                icon: "internaldrive"
            )
            metricCard(
                title: "Audio",
                bytes: viewModel.storageInfo?.audioBytes,
                icon: "waveform"
            )
            metricCard(
                title: "Images",
                bytes: viewModel.storageInfo?.mediaBytes,
                icon: "photo"
            )
        }
    }

    private func metricCard(title: String, bytes: Int64?, icon: String) -> some View {
        VStack(spacing: Ink.Spacing.xs) {
            Image(systemName: icon)
                .font(.inkSectionIcon)
                .foregroundColor(.inkTextSecondary)

            if viewModel.isLoadingStorage {
                ProgressView().scaleEffect(0.7)
            } else {
                Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextPrimary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
            }

            Text(title)
                .font(.inkCaption)
                .foregroundColor(.inkTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    // MARK: Action rows

    private var actionsCard: some View {
        VStack(spacing: 0) {
            // Clear exports
            let exportsLabel = viewModel.exportedPDFsBytes > 0
                ? "(\(ByteCountFormatter.string(fromByteCount: viewModel.exportedPDFsBytes, countStyle: .file)))"
                : nil

            actionRow(
                title: "Clear Exported PDFs",
                detail: exportsLabel,
                icon: "doc.richtext",
                disabled: viewModel.exportedPDFsBytes == 0,
                disabledSubLabel: viewModel.exportedPDFsBytes == 0 ? "Nothing to clear" : nil,
                isLoading: isClearingExports,
                isDestructive: false
            ) {
                showClearExportsAlert = true
            }

            InkDivider()

            // Clear audio
            let audioBytes = viewModel.storageInfo?.audioBytes ?? 0
            let audioLabel = audioBytes > 0
                ? "(\(ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)))"
                : nil

            actionRow(
                title: "Clear Audio Recordings",
                detail: audioLabel,
                icon: "waveform.slash",
                disabled: audioBytes == 0,
                disabledSubLabel: audioBytes == 0 ? "No recordings" : nil,
                isLoading: isClearingAudio,
                isDestructive: true
            ) {
                showClearAudioAlert = true
            }

            InkDivider()

            // View in Files
            Button {
                openInFiles()
            } label: {
                HStack(spacing: Ink.Spacing.md) {
                    Image(systemName: "folder")
                        .font(.inkMidIcon)
                        .foregroundColor(.inkAccentPrimary)
                        .frame(width: 24)
                    Text("View in Files")
                        .font(.inkBody)
                        .foregroundColor(.inkAccentPrimary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.inkTag)
                        .foregroundColor(.inkTextTertiary)
                }
                .padding(.horizontal, Ink.Spacing.md)
                .padding(.vertical, Ink.Spacing.sm)
            }
            .buttonStyle(.inkPressable)
        }
        .inkCard()
    }

    private func actionRow(
        title: String,
        detail: String?,
        icon: String,
        disabled: Bool,
        disabledSubLabel: String?,
        isLoading: Bool,
        isDestructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: disabled ? {} : action) {
            HStack(spacing: Ink.Spacing.md) {
                Image(systemName: icon)
                    .font(.inkMidIcon)
                    .foregroundColor(disabled ? .inkTextTertiary : (isDestructive ? .inkDestructive : .inkTextPrimary))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Ink.Spacing.xs) {
                        Text(title)
                            .font(.inkBody)
                            .foregroundColor(disabled ? .inkTextTertiary : (isDestructive ? .inkDestructive : .inkTextPrimary))
                        if let detail {
                            Text(detail)
                                .font(.inkCaption)
                                .foregroundColor(.inkTextTertiary)
                        }
                    }
                    if disabled, let sub = disabledSubLabel {
                        Text(sub)
                            .font(.inkCaption)
                            .foregroundColor(.inkTextTertiary)
                    }
                }

                Spacer()

                if isLoading {
                    ProgressView().scaleEffect(0.75)
                }
            }
            .padding(.horizontal, Ink.Spacing.md)
            .padding(.vertical, Ink.Spacing.sm)
        }
        .buttonStyle(.inkPressable)
        .disabled(disabled || isLoading)
    }

    // MARK: Actions

    private func clearExports() async {
        isClearingExports = true
        do {
            try await viewModel.clearExportedPDFs()
        } catch {
            clearError = error.localizedDescription
        }
        isClearingExports = false
    }

    private func clearAudio() async {
        isClearingAudio = true
        do {
            try await viewModel.clearAudioRecordings()
        } catch {
            clearError = error.localizedDescription
        }
        isClearingAudio = false
    }

    private func openInFiles() {
        guard let url = URL(string: "shareddocuments://") else { return }
        UIApplication.shared.open(url)
    }
}
