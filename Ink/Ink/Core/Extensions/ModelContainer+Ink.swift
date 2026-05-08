import Foundation
import SwiftData

extension ModelContainer {

    // Bump this integer whenever the SwiftData schema changes in a way that
    // is incompatible with existing on-disk stores (added non-optional columns,
    // renamed properties, changed enum encoding, etc.). The first launch after
    // a bump will delete the old SQLite files so SwiftData can build a fresh
    // store — acceptable during development; production apps should use a
    // proper VersionedSchema + MigrationPlan instead.
    private static let currentSchemaVersion = 2
    private static let schemaVersionKey     = "ink.schema.version"

    /// Production container backed by ink.sqlite in Application Support/Ink/.
    static func inkContainer() throws -> ModelContainer {
        let schema = Schema([
            Subject.self,
            Notebook.self,
            Page.self,
            TextBlock.self,
            MediaAttachment.self,
            AudioAnnotation.self,
        ])
        let storeURL = StorageService.inkDirectoryURL
            .appendingPathComponent("ink.sqlite")
        try FileManager.default.createDirectory(
            at: StorageService.inkDirectoryURL,
            withIntermediateDirectories: true
        )

        // Delete the store when the schema version changes so SwiftData
        // never reads rows that are missing non-optional columns.
        let storedVersion = UserDefaults.standard.integer(forKey: schemaVersionKey)
        if storedVersion != currentSchemaVersion {
            for ext in ["sqlite", "sqlite-shm", "sqlite-wal"] {
                try? FileManager.default.removeItem(
                    at: storeURL.deletingPathExtension().appendingPathExtension(ext)
                )
            }
            UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
        }

        // cloudKitDatabase: .none — without this, SwiftData defaults to
        // `.automatic` and auto-enables CloudKit Database sync because the
        // app's entitlements declare an iCloud container. CloudKit then
        // validates the schema against its strict rules (all relationships
        // must have inverses + be optional, every attribute must be optional
        // or have a default) and refuses to load the store on launch.
        //
        // Ink does NOT use CloudKit Database — its iCloud sync uses
        // CloudDocuments (iCloud Drive file presence) via CloudSyncManager +
        // NSFileCoordinator. SwiftData stays local-only.
        let config = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    /// In-memory container for unit tests — no disk I/O.
    static func inkTestContainer() throws -> ModelContainer {
        let schema = Schema([
            Subject.self,
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
