import SwiftUI

struct StorageSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.theme) private var theme

    @State private var showClearExportsAlert   = false
    @State private var showClearAudioAlert     = false
    @State private var isClearingExports       = false
    @State private var isClearingAudio         = false
    @State private var clearError:             String? = nil
    @State private var showPurgeDeletedAlert   = false
    @State private var isPurgingDeleted        = false
    @State private var purgedCount: Int?       = nil
    @State private var isPullingFromCloud      = false
    @State private var pullFeedback: String?   = nil

    /// Latest unified-storage diagnostics. Populated on `.task`; nil
    /// until the first read completes (a few ms — no spinner needed).
    @State private var mediaDiagnostics: MediaStorage.Diagnostics? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: CeciliasNotes.Spacing.lg) {
                metricsRow
                if let staleness = cacheStalenessCaption {
                    Text(staleness)
                        .font(.system(size: 11).italic())
                        .foregroundStyle(theme.recessiveTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                mediaStorageBreakdown
                actionsCard
            }
            .padding(CeciliasNotes.Spacing.lg)
        }
        .background(theme.surface.ignoresSafeArea())
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
        .alert("Purge Deleted Items from iCloud?", isPresented: $showPurgeDeletedAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Purge", role: .destructive) {
                HapticManager.shared.destructiveConfirmed()
                Task { await purgeDeletedItems() }
            }
        } message: {
            Text("Every notebook, subject, folder, or page you've already deleted will be permanently removed from iCloud across all your devices. This can't be undone.")
        }
        .alert("Pulled from iCloud", isPresented: Binding(
            get: { pullFeedback != nil },
            set: { if !$0 { pullFeedback = nil } }
        ), presenting: pullFeedback) { _ in
            Button("OK", role: .cancel) {}
        } message: { feedback in
            Text(feedback)
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
            CeciliasNotesDivider()
            breakdownRow(
                label: "Audio recordings",
                count: mediaDiagnostics?.audioCount,
                bytes: mediaDiagnostics?.audioBytes,
                icon: "waveform"
            )
            CeciliasNotesDivider()
            breakdownRow(
                label: "Lecture recordings",
                count: mediaDiagnostics?.lectureCount,
                bytes: mediaDiagnostics?.lectureBytes,
                icon: "mic"
            )
        }
        .ceciliasNotesCard()
        .task { await loadMediaDiagnostics() }
    }

    private func breakdownRow(
        label: String,
        count: Int?,
        bytes: Int64?,
        icon: String
    ) -> some View {
        HStack(spacing: CeciliasNotes.Spacing.sm) {
            Image(systemName: icon)
                .font(.ceciliasNotesSectionIcon)
                .foregroundColor(theme.foregroundMuted)
                .frame(width: 24)
            Text(label)
                .font(.ceciliasNotesBody)
                .foregroundColor(theme.foreground)
            Spacer()
            if let count, let bytes {
                Text("\(count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundMuted)
                    .monospacedDigit()
            } else {
                Text("calculating…")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(theme.recessiveTertiary)
            }
        }
        .padding(CeciliasNotes.Spacing.md)
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
        HStack(spacing: CeciliasNotes.Spacing.sm) {
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
        VStack(spacing: CeciliasNotes.Spacing.xs) {
            Image(systemName: icon)
                .font(.ceciliasNotesSectionIcon)
                .foregroundColor(theme.foregroundMuted)

            // Cached value (if any) is restored on view-model init
            // so `bytes` is usually non-nil on entry. The
            // "calculating…" placeholder only shows on the first
            // launch where no cache exists yet — never the
            // legacy "—" empty state, which read as broken.
            if let bytes {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.ceciliasNotesSubhead)
                    .foregroundColor(theme.foreground)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
            } else {
                Text("calculating…")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(theme.recessiveTertiary)
            }

            Text(title)
                .font(.ceciliasNotesCaption)
                .foregroundColor(theme.foregroundMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(CeciliasNotes.Spacing.md)
        .ceciliasNotesCard()
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

            CeciliasNotesDivider()

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

            CeciliasNotesDivider()

            // Re-scan iCloud Files — kicks the NSMetadataQuery to
            // re-gather anything an external agent (cecilias-notes-mcp
            // on Mac) dropped into iCloud Drive. Same code path as
            // the app-launch watcher, but fires immediately so the
            // user doesn't sit through iCloud's auto-sync latency.
            //
            // The original label "Pull from iCloud Now" implied this
            // also forced the SwiftData/CloudKit sync the home-page
            // indicator tracks — but those two are separate systems
            // (SwiftData sync runs on its own cadence and we don't
            // expose a manual trigger). Tapping this used to leave
            // the user staring at the home-page "last synced N min
            // ago" timestamp and wondering why it didn't reset.
            actionRow(
                title: "Re-scan iCloud Files",
                detail: "Imports .inkbook files dropped into iCloud Drive by external tools. Does not force a notebook sync — the home-page indicator tracks that separately.",
                icon: "arrow.down.to.line",
                disabled: false,
                disabledSubLabel: nil,
                isLoading: isPullingFromCloud,
                isDestructive: false
            ) {
                Task { await pullFromCloud() }
            }

            CeciliasNotesDivider()

            // Purge — runs `emptyTrash()` which hard-deletes every
            // soft-deleted record. SwiftData+CloudKit propagates the
            // hard delete so iCloud actually drops the records too.
            // Useful for power users (synthetic data sweeps, batch
            // delete cleanup) where Trash → Empty isn't reachable.
            let purgeDetail: String? = purgedCount.map { count in
                "Purged \(count) item\(count == 1 ? "" : "s")"
            }
            actionRow(
                title: "Purge Deleted Items from iCloud",
                detail: purgeDetail,
                icon: "icloud.slash",
                disabled: false,
                disabledSubLabel: nil,
                isLoading: isPurgingDeleted,
                isDestructive: true
            ) {
                showPurgeDeletedAlert = true
            }

            CeciliasNotesDivider()

            // View in Files
            Button {
                openInFiles()
            } label: {
                HStack(spacing: CeciliasNotes.Spacing.md) {
                    Image(systemName: "folder")
                        .font(.ceciliasNotesMidIcon)
                        .foregroundColor(theme.accent)
                        .frame(width: 24)
                    Text("View in Files")
                        .font(.ceciliasNotesBody)
                        .foregroundColor(theme.accent)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.ceciliasNotesTag)
                        .foregroundColor(theme.foregroundSubtle)
                }
                .padding(.horizontal, CeciliasNotes.Spacing.md)
                .padding(.vertical, CeciliasNotes.Spacing.sm)
            }
            .buttonStyle(.ceciliasNotesPressable)
        }
        .ceciliasNotesCard()
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
            HStack(spacing: CeciliasNotes.Spacing.md) {
                Image(systemName: icon)
                    .font(.ceciliasNotesMidIcon)
                    .foregroundColor(disabled ? theme.foregroundSubtle : (isDestructive ? theme.danger : theme.foreground))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: CeciliasNotes.Spacing.xs) {
                        Text(title)
                            .font(.ceciliasNotesBody)
                            .foregroundColor(disabled ? theme.foregroundSubtle : (isDestructive ? theme.danger : theme.foreground))
                        if let detail {
                            Text(detail)
                                .font(.ceciliasNotesCaption)
                                .foregroundColor(theme.foregroundSubtle)
                        }
                    }
                    if disabled, let sub = disabledSubLabel {
                        Text(sub)
                            .font(.ceciliasNotesCaption)
                            .foregroundColor(theme.foregroundSubtle)
                    }
                }

                Spacer()

                if isLoading {
                    ProgressView().scaleEffect(0.75)
                }
            }
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .padding(.vertical, CeciliasNotes.Spacing.sm)
        }
        .buttonStyle(.ceciliasNotesPressable)
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

    /// Hard-delete every soft-deleted notebook / subject / folder /
    /// page in the local store. SwiftData+CloudKit propagates the
    /// hard delete to the user's CloudKit private database, so the
    /// records actually leave iCloud rather than lingering with an
    /// `isDeleted = true` flag forever.
    private func purgeDeletedItems() async {
        isPurgingDeleted = true
        defer { isPurgingDeleted = false }
        let storage = StorageService.shared
        // Snapshot the soft-deleted counts before purging so we can
        // report a number; the actual emptyTrash() does the work.
        let countSnapshot = storage.softDeletedTotalCount()
        do {
            try storage.emptyTrash()
            purgedCount = countSnapshot
            await viewModel.loadStorageMetrics()
        } catch {
            clearError = error.localizedDescription
        }
    }

    /// Kick the iCloud file watcher so any `.inkbook` / `.json` files
    /// dropped by an external agent (e.g. cecilias-notes-mcp on Mac)
    /// get imported immediately instead of after iCloud's own sync
    /// cadence.
    private func pullFromCloud() async {
        isPullingFromCloud = true
        defer { isPullingFromCloud = false }
        await MainActor.run {
            CeciliasNotesFileWatcher.shared.rescan()
        }
        // Give iCloud a moment to start materialising any files the
        // metadata query just spotted, then surface a friendly
        // acknowledgement. The actual import notifications still flow
        // through the watcher → importer path; we just confirm the
        // pull was triggered.
        try? await Task.sleep(for: .seconds(1))
        pullFeedback = "Checked iCloud for new files from connected agents. New notebooks will appear in your library momentarily."
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
