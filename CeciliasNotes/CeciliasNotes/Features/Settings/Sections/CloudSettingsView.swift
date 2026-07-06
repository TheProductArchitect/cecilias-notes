import CloudKit
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Phase D + Phase 3 redesign — flat-white surface, editorial section
/// labels, hairline-only rows. Toggle drives `CloudSyncManager`'s
/// existing iCloud Drive flow (file-based sync); the live status row
/// reports CloudKit Database sync state via the three-state pattern
/// introduced in Prompt 7 (plain text, recessive italic — no icons,
/// no spinners, no error surfaces).
struct CloudSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var cloud: CloudSyncManager

    @State private var pendingEnable  = false
    @State private var pendingDisable = false
    @State private var localDataBytes: Int64 = 0
    @State private var isLoadingUsage = true

    /// `nil` until the first `CKContainer.accountStatus` callback
    /// lands. The status row reads this to decide between "up to
    /// date" and "sign in to iCloud to sync your notes" — the
    /// `.available` state means the user is signed in; anything
    /// else (`.noAccount`, `.restricted`, `.couldNotDetermine`,
    /// `.temporarilyUnavailable`) collapses to the sign-in prompt.
    @State private var iCloudAccountStatus: CKAccountStatus?

    /// The user's CloudKit user record ID once resolved. Hashed
    /// against the iCloud account — different accounts produce
    /// different IDs, so this lets the user tell at a glance which
    /// account the app is currently signed into without iOS having
    /// to expose the Apple ID email (which it doesn't to apps).
    @State private var iCloudUserRecordName: String?

    /// Notebook count surfaced from SwiftData. The body uses this
    /// to render "syncing N notebooks" — meaningful where
    /// "0 KB used" was misleading (CloudKit usage is not exposed
    /// by any public API, so the previous label was reading a
    /// nearly-always-empty ubiquity path).
    @Query(filter: #Predicate<Notebook> { $0.isDeleted == false })
    private var notebooksForCount: [Notebook]

    @Environment(\.theme) private var theme

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        self.cloud     = viewModel.cloudSyncManager
    }

    @State private var inboxEvents: [CeciliasNotesFileWatcher.InboxEvent] = []
    @State private var pendingFullReset: Bool = false
    @State private var resetInProgress: Bool = false
    @State private var resetStatusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                syncSection
                accountSection
                if cloud.isEnabled {
                    statusSection
                    storageSection
                }
                inboxActivitySection
                MultipeerSettingsSection()
                CloudConflictResolutionSection()
                dangerZoneSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(theme.surface)
        .task { await loadiCloudUsage() }
        .onAppear { refreshInboxEvents() }
        .onReceive(NotificationCenter.default.publisher(
            for: .ceciliasNotesInboxEventsChanged)
        ) { _ in refreshInboxEvents() }
        .alert("Enable iCloud sync?", isPresented: $pendingEnable) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") {
                Task { try? await cloud.enable() }
            }
        } message: {
            Text("Your notebooks will appear in the Files app under Cecilia's Notes.")
        }
        .alert("Disable iCloud sync?", isPresented: $pendingDisable) {
            Button("Cancel", role: .cancel) {}
            Button("Disable", role: .destructive) {
                Task { try? await cloud.disable() }
            }
        } message: {
            Text("Notes will remain on this device only.")
        }
        .alert("Reset all iCloud data?", isPresented: $pendingFullReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task { await performFullReset() }
            }
        } message: {
            Text("Removes every notebook, subject, quiz, audio recording, and image attachment from this device AND your iCloud account. Reinstalling the app afterward will start blank. This can't be undone.")
        }
    }

    // MARK: Sync toggle

    @State private var swiftDataCloudKitDisabled: Bool = UserDefaults.standard
        .bool(forKey: ModelContainer.swiftDataCloudKitDisabledKey)
    @State private var pendingDatabaseSyncRelaunch: Bool = false

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("sync")

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud sync")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.foreground)
                    Text("notebooks sync across your devices via iCloud drive.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foregroundSubtle)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { cloud.isEnabled },
                    set: { enabling in
                        if enabling { pendingEnable = true } else { pendingDisable = true }
                    }
                ))
                .labelsHidden()
                .tint(theme.accent)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }

            // Escape hatch for the chronic-CloudKit-stuck-export
            // scenario. When the SwiftData CloudKit pipeline gets
            // stuck retrying the same export task indefinitely (an
            // iOS-side bug we can't recover from in-app), every
            // mainContext read on the main runloop blocks for the
            // lock's duration — the editor freezes mid-render and
            // the user sees an unresponsive app. Disabling the
            // SwiftData CloudKit sync stops fighting that loop; the
            // on-disk store survives the toggle, file-asset iCloud
            // sync (media / audio via the ubiquity container) is
            // unaffected.
            //
            // Setting the toggle requires a relaunch because the
            // ModelContainer reads the value exactly once during
            // launch (a runtime switch would have to tear down and
            // rebuild every @Query view in flight).
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("disable database sync (advanced)")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.foreground)
                    Text("if the app is freezing on a stuck iCloud sync loop, turn this on, force-quit, and relaunch. notes stay on this device.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foregroundSubtle)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { swiftDataCloudKitDisabled },
                    set: { newValue in
                        swiftDataCloudKitDisabled = newValue
                        let defaults = UserDefaults.standard
                        defaults.set(
                            newValue,
                            forKey: ModelContainer.swiftDataCloudKitDisabledKey
                        )
                        // Force-flush so a fast force-quit (which
                        // is exactly what the alert tells the user
                        // to do next) doesn't lose the value before
                        // UserDefaults' own periodic flush runs.
                        defaults.synchronize()
                        pendingDatabaseSyncRelaunch = true
                    }
                ))
                .labelsHidden()
                .tint(theme.accent)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
        }
        .alert("Relaunch the app", isPresented: $pendingDatabaseSyncRelaunch) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Force-quit and relaunch Cecilia's Notes for the database-sync change to take effect.")
        }
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("status")

            VStack(alignment: .leading, spacing: 4) {
                statusRow
                if let lastSynced = cloud.lastSyncedAt {
                    Text("last synced \(relativeDate(lastSynced))")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foregroundSubtle)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }

            Button {
                Task { await cloud.syncNow() }
            } label: {
                Text("sync now")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.accent)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!cloud.isEnabled)
        }
    }

    /// Plain-text, three-state status row per Prompt 7 spec. Recessive
    /// grey 12pt italic. **No icons, no spinners.** Errors are
    /// swallowed — a sync failure (network offline, CloudKit
    /// unavailable) reads as "up to date" rather than surfacing an
    /// error to the user. CloudKit retries automatically and the
    /// state self-corrects on the next successful sync.
    @ViewBuilder
    private var statusRow: some View {
        Text(statusText)
            .font(.system(size: 12).italic())
            .foregroundStyle(theme.foregroundSubtle)
            .task { await refreshAccountStatus() }
            .onReceive(NotificationCenter.default.publisher(
                for: .CKAccountChanged
            )) { _ in
                Task { await refreshAccountStatus() }
            }
    }

    private var statusText: String {
        // Two-state status, account-driven only. The legacy
        // `cloud.syncStatus` is `CloudSyncManager`'s iCloud-Drive
        // file-presence flag — SwiftData CloudKit sync runs on a
        // separate, opaque pipeline (`NSPersistentCloudKitContainer`
        // internals) that exposes no public progress publisher.
        // Reading `syncStatus` here used to keep the row stuck on
        // "syncing…" indefinitely. "up to date" is the honest
        // default for any signed-in user; CloudKit retries
        // failures silently in the background.
        if let status = iCloudAccountStatus, status != .available {
            return "sign in to iCloud to sync your notes"
        }
        return "up to date"
    }

    private func refreshAccountStatus() async {
        let status: CKAccountStatus = await withCheckedContinuation { cont in
            CKContainer(identifier: "iCloud.app.ceciliasnotes")
                .accountStatus { status, _ in
                    cont.resume(returning: status)
                }
        }
        await MainActor.run { iCloudAccountStatus = status }
    }

    // MARK: Account

    /// Surfaces the iCloud sign-in state and a stable identifier
    /// for the account currently in use. iOS doesn't expose the
    /// Apple ID email to apps; the CloudKit user record name is
    /// the closest the system lets us get to "which account is
    /// this" — it's a hash derived from the iCloud account, so
    /// two different accounts produce two different IDs. A
    /// "manage in Settings" button opens the iOS Settings app so
    /// the user can verify the human-readable Apple ID outside
    /// the app.
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("icloud account")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("status")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.foreground)
                    Spacer()
                    Text(accountStatusText)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.recessivePrimary)
                }

                if let userID = iCloudUserRecordName {
                    HStack(alignment: .top) {
                        Text("account id")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.foreground)
                        Spacer()
                        Text(shortAccountID(userID))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.recessivePrimary)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Text("ios doesn't expose your apple id email to apps. open settings to verify which account is signed into icloud on this device.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.foregroundSubtle)
                    .padding(.top, 2)

                Button {
                    PlatformApp.openSystemSettings()
                } label: {
                    Text("open settings")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.accent)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
        }
        .task { await refreshAccountIdentity() }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            Task { await refreshAccountIdentity() }
        }
    }

    private var accountStatusText: String {
        guard let status = iCloudAccountStatus else { return "checking…" }
        switch status {
        case .available:              return "signed in"
        case .noAccount:              return "not signed in"
        case .restricted:             return "restricted"
        case .temporarilyUnavailable: return "temporarily unavailable"
        case .couldNotDetermine:      return "unknown"
        @unknown default:             return "unknown"
        }
    }

    private func shortAccountID(_ id: String) -> String {
        // CloudKit user record names are GUID-shaped. Keep the head
        // and tail so the user can recognise + compare without the
        // full opaque string dominating the row.
        guard id.count > 16 else { return id }
        return String(id.prefix(8)) + "…" + String(id.suffix(6))
    }

    private func refreshAccountIdentity() async {
        let container = CKContainer(identifier: "iCloud.app.ceciliasnotes")
        let status: CKAccountStatus = await withCheckedContinuation { cont in
            container.accountStatus { status, _ in cont.resume(returning: status) }
        }
        await MainActor.run { iCloudAccountStatus = status }
        guard status == .available else {
            await MainActor.run { iCloudUserRecordName = nil }
            return
        }
        let recordName: String? = await withCheckedContinuation { cont in
            container.fetchUserRecordID { recordID, _ in
                cont.resume(returning: recordID?.recordName)
            }
        }
        await MainActor.run { iCloudUserRecordName = recordName }
    }

    // MARK: Storage

    /// The old "used in iCloud" readout summed the ubiquity
    /// container's `Documents/Notebooks` directory — a path that
    /// is empty for most users because SwiftData rows sync via
    /// CloudKit's private database (no filesystem footprint) and
    /// images / audio live in the **local** `Documents/MediaAttachments`
    /// tree. That left the user reading "0 KB" while real data
    /// existed everywhere. The replacement honestly reports
    /// **local data size** — sum of the SQLite store, media
    /// attachments, and the ubiquity Notebooks dir — alongside a
    /// count of what's syncing.
    /// Last few events from the iCloud inbox watcher. Built directly
    /// for the "MCP wrote a notebook, why didn't it appear?" case:
    /// the user can see in real time whether iCloud actually
    /// delivered the file, whether it was downloaded, and whether
    /// the importer ran.
    private var inboxActivitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("inbox activity")
                Spacer()
                Button {
                    CeciliasNotesFileWatcher.shared.rescan()
                    HapticManager.shared.toolSwitched()
                } label: {
                    Text("pull")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            }
            if inboxEvents.isEmpty {
                Text("no files seen yet. when a connected agent (cecilias-notes-mcp on mac, share-extension drop, etc.) lands a file in the icloud inbox, it'll appear here.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.foregroundSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Stats strip — counts derived from the rolling
                // 50-event buffer. Gives the user a one-line answer
                // to "is the pipeline healthy?" without scanning
                // the row list every time.
                inboxStatsStrip
                Rectangle().fill(theme.hairline).frame(height: 0.5)
                VStack(spacing: 0) {
                    ForEach(inboxEvents.prefix(15)) { event in
                        inboxEventRow(event)
                        Rectangle().fill(theme.hairline).frame(height: 0.5)
                    }
                }
                if inboxEvents.count > 15 {
                    Text("\(inboxEvents.count - 15) older event\(inboxEvents.count - 15 == 1 ? "" : "s") rolled off")
                        .font(.system(size: 10).italic())
                        .foregroundStyle(theme.foregroundSubtle)
                        .padding(.top, 6)
                }
                // Inbox-path footnote — useful when the user wants
                // to confirm WHERE on iCloud Drive the watcher is
                // looking (the spot the Mac MCP / share extension
                // write to). Truncates from the front so the
                // notebooks-relative tail stays visible.
                if let path = inboxPathDisplay() {
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.foregroundSubtle)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.top, 8)
                }
            }
        }
    }

    /// One-line summary above the event list. Counts events in
    /// the rolling buffer (the watcher caps at 50, so this is
    /// "recent" not "lifetime"; reset on app launch).
    private var inboxStatsStrip: some View {
        let imported    = inboxEvents.filter { $0.kind == .imported }.count
        let downloading = inboxEvents.filter { $0.kind == .downloading }.count
        let skipped     = inboxEvents.filter {
            $0.kind == .skippedDuplicate || $0.kind == .unknownExtension
        }.count
        let lastImport = inboxEvents.first { $0.kind == .imported }?.date

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                inboxStat(value: imported,    label: "imported")
                inboxStat(value: downloading, label: "downloading")
                inboxStat(value: skipped,     label: "skipped")
            }
            if let lastImport {
                Text("last imported \(relativeTimeString(from: lastImport))")
                    .font(.system(size: 10).italic())
                    .foregroundStyle(theme.foregroundSubtle)
            }
        }
        .padding(.bottom, 4)
    }

    private func inboxStat(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.foreground)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.foregroundSubtle)
        }
    }

    /// Human-readable "Nm ago" / "Nh ago" / "yesterday" string for
    /// the last-import footnote.
    private func relativeTimeString(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Resolved iCloud-inbox path, abbreviated with the
    /// `~/Library/Mobile Documents/…/Inbox` tail. Nil when iCloud
    /// isn't available (the watcher couldn't resolve a container).
    private func inboxPathDisplay() -> String? {
        guard let url = CeciliasNotesFileWatcher.sharedInboxURL() else { return nil }
        let path = url.path
        // Trim the device-specific prefix; keep the container-
        // relative portion that's stable across devices.
        if let range = path.range(of: "Mobile Documents/") {
            return "📂 …/" + String(path[range.upperBound...])
        }
        return "📂 " + path
    }

    private func inboxEventRow(_ event: CeciliasNotesFileWatcher.InboxEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.inboxTimeFormatter.string(from: event.date))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.foregroundSubtle)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.filename)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(inboxEventLabel(event.kind))
                    .font(.system(size: 10).italic())
                    .foregroundStyle(inboxEventColor(event.kind))
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func inboxEventLabel(_ kind: CeciliasNotesFileWatcher.InboxEvent.Kind) -> String {
        switch kind {
        case .detected:          return "detected (in iCloud)"
        case .downloading:       return "downloading from iCloud…"
        case .imported:          return "imported into library"
        case .skippedDuplicate:  return "skipped — already imported"
        case .unknownExtension:  return "skipped — unknown extension"
        }
    }

    private func inboxEventColor(_ kind: CeciliasNotesFileWatcher.InboxEvent.Kind) -> Color {
        switch kind {
        case .imported:                              return theme.accent
        case .downloading, .detected:                return theme.foregroundMuted
        case .skippedDuplicate, .unknownExtension:   return theme.foregroundSubtle
        }
    }

    private func refreshInboxEvents() {
        inboxEvents = CeciliasNotesFileWatcher.shared.recentEvents
    }

    private static let inboxTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("storage")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("syncing")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.foreground)
                    Spacer()
                    Text("\(notebooksForCount.count) notebook\(notebooksForCount.count == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.recessivePrimary)
                        .monospacedDigit()
                }
                HStack {
                    Text("local data on this device")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.foreground)
                    Spacer()
                    if isLoadingUsage {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text(ByteCountFormatter.string(fromByteCount: localDataBytes, countStyle: .file))
                            .font(.system(size: 13))
                            .foregroundStyle(theme.recessivePrimary)
                            .monospacedDigit()
                    }
                }
                Text("cloudkit doesn't expose the synced-bytes total to apps. the local figure above is the upper bound of what could be synced — your notebook rows go over cloudkit, while images and audio stay on this device for now.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.foregroundSubtle)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
        }
    }

    // MARK: Danger zone

    /// Full reset of every SwiftData row on this device. CloudKit
    /// syncs the deletions back so the user's iCloud account also
    /// drops the records — which fixes the "I deleted everything in
    /// the app, reinstalled, and the old notebooks came back"
    /// gotcha (Apple's CloudKit preserves records across reinstalls
    /// because the data lives in the account, not the app sandbox).
    /// The destructive alert is the gate; the message lists exactly
    /// what disappears.
    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("danger zone")
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    pendingFullReset = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("reset all icloud data")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.danger)
                            Text("clears every notebook, subject, quiz, recording and image — on this device and in your icloud account. reinstalling won't bring them back.")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(theme.foregroundSubtle)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        if resetInProgress {
                            ProgressView().scaleEffect(0.6)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(resetInProgress)

                if let resetStatusMessage {
                    Text(resetStatusMessage)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(theme.recessivePrimary)
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
        }
    }

    private func performFullReset() async {
        resetInProgress = true
        resetStatusMessage = nil
        let start = Date()
        await viewModel.resetAllUserData()
        let elapsed = Date().timeIntervalSince(start)
        resetInProgress = false
        resetStatusMessage = String(format: "reset complete in %.1fs — sync will propagate the deletes to icloud over the next few minutes.", elapsed)
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date()).lowercased()
    }

    // MARK: Compute local data total

    /// Sum the file sizes across every directory that holds user
    /// data this app could ever sync. Includes:
    ///   • the SwiftData SQLite store (and its sidecar
    ///     `-wal` / `-shm` files) — the bytes CloudKit replays to
    ///     other devices
    ///   • `Documents/MediaAttachments/` — images, audio,
    ///     lectures, PDFs (local-only today, but counted so the
    ///     user sees what's on disk)
    ///   • the iCloud ubiquity `Documents/Notebooks/` directory
    ///     when sync is on (legacy file-coordination path; the
    ///     old code only counted this and nothing else)
    /// CloudKit's *actual* used-bytes figure isn't exposed by any
    /// public API, so we report this honest local total instead
    /// of "0 KB" — the previous label that read the wrong path.
    private func loadiCloudUsage() async {
        isLoadingUsage = true
        localDataBytes = await Task.detached(priority: .utility) {
            var total: Int64 = 0
            var roots: [URL] = []
            // SQLite store + sidecars. The container lives under
            // Application Support; sum that directory rather than
            // naming each file so .sqlite-wal / .sqlite-shm are
            // automatically included.
            roots.append(StorageService.ceciliasNotesDirectoryURL)
            // Local media bytes.
            roots.append(MediaStorage.rootURL)
            // Legacy ubiquity Notebooks path (was the only thing
            // counted before — keep it so existing users with
            // file-coordination data continue to see it reflected).
            if let icloudNotebooks = FileManager.default
                .url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents/Notebooks") {
                roots.append(icloudNotebooks)
            }
            for root in roots {
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: .skipsHiddenFiles
                ) else { continue }
                while let next = enumerator.nextObject() {
                    guard let url = next as? URL else { continue }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .flatMap { Int64($0) } ?? 0
                    total += size
                }
            }
            return total
        }.value
        isLoadingUsage = false
    }
}
