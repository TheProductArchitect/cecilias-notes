import Foundation
import SwiftData

extension ModelContainer {

    /// Production container backed by `ink.sqlite` in
    /// Application Support/Ink/.
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
    static func inkContainer() throws -> ModelContainer {
        let storeURL = StorageService.inkDirectoryURL
            .appendingPathComponent("ink.sqlite")
        try FileManager.default.createDirectory(
            at: StorageService.inkDirectoryURL,
            withIntermediateDirectories: true
        )

        // V4 = the CloudKit-compatible schema. Prompt 7 was an
        // explicit fresh start with no backward-compatibility
        // requirement, so there is no migration plan — see
        // `InkSchemas.swift` for the duplicate-checksum trap that
        // forced the collapse to a single version.
        let schema = Schema(versionedSchema: InkSchemaV4.self)

        // First attempt: CloudKit private database. The container
        // identifier matches the iCloud capability provisioned in
        // the app's entitlements.
        let cloudConfig = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .private("iCloud.com.wave.venu.Ink")
        )
        do {
            return try ModelContainer(
                for: schema,
                configurations: cloudConfig
            )
        } catch {
            // Local-only fallback. Logged once at launch so a
            // missing-entitlements regression is visible during
            // development; no user-facing error surface.
            #if DEBUG
            print("[ModelContainer] CloudKit init failed, falling back to local: \(error)")
            #endif
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
    }

    /// In-memory container for unit tests — no disk I/O, no CloudKit.
    static func inkTestContainer() throws -> ModelContainer {
        let schema = Schema([
            Subject.self,
            Folder.self,
            Notebook.self,
            Page.self,
            TextBlock.self,
            MediaAttachment.self,
            AudioAnnotation.self,
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }
}
