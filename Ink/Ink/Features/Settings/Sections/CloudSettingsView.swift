import CloudKit
import SwiftUI

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
    @State private var iCloudUsedBytes: Int64 = 0
    @State private var isLoadingUsage = true

    /// `nil` until the first `CKContainer.accountStatus` callback
    /// lands. The status row reads this to decide between "up to
    /// date" and "sign in to iCloud to sync your notes" — the
    /// `.available` state means the user is signed in; anything
    /// else (`.noAccount`, `.restricted`, `.couldNotDetermine`,
    /// `.temporarilyUnavailable`) collapses to the sign-in prompt.
    @State private var iCloudAccountStatus: CKAccountStatus?

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

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        self.cloud     = viewModel.cloudSyncManager
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                syncSection
                if cloud.isEnabled {
                    statusSection
                    storageSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(Color(.systemBackground))
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
                        .foregroundStyle(Color.inkTextPrimary)
                    Text("notebooks sync across your devices via iCloud drive.")
                        .font(.system(size: 11))
                        .foregroundStyle(Self.captionColour)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { cloud.isEnabled },
                    set: { enabling in
                        if enabling { pendingEnable = true } else { pendingDisable = true }
                    }
                ))
                .labelsHidden()
                .tint(.brandAccent)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Self.hairlineColour).frame(height: 0.5)
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
                        .foregroundStyle(Self.captionColour)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Self.hairlineColour).frame(height: 0.5)
            }

            Button {
                Task { await cloud.syncNow() }
            } label: {
                Text("sync now")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.brandAccent)
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
            .foregroundStyle(Self.captionColour)
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
            CKContainer(identifier: "iCloud.com.wave.venu.Ink")
                .accountStatus { status, _ in
                    cont.resume(returning: status)
                }
        }
        await MainActor.run { iCloudAccountStatus = status }
    }

    // MARK: Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("storage")
            HStack {
                Text("used in iCloud")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkTextPrimary)
                Spacer()
                if isLoadingUsage {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: iCloudUsedBytes, countStyle: .file))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkRecessivePrimary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Self.hairlineColour).frame(height: 0.5)
            }
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

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date()).lowercased()
    }

    // MARK: Compute iCloud usage

    private func loadiCloudUsage() async {
        isLoadingUsage = true
        iCloudUsedBytes = await Task.detached(priority: .utility) {
            guard let ubiquityURL = FileManager.default
                .url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents/Notebooks")
            else { return Int64(0) }
            var total: Int64 = 0
            guard let enumerator = FileManager.default.enumerator(
                at: ubiquityURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: .skipsHiddenFiles
            ) else { return Int64(0) }
            while let next = enumerator.nextObject() {
                guard let url = next as? URL else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .flatMap { Int64($0) } ?? 0
                total += size
            }
            return total
        }.value
        isLoadingUsage = false
    }
}
