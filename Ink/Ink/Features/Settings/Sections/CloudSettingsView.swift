import SwiftUI

struct CloudSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var cloud: CloudSyncManager

    @State private var pendingEnable  = false
    @State private var pendingDisable = false
    @State private var iCloudUsedBytes: Int64 = 0
    @State private var isLoadingUsage = true

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        self.cloud     = viewModel.cloudSyncManager
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Ink.Spacing.lg) {
                iCloudCard
                storageRow
            }
            .padding(Ink.Spacing.lg)
        }
        .background(Color.inkBackgroundSecondary.ignoresSafeArea())
        .navigationTitle("iCloud")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadiCloudUsage() }
        // Enable confirmation
        .alert("Enable iCloud Sync?", isPresented: $pendingEnable) {
            Button("Cancel", role: .cancel) {}
            Button("Enable iCloud") {
                Task { try? await cloud.enable() }
            }
        } message: {
            Text("Your notebooks will appear in the Files app under Ink.")
        }
        // Disable confirmation
        .alert("Disable iCloud Sync?", isPresented: $pendingDisable) {
            Button("Cancel", role: .cancel) {}
            Button("Disable Sync", role: .destructive) {
                Task { try? await cloud.disable() }
            }
        } message: {
            Text("Notes will remain on this device only.")
        }
    }

    // MARK: iCloud Card (full-width prominent card)

    private var iCloudCard: some View {
        VStack(spacing: Ink.Spacing.md) {
            // Header row
            HStack(alignment: .center, spacing: Ink.Spacing.md) {
                Image(systemName: "icloud")
                    .font(.inkLargeMetric)
                    .foregroundColor(cloud.isEnabled ? .inkAccentPrimary : .inkTextSecondary)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync with iCloud Drive")
                        .font(.inkHeadline)
                        .foregroundColor(.inkTextPrimary)
                    Text("Notebooks appear in the Files app under Ink.")
                        .font(.inkCaption)
                        .foregroundColor(.inkTextSecondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { cloud.isEnabled },
                    set: { enabling in
                        if enabling { pendingEnable = true } else { pendingDisable = true }
                    }
                ))
                .labelsHidden()
                .tint(.inkAccentPrimary)
            }

            // Status area (shown when enabled)
            if cloud.isEnabled {
                InkDivider()
                syncStatusView

                InkButton("Sync Now", style: .ghost) {
                    Task { await cloud.syncNow() }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    @ViewBuilder
    private var syncStatusView: some View {
        switch cloud.syncStatus {
        case .disabled:
            EmptyView()

        case .checking:
            HStack(spacing: Ink.Spacing.sm) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Syncing…")
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextSecondary)
                Spacer()
            }

        case .syncing(let progress):
            HStack(spacing: Ink.Spacing.sm) {
                ProgressView(value: progress)
                    .tint(.inkAccentPrimary)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.inkMono)
                    .foregroundColor(.inkTextSecondary)
                    .monospacedDigit()
                Spacer()
            }

        case .upToDate:
            HStack(spacing: Ink.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.inkAccentPrimary)
                Text("Up to date")
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextPrimary)
                Spacer()
            }

        case .error(let msg):
            VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
                HStack(spacing: Ink.Spacing.sm) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.inkDestructive)
                    Text(msg)
                        .font(.inkCaption)
                        .foregroundColor(.inkDestructive)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                HStack(spacing: Ink.Spacing.sm) {
                    Button("Retry") { Task { await cloud.syncNow() } }
                        .buttonStyle(.inkPressable)
                        .font(.inkSubhead)
                        .foregroundColor(.inkAccentPrimary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.inkPressable)
                    .font(.inkSubhead)
                    .foregroundColor(.inkAccentPrimary)
                    Spacer()
                }
            }
        }
    }

    // MARK: Storage used by Ink in iCloud

    private var storageRow: some View {
        HStack {
            Label("iCloud Storage Used by Ink", systemImage: "chart.pie")
                .font(.inkBody)
                .foregroundColor(.inkTextPrimary)
            Spacer()
            if isLoadingUsage {
                ProgressView().scaleEffect(0.7)
            } else {
                Text(ByteCountFormatter.string(fromByteCount: iCloudUsedBytes, countStyle: .file))
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextSecondary)
                    .monospacedDigit()
            }
        }
        .padding(Ink.Spacing.md)
        .inkCard()
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
            for case let url as URL in enumerator {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .flatMap { Int64($0) } ?? 0
                total += size
            }
            return total
        }.value
        isLoadingUsage = false
    }
}
