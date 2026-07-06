import CloudKit
import SwiftData
import SwiftUI

/// macOS iCloud settings — grouped form, short copy, advanced options tucked away.
struct MacCloudSettingsView: View {
    @EnvironmentObject private var cloudSync: CloudSyncManager
    @Environment(\.theme) private var theme

    @State private var pendingEnable = false
    @State private var pendingDisable = false
    @State private var swiftDataCloudKitDisabled = UserDefaults.standard
        .bool(forKey: ModelContainer.swiftDataCloudKitDisabledKey)
    @State private var pendingDatabaseSyncRelaunch = false
    @State private var iCloudAccountStatus: CKAccountStatus?
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { cloudSync.isEnabled },
                    set: { enabling in
                        if enabling { pendingEnable = true } else { pendingDisable = true }
                    }
                ))

                if cloudSync.isEnabled {
                    LabeledContent("Files", value: fileSyncStatusLabel)
                    LabeledContent("Database", value: databaseSyncStatusLabel)

                    Button("Sync Now") {
                        Task { await cloudSync.syncNow() }
                    }
                }
            } footer: {
                Text("Notebooks and media stay in step across your Mac, iPad, and iPhone.")
            }

            Section("Nearby Devices") {
                MacMultipeerPairingSection()
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    Toggle("Disable database sync", isOn: Binding(
                        get: { swiftDataCloudKitDisabled },
                        set: { newValue in
                            swiftDataCloudKitDisabled = newValue
                            let defaults = UserDefaults.standard
                            defaults.set(newValue, forKey: ModelContainer.swiftDataCloudKitDisabledKey)
                            defaults.synchronize()
                            pendingDatabaseSyncRelaunch = true
                        }
                    ))

                    if CloudKitContainerState.status == .localOnlyFallback {
                        Text("Database sync paused after unclean shutdowns. Turn this off and relaunch, or sign in to iCloud.")
                            .font(.caption)
                            .foregroundStyle(theme.danger)
                    }

                    MacCloudConflictSummary()
                }
            } footer: {
                Text("Only change database sync if the app freezes on startup.")
            }
        }
        .formStyle(.grouped)
        .task { await refreshAccountStatus() }
        .alert("Enable iCloud sync?", isPresented: $pendingEnable) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") {
                Task { try? await cloudSync.enable() }
            }
        } message: {
            Text("Your notebooks will sync across your Apple devices.")
        }
        .alert("Disable iCloud sync?", isPresented: $pendingDisable) {
            Button("Cancel", role: .cancel) {}
            Button("Disable", role: .destructive) {
                Task { try? await cloudSync.disable() }
            }
        } message: {
            Text("Notes will stay on this Mac only.")
        }
        .alert("Relaunch required", isPresented: $pendingDatabaseSyncRelaunch) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Quit and reopen Cecilia's Notes for this change to take effect.")
        }
    }

    private var fileSyncStatusLabel: String {
        switch cloudSync.syncStatus {
        case .disabled: return "Off"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .syncing: return "Syncing…"
        case .waitingForNetwork: return "No network"
        case .error(let message): return message
        }
    }

    private var databaseSyncStatusLabel: String {
        if swiftDataCloudKitDisabled { return "Off" }
        switch CloudKitContainerState.status {
        case .privateDatabase:
            return iCloudAccountStatus == .available ? "Active" : "Sign in to iCloud"
        case .localOnlyFallback:
            return "Paused"
        case .localOnlyIntentional:
            return "Off"
        case .uninitialized:
            return "Starting…"
        }
    }

    private func refreshAccountStatus() async {
        let status = try? await CKContainer(identifier: "iCloud.app.ceciliasnotes")
            .accountStatus()
        await MainActor.run { iCloudAccountStatus = status }
    }
}

/// Compact conflict log — no wall of explanatory text.
private struct MacCloudConflictSummary: View {
    @State private var records: [SyncConflictLog.Record] = []
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if records.isEmpty {
                Text("No recent merge conflicts")
                    .font(.caption)
                    .foregroundStyle(theme.foregroundSubtle)
            } else {
                ForEach(records.prefix(5)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.notebookTitle)
                            .font(.subheadline)
                        Text(item.resolution)
                            .font(.caption)
                            .foregroundStyle(theme.foregroundSubtle)
                    }
                }
                Button("Clear History") {
                    SyncConflictLog.clear()
                    refresh()
                }
                .font(.caption)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .syncConflictLogChanged)) { _ in
            refresh()
        }
    }

    private func refresh() {
        records = SyncConflictLog.records
    }
}
