import CloudKit
import Foundation
import SwiftData

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
            return container
        } catch {
            // Local-only fallback. Logged once at launch so a
            // missing-entitlements regression is visible during
            // development; no user-facing error surface.
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
