import SwiftUI

struct StorageSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var showClearExportsAlert   = false
    @State private var showClearAudioAlert     = false
    @State private var isClearingExports       = false
    @State private var isClearingAudio         = false
    @State private var clearError:             String? = nil

    /// Latest unified-storage diagnostics. Populated on `.task`; nil
    /// until the first read completes (a few ms — no spinner needed).
    @State private var mediaDiagnostics: MediaStorage.Diagnostics? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: Ink.Spacing.lg) {
                metricsRow
                if let staleness = cacheStalenessCaption {
                    Text(staleness)
                        .font(.system(size: 11).italic())
                        .foregroundStyle(Color.inkRecessiveTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                mediaStorageBreakdown
                actionsCard
            }
            .padding(Ink.Spacing.lg)
        }
        .background(Color.inkBackgroundSecondary.ignoresSafeArea())
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.loadStorageMetrics() }
        // Always run a fresh calculation on appear. The view-model
        // pre-populates `storageInfo` from the UserDefaults cache
        // so the cards render real numbers immediately; the
        // background task then overwrites with up-to-date values
        // and re-writes the cache. `.task` is tied to view
        // lifetime and cancels cleanly if the user leaves Settings.
        .task {
            await viewModel.loadStorageMetrics()
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

    /// Returns "updated X min ago" / "updated just now" when the
    /// displayed cache value is older than `storageCacheStaleAfter`
    /// (5 min). Returns `nil` while a fresh recalculation is running,
    /// when the cache age is below the threshold, or when no cache
    /// exists yet — those cases either display the value as-is or
    /// fall back to the "calculating…" placeholder in the metric
    /// cards.
    private var cacheStalenessCaption: String? {
        guard let cachedAt = viewModel.storageInfoCachedAt,
              viewModel.storageInfo != nil,
              !viewModel.isLoadingStorage
        else { return nil }
        let age = Date().timeIntervalSince(cachedAt)
        guard age >= SettingsViewModel.storageCacheStaleAfter else { return nil }
        let minutes = Int(age / 60)
        return minutes < 1
            ? "updated just now"
            : "updated \(minutes) min ago"
    }

    // MARK: Unified MediaStorage breakdown
    //
    // Surfaces `MediaStorage.diagnostics()` — per-category counts and
    // bytes for the unified `Documents/MediaAttachments/` tree. The
    // legacy notebook-scoped totals above ("Total Used / Audio /
    // Images") still come from `StorageService.localStorageUsed`,
    // which walks the SwiftData notebook directories. Both panels are
    // consistent for migrated installs and useful even before the
    // migration completes (the breakdown reflects the unified tree
    // exclusively, the totals reflect everything).

    private var mediaStorageBreakdown: some View {
        VStack(spacing: 0) {
            breakdownRow(
                label: "Images",
                count: mediaDiagnostics?.imageCount,
                bytes: mediaDiagnostics?.imageBytes,
                icon: "photo"
            )
            InkDivider()
            breakdownRow(
                label: "Audio recordings",
                count: mediaDiagnostics?.audioCount,
                bytes: mediaDiagnostics?.audioBytes,
                icon: "waveform"
            )
            InkDivider()
            breakdownRow(
                label: "Lecture recordings",
                count: mediaDiagnostics?.lectureCount,
                bytes: mediaDiagnostics?.lectureBytes,
                icon: "mic"
            )
        }
        .inkCard()
        .task { await loadMediaDiagnostics() }
    }

    private func breakdownRow(
        label: String,
        count: Int?,
        bytes: Int64?,
        icon: String
    ) -> some View {
        HStack(spacing: Ink.Spacing.sm) {
            Image(systemName: icon)
                .font(.inkSectionIcon)
                .foregroundColor(.inkTextSecondary)
                .frame(width: 24)
            Text(label)
                .font(.inkBody)
                .foregroundColor(.inkTextPrimary)
            Spacer()
            if let count, let bytes {
                Text("\(count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(.inkCaption)
                    .foregroundColor(.inkTextSecondary)
                    .monospacedDigit()
            } else {
                Text("calculating…")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(Color.inkRecessiveTertiary)
            }
        }
        .padding(Ink.Spacing.md)
    }

    private func loadMediaDiagnostics() async {
        // Filesystem enumeration — small (3 directories) but still
        // hop off main to keep the cards' first paint snappy.
        let result = await Task.detached(priority: .utility) {
            MediaStorage.diagnostics()
        }.value
        await MainActor.run { mediaDiagnostics = result }
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

            // Cached value (if any) is restored on view-model init
            // so `bytes` is usually non-nil on entry. The
            // "calculating…" placeholder only shows on the first
            // launch where no cache exists yet — never the
            // legacy "—" empty state, which read as broken.
            if let bytes {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextPrimary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
            } else {
                Text("calculating…")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(Color.inkRecessiveTertiary)
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
