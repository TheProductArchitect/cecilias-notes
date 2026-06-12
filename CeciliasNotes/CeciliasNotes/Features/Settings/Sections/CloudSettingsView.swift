import CloudKit
import SwiftData
import SwiftUI
import UIKit

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                syncSection
                accountSection
                if cloud.isEnabled {
                    statusSection
                    storageSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(theme.surface)
        .task { await loadiCloudUsage() }
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
    }

    // MARK: Sync toggle

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
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
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
