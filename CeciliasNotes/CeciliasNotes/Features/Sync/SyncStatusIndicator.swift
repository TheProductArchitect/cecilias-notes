import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Continuous rotation for the syncing glyph. A single
    /// `.repeatForever` animation drives a steady spin — far smoother
    /// than the previous tick-loop that incremented the angle every
    /// 800ms (which stuttered at each tick boundary).
    @State private var spinning: Bool = false

    var body: some View {
#if os(macOS)
        macMenu
#else
        iosMenu
#endif
    }

#if os(macOS)
    private var macMenu: some View {
        Menu {
            macMenuHeader
            menuContent
        } label: {
            macToolbarIcon
        }
        .libraryToolbarMenuStyle()
        .accessibilityLabel(accessibilityLabelText)
        .onChange(of: isSyncing) { _, syncing in
            updateSpin(syncing)
        }
        .onAppear { updateSpin(isSyncing) }
    }

    @ViewBuilder
    private var macMenuHeader: some View {
        switch CloudKitContainerState.status {
        case .localOnlyFallback:
            Text("Not signed in to iCloud")
            Divider()
        case .uninitialized:
            Text("Syncing library…")
            Divider()
        default:
            EmptyView()
        }
    }

    private var macToolbarIcon: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isSyncing {
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                } else {
                    Image(systemName: macCloudGlyph)
                }
            }
            .font(.system(size: 14, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(macIconTint)

            if isSyncing {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)
                    .offset(x: 4, y: -2)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    /// Keep the glyph grey on Mac — accent tint on `Menu` labels renders
    /// as a solid blue pill with no visible cloud icon.
    private var macIconTint: Color {
        switch cloudSync.syncStatus {
        case .error: return theme.danger
        default:    return theme.recessiveQuaternary
        }
    }
#else
    private var iosMenu: some View {
        Menu {
            menuContent
        } label: {
            label
        }
        .libraryToolbarMenuStyle()
        .accessibilityLabel(accessibilityLabelText)
        .onChange(of: isSyncing) { _, syncing in
            updateSpin(syncing)
        }
        .onAppear { updateSpin(isSyncing) }
    }
#endif

    private func updateSpin(_ syncing: Bool) {
        if syncing, !reduceMotion {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                spinning = true
            }
        } else {
            withAnimation(.default) { spinning = false }
        }
    }

    // MARK: - Label (iOS)

#if os(iOS)
    @ViewBuilder
    private var label: some View {
        HStack(spacing: 8) {
            cloudGlyph
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cloudGlyph: some View {
        Group {
            if isSyncing {
                ZStack {
                    Image(systemName: "icloud")
                        .font(.system(size: 14, weight: .regular))
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .offset(y: 1)
                }
                .foregroundStyle(tint)
            } else {
                Image(systemName: glyph)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 44, height: 44)
    }
#endif

#if os(macOS)
    private var macCloudGlyph: String {
        switch CloudKitContainerState.status {
        case .localOnlyFallback: return "icloud.slash"
        case .uninitialized:     return "icloud"
        default:                  return glyph
        }
    }
#endif

    /// The status to DISPLAY. The CloudKit *database* sync (SwiftData)
    /// runs independently of `CloudSyncManager`'s iCloud-*Drive* file
    /// sync, and the latter's `isEnabled` flag defaults to `false`
    /// (`UserDefaults.bool` on an unset key). So on devices whose
    /// notebooks were syncing fine over CloudKit, the indicator still
    /// read "iCloud sync off" — purely because the secondary file-sync
    /// toggle had never been turned on (device log 2026-07-24:
    /// `privateDatabase` + account `available`). When the container is
    /// on the private database the app IS syncing to iCloud, so a
    /// `.disabled` file-sync status must not surface as "off"; present
    /// it as up-to-date instead.
    private var effectiveStatus: CloudSyncManager.SyncStatus {
        if cloudSync.syncStatus == .disabled,
           CloudKitContainerState.status == .privateDatabase {
            return .upToDate
        }
        return cloudSync.syncStatus
    }

    private var glyph: String {
        switch effectiveStatus {
        case .upToDate:          return "checkmark.icloud"
        case .syncing:           return "arrow.triangle.2.circlepath.icloud"
        case .checking:          return "arrow.triangle.2.circlepath.icloud"
        case .waitingForNetwork: return "icloud.slash"
        case .disabled:          return "icloud"
        case .error:             return "exclamationmark.icloud"
        }
    }

    private var tint: Color {
#if os(macOS)
        return macIconTint
#else
        switch effectiveStatus {
        case .upToDate:          return theme.recessiveQuaternary
        case .syncing, .checking: return theme.accent
        case .waitingForNetwork: return theme.recessiveTertiary
        case .disabled:          return theme.recessiveTertiary
        case .error:             return theme.danger
        }
#endif
    }

    private var isSyncing: Bool {
#if os(macOS)
        if CloudKitContainerState.status == .localOnlyFallback {
            return false
        }
#endif
        switch effectiveStatus {
        case .syncing, .checking: return true
        default:                  return false
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private var menuContent: some View {
        switch effectiveStatus {
        case .disabled:
            Text("iCloud sync off")
            Button("Open Settings → iCloud") {
#if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
#else
                if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
                    NSWorkspace.shared.open(url)
                }
#endif
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
        switch effectiveStatus {
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
