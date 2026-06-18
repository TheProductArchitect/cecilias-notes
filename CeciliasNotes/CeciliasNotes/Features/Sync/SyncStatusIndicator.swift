import SwiftUI

/// Compact sync-state badge that surfaces `CloudSyncManager.syncStatus`
/// in chrome. Renders one of five glyphs (idle / syncing / waiting /
/// disabled / error), tap-opens a menu with the last-synced timestamp
/// + error message + retry.
///
/// Step 10 — first user-visible surface for the cloud sync state.
/// Read-only on the way in: the indicator doesn't drive sync, it
/// reports it. The "Try again" menu item routes through the existing
/// `reconcileAfterLaunch()` path.
struct SyncStatusIndicator: View {

    @EnvironmentObject private var cloudSync: CloudSyncManager
    @Environment(\.theme) private var theme

    /// Continuous rotation for the syncing glyph. A single
    /// `.repeatForever` animation drives a steady spin — far smoother
    /// than the previous tick-loop that incremented the angle every
    /// 800ms (which stuttered at each tick boundary).
    @State private var spinning: Bool = false

    var body: some View {
        Menu {
            menuContent
        } label: {
            label
        }
        .menuStyle(.button)
        .accessibilityLabel(accessibilityLabelText)
        .onChange(of: isSyncing) { _, syncing in
            updateSpin(syncing)
        }
        .onAppear { updateSpin(isSyncing) }
    }

    private func updateSpin(_ syncing: Bool) {
        if syncing {
            // 2.4s/rev — a calm, legible rotation. A faster spin
            // reads as "frantic / stuck" rather than "working".
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                spinning = true
            }
        } else {
            withAnimation(.default) { spinning = false }
        }
    }

    // MARK: - Label

    @ViewBuilder
    private var label: some View {
        Group {
            if isSyncing {
                // Static cloud with the circular arrows spinning
                // *inside* it — only the arrows rotate, the cloud
                // outline stays put. Reads as "working" without the
                // whole glyph wobbling.
                ZStack {
                    Image(systemName: "icloud")
                        .font(.system(size: 13, weight: .regular))
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 7, weight: .semibold))
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .offset(y: 1)
                }
                .foregroundStyle(tint)
            } else {
                Image(systemName: glyph)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }

    private var glyph: String {
        switch cloudSync.syncStatus {
        case .upToDate:          return "checkmark.icloud"
        case .syncing:           return "arrow.triangle.2.circlepath.icloud"
        case .checking:          return "arrow.triangle.2.circlepath.icloud"
        case .waitingForNetwork: return "icloud.slash"
        case .disabled:          return "icloud"
        case .error:             return "exclamationmark.icloud"
        }
    }

    private var tint: Color {
        switch cloudSync.syncStatus {
        case .upToDate:          return theme.recessiveQuaternary
        case .syncing, .checking: return theme.accent
        case .waitingForNetwork: return theme.recessiveTertiary
        case .disabled:          return theme.recessiveTertiary
        case .error:             return theme.danger
        }
    }

    private var isSyncing: Bool {
        switch cloudSync.syncStatus {
        case .syncing, .checking: return true
        default:                  return false
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private var menuContent: some View {
        switch cloudSync.syncStatus {
        case .disabled:
            Text("iCloud sync off")
            Button("Open Settings → iCloud") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        case .upToDate:
            if let date = cloudSync.lastSyncedAt {
                Text("Last synced \(Self.relative(date))")
            } else {
                Text("All changes synced")
            }
        case .syncing:
            // No percentage — NSMetadataQuery snapshots can't give a
            // reliable progress figure, and a stuck number reads
            // worse than an honest "in progress".
            Text("Syncing…")
        case .checking:
            Text("Checking iCloud…")
        case .waitingForNetwork:
            Text("Waiting for network")
            Text("Sync resumes when reachable")
        case .error(let message):
            Text("Sync issue")
            Text(message)
            Divider()
            Button("Try again") {
                Task { await retry() }
            }
        }
    }

    private var accessibilityLabelText: String {
        switch cloudSync.syncStatus {
        case .disabled:           return "iCloud sync disabled"
        case .upToDate:           return "iCloud synced"
        case .syncing:            return "Syncing"
        case .checking:           return "Checking iCloud"
        case .waitingForNetwork:  return "Waiting for network"
        case .error:              return "Sync error"
        }
    }

    private func retry() async {
        // The existing reconcile path covers the same recovery cases
        // the user sees in the menu — it re-runs availability check
        // + restarts NSMetadataQuery. Safe to call when already
        // healthy (idempotent re-enter of `.checking → .upToDate`).
        await cloudSync.reconcileAfterLaunchForExternalRetry()
    }

    // MARK: - Formatting

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
