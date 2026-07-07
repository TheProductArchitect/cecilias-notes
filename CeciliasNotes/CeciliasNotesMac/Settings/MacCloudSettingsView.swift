import CloudKit
import SwiftData
import SwiftUI

/// macOS iCloud settings — one clear status, separate iCloud vs nearby pairing.
struct MacCloudSettingsView: View {
    @EnvironmentObject private var cloudSync: CloudSyncManager
    @Environment(\.theme) private var theme

    @State private var pendingEnable = false
    @State private var pendingDisable = false
    @State private var swiftDataCloudKitDisabled = UserDefaults.standard
        .bool(forKey: ModelContainer.swiftDataCloudKitDisabledKey)
    @State private var pendingDatabaseSyncRelaunch = false
    @State private var iCloudAccountStatus: CKAccountStatus?
    @State private var showTroubleshooting = false
    @State private var pendingCloudKitRecoveryRelaunch = false

    private var isDatabasePaused: Bool {
        CloudKitContainerState.status == .localOnlyFallback
    }

    var body: some View {
        Form {
            Section {
                if isDatabasePaused {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Notebook sync paused", systemImage: "exclamationmark.icloud")
                            .font(.headline)
                            .foregroundStyle(theme.danger)
                        Text("The app shut down uncleanly twice, so notebook syncing was paused to protect your data. Notes on this Mac are safe.")
                            .font(.callout)
                            .foregroundStyle(theme.foregroundMuted)
                        Button("Restore & Relaunch") {
                            pendingCloudKitRecoveryRelaunch = true
                        }
                        .buttonStyle(.borderedProminent)
                        .macSuppressFocusRing()
                    }
                    .padding(.vertical, 4)
                }

                Toggle("Sync with iCloud", isOn: Binding(
                    get: { cloudSync.isEnabled },
                    set: { enabling in
                        if enabling { pendingEnable = true } else { pendingDisable = true }
                    }
                ))

                if cloudSync.isEnabled {
                    LabeledContent("Notebooks", value: databaseSyncStatusLabel)
                    LabeledContent("Photos & files", value: fileSyncStatusLabel)

                    Button("Sync Now") {
                        Task { await cloudSync.syncNow() }
                    }
                    .macSuppressFocusRing()
                }
            } footer: {
                if isDatabasePaused {
                    Text("Use Restore & Relaunch above — toggling iCloud off and on won't fix a paused database.")
                } else {
                    Text("Notebooks and media stay in step across your Mac, iPad, and iPhone.")
                }
            }

            Section {
                MacMultipeerPairingSection()
            } header: {
                Text("Send to iPad")
            } footer: {
                Text("Pair on the same Wi‑Fi to send pages to a nearby device. Separate from iCloud sync.")
            }

            Section {
                DisclosureGroup("Troubleshooting", isExpanded: $showTroubleshooting) {
                    if !isDatabasePaused {
                        Toggle("Disable notebook database sync", isOn: Binding(
                            get: { swiftDataCloudKitDisabled },
                            set: { newValue in
                                swiftDataCloudKitDisabled = newValue
                                let defaults = UserDefaults.standard
                                defaults.set(newValue, forKey: ModelContainer.swiftDataCloudKitDisabledKey)
                                defaults.synchronize()
                                pendingDatabaseSyncRelaunch = true
                            }
                        ))
                        Text("Only if the app freezes on startup. Photos & files sync is unaffected.")
                            .font(.caption)
                            .foregroundStyle(theme.foregroundSubtle)
                    }

                    MacCloudConflictSummary()
                }
            } footer: {
                if isDatabasePaused {
                    Text("Notebook sync is already paused — use Restore & Relaunch in the section above.")
                } else {
                    Text("Leave database sync on unless support asks you to turn it off.")
                }
            }
        }
        .formStyle(.grouped)
        .macFormFocusChrome()
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
        .alert("Restore sync and relaunch?", isPresented: $pendingCloudKitRecoveryRelaunch) {
            Button("Cancel", role: .cancel) {}
            Button("Restore & Relaunch") {
                ModelContainer.prepareCloudKitRecoveryRelaunch()
                relaunchApp()
            }
        } message: {
            Text("Cecilia's Notes will quit and reopen with notebook sync re-enabled. Unsaved edits are saved automatically first.")
        }
    }

    /// Spawn a fresh instance, then terminate this one. The button
    /// says "Relaunch" — making the user quit by hand after a promise
    /// of relaunching reads as a broken button.
    private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
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
                .macSuppressFocusRing()
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
