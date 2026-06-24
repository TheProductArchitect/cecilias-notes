import CloudKit
import Foundation
import SwiftData

/// Runtime visibility into whether the production ModelContainer
/// came up on the CloudKit path or fell back to a local-only
/// store. Read by the Library to surface a "your other devices'
/// notes won't appear here" banner when sync is silently disabled
/// — historically this only got logged in DEBUG, so a user on a
/// new iPhone install would see an empty library and no
/// explanation. Written exactly once during launch by
/// `ceciliasNotesContainer()`.
enum CloudKitContainerStatus: String {
    case uninitialized
    case privateDatabase
    case localOnlyFallback
}

enum CloudKitContainerState {
    /// The view layer reads this directly. `nonisolated(unsafe)`
    /// because writes only happen during launch (before any view
    /// can observe) and reads on the main actor afterwards.
    nonisolated(unsafe) static var status: CloudKitContainerStatus = .uninitialized
}

extension ModelContainer {

    /// Production container backed by `ceciliasnotes.sqlite` in
    /// Application Support/CeciliasNotes/.
    ///
    /// CloudKit private database — schema audited for compatibility
    /// in Prompt 7 (every non-optional property has an inline
    /// default, every parent-child relationship has a matching
    /// `inverse:`). Conflict resolution is CloudKit's native
    /// last-write-wins; no custom merge logic.
    ///
    /// **Graceful fallback to local-only.** If the CloudKit
    /// container fails to register at runtime — entitlements
    /// missing, wrong container ID, user not signed into iCloud,
    /// device offline during first launch with sync enabled — we
    /// re-init the container with `cloudKitDatabase: .none` so the
    /// app never crashes at launch. The error is logged to the
    /// console only; the user just sees a non-syncing app and
    /// Settings → iCloud surfaces "sign in to iCloud to sync your
    /// notes" via `CloudSyncManager`.
    /// UserDefaults key for the user-controllable "disable SwiftData
    /// CloudKit sync" escape hatch. Toggled from Settings → iCloud
    /// → "Disable SwiftData CloudKit sync". When set, the container
    /// is initialised with `cloudKitDatabase: .none` regardless of
    /// the user's iCloud account state, sidestepping the chronic
    /// CloudKit-stuck-export scenario that pins the SwiftData
    /// metadata lock for the full sync round and freezes every
    /// mainContext read on the main runloop.
    ///
    /// Use case: a user whose CloudKit container has entered a
    /// stuck-export loop (same `com.apple.coredata.cloudkit.activity.export.<UUID>`
    /// retrying for days). Disabling the SwiftData CloudKit sync
    /// stops fighting that loop; their on-device data remains in
    /// the same `ceciliasnotes.sqlite` and survives the toggle.
    /// File-asset iCloud sync (media/audio via the ubiquity
    /// container) is unaffected — that's managed by
    /// `CloudSyncManager`.
    static let swiftDataCloudKitDisabledKey = "ceciliasnotes.swiftdata.cloudkitDisabled"

    static func ceciliasNotesContainer() throws -> ModelContainer {
        let storeURL = StorageService.ceciliasNotesDirectoryURL
            .appendingPathComponent("ceciliasnotes.sqlite")
        try FileManager.default.createDirectory(
            at: StorageService.ceciliasNotesDirectoryURL,
            withIntermediateDirectories: true
        )

        // V6 = the active schema. Step 1 of the unified PageElement
        // migration: adds `PageElement` and 7 polymorphic content
        // entities alongside the existing V5 entities. The V5
        // entities stay in the V6 model list so the existing
        // rendering paths keep working through Steps 2-9. The V5
        // SwiftData store is wiped on first launch under V6 by the
        // `runV6WipeIfNeeded` gate in `CeciliasNotesAppDelegate` —
        // no migration plan, single-tester start-clean. See
        // `CeciliasNotesSchemas.swift` for the duplicate-checksum
        // trap that forces single-version operation.
        let schema = Schema(versionedSchema: CeciliasNotesSchemaV6.self)

        // Escape hatch 1: user-set preference. A chronic stuck
        // CloudKit export loop is an iOS-side bug we can't recover
        // from on our own, but the user can route around it by
        // turning the database sync off from Settings → iCloud.
        let disabledByUser = UserDefaults.standard.bool(
            forKey: swiftDataCloudKitDisabledKey
        )

        // Escape hatch 2: dirty-launch auto-fallback. If the
        // previous shutdown was abnormal (force-quit, watchdog kill,
        // crash) AND it had happened TWICE in a row, the most likely
        // cause is the launch itself wedging on a stuck CloudKit
        // sync. Open the container without CloudKit so the user can
        // at least reach the editor + Settings to toggle the
        // preference durably. A single dirty launch isn't enough —
        // a one-off force-quit during normal use shouldn't downgrade
        // sync. Two in a row means the recovery path is needed.
        let dirtyCountKey = "ceciliasnotes.swiftdata.dirtyLaunchStreak"
        let dirtyStreak = UserDefaults.standard.integer(forKey: dirtyCountKey)
        let autoFallback = dirtyStreak >= 2
        // Bump the streak now — when launch completes cleanly the
        // app delegate clears it back to 0 (see CeciliasNotesAppDelegate).
        UserDefaults.standard.set(dirtyStreak + 1, forKey: dirtyCountKey)

        if disabledByUser || autoFallback {
            #if DEBUG
            if disabledByUser {
                dlog("[ModelContainer] SwiftData CloudKit sync DISABLED by user preference — opening with cloudKitDatabase: .none")
            } else {
                dlog("[ModelContainer] SwiftData CloudKit sync auto-disabled after \(dirtyStreak) consecutive dirty launches — opening with cloudKitDatabase: .none")
            }
            #endif
            CloudKitContainerState.status = .localOnlyFallback
            let localConfig = ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            return try ModelContainer(
                for: schema,
                configurations: localConfig
            )
        }

        // First attempt: CloudKit private database. The container
        // identifier matches the iCloud capability provisioned in
        // the app's entitlements.
        let cloudConfig = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .private("iCloud.app.ceciliasnotes")
        )
        do {
            let container = try ModelContainer(
                for: schema,
                configurations: cloudConfig
            )
            #if DEBUG
            // Diagnostic 4 — confirm the production container
            // actually came up on the CloudKit path (not silently
            // demoted to local-only by the catch branch below). The
            // CKContainer account-status check runs async; logs the
            // user's iCloud sign-in state so we know whether sync
            // even has the prerequisites to fire.
            dlog("[CloudKit] container initialised on private database (iCloud.app.ceciliasnotes)")
            CKContainer(identifier: "iCloud.app.ceciliasnotes").accountStatus { status, err in
                let label: String
                switch status {
                case .available:           label = "available"
                case .noAccount:           label = "noAccount (user not signed in)"
                case .restricted:          label = "restricted"
                case .couldNotDetermine:   label = "couldNotDetermine"
                case .temporarilyUnavailable: label = "temporarilyUnavailable"
                @unknown default:          label = "unknown(\(status.rawValue))"
                }
                dlog("[CloudKit] account status: \(label) err=\(err?.localizedDescription ?? "nil")")
            }
            #endif
            CloudKitContainerState.status = .privateDatabase
            return container
        } catch {
            // Local-only fallback. The Library reads
            // `CloudKitContainerState.status` and surfaces a
            // user-visible banner so a fresh iPhone install
            // missing iCloud sign-in / CloudKit entitlements
            // doesn't look like "the app has no data" — it
            // explains why other devices' notes aren't showing.
            CloudKitContainerState.status = .localOnlyFallback
            #if DEBUG
            dlog("[ModelContainer] CloudKit init failed, falling back to local: \(error)")
            dlog("[CloudKit] *** SYNC DISABLED *** container ran on local-only path; verify (1) iCloud + CloudKit capabilities in app target, (2) iCloud container 'iCloud.app.ceciliasnotes' exists in Apple Dev portal, (3) user signed into iCloud on device, (4) Cecilia's Notes toggle ON in Settings → Apple ID → iCloud")
            #endif
            let localConfig = ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: localConfig
                )
            } catch {
                // Both CloudKit and local opens failed. The
                // overwhelmingly likely cause on a development
                // device is a schema mismatch — the on-disk store
                // was created against an older Swift model layout
                // (this project added bidirectional relationships
                // + optional to-many during the CloudKit-compat
                // rewrite). This is a fresh-start project with no
                // migration plan, so we delete the store and
                // retry. Any genuine corruption is also recovered
                // by this path — the user gets a clean start.
                #if DEBUG
                dlog("[ModelContainer] Local init failed (schema mismatch?), wiping store and retrying: \(error)")
                #endif
                try? FileManager.default.removeItem(at: storeURL)
                // SQLite ships with sidecar journal/WAL files that
                // can also be wedged if the main file is gone but
                // they aren't — sweep them too so the next open
                // sees a pristine directory.
                for suffix in ["-shm", "-wal", "-journal"] {
                    try? FileManager.default.removeItem(
                        at: storeURL.appendingPathExtension(String(suffix.dropFirst()))
                    )
                }
                return try ModelContainer(
                    for: schema,
                    configurations: localConfig
                )
            }
        }
    }

    /// In-memory container for unit tests — no disk I/O, no CloudKit.
    /// Tracks whichever schema version the production container is
    /// on so test fixtures stay in sync.
    static func ceciliasNotesTestContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CeciliasNotesSchemaV6.self)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }
}
