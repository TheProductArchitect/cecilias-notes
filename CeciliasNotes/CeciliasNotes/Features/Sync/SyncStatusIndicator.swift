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

    /// Rotating phase for the syncing glyph. SwiftUI's
    /// `.rotationEffect` driven by an `@State` Double, ticked by a
    /// `.task` that sleeps 1s and increments — cheap, no Timer
    /// allocation, cancels when the view leaves the hierarchy.
    @State private var spin: Double = 0

    var body: some View {
        Menu {
            menuContent
        } label: {
            label
        }
        .menuStyle(.button)
        .accessibilityLabel(accessibilityLabelText)
        .task(id: cloudSync.syncStatus) {
            // Spin only while syncing — the task is replaced when
            // `.syncStatus` changes value, which cancels the
            // previous spin loop automatically.
            guard isSyncing else { return }
            while !Task.isCancelled, isSyncing {
                try? await Task.sleep(for: .milliseconds(800))
                if Task.isCancelled { break }
                withAnimation(.linear(duration: 0.8)) {
                    spin += 360
                }
            }
        }
    }

    // MARK: - Label

    @ViewBuilder
    private var label: some View {
        Image(systemName: glyph)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(tint)
            .rotationEffect(.degrees(isSyncing ? spin : 0))
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
            Text("Enable in Settings → iCloud")
        case .upToDate:
            if let date = cloudSync.lastSyncedAt {
                Text("Last synced \(Self.relative(date))")
            } else {
                Text("All changes synced")
            }
        case .syncing(let progress):
            let pct = max(0, min(100, Int(progress * 100)))
            Text("Syncing… \(pct)%")
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
        case .syncing(let p):     return "Syncing, \(Int(p * 100)) percent"
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
