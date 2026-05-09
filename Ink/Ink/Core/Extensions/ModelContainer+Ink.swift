import Foundation
import SwiftData

extension ModelContainer {

    /// Production container backed by ink.sqlite in Application Support/Ink/.
    ///
    /// Schema migration: production-grade. `InkMigrationPlan` declares the
    /// transition V2 → V3 (adds `Folder`, adds `Notebook.folderId`) as a
    /// lightweight migration. SwiftData reads the on-disk schema, diffs it
    /// against the current schema (V3), and applies `ALTER TABLE` for
    /// additive changes — existing notebooks come back with `folderId = nil`
    /// (i.e., directly under their subject), no data loss.
    ///
    /// CloudKit is explicitly disabled: Ink's iCloud sync uses CloudDocuments
    /// (iCloud Drive file presence) via `CloudSyncManager`, not CloudKit
    /// Database. Without `cloudKitDatabase: .none`, SwiftData would auto-mirror
    /// the store to CloudKit and reject the load because `Folder.parentSubjectId`
    /// (non-optional) violates CloudKit's "all attributes must be optional or
    /// have a default" rule.
    static func inkContainer() throws -> ModelContainer {
        let storeURL = StorageService.inkDirectoryURL
            .appendingPathComponent("ink.sqlite")
        try FileManager.default.createDirectory(
            at: StorageService.inkDirectoryURL,
            withIntermediateDirectories: true
        )

        // Use the V3 schema (current). The migration plan handles arrivals
        // from V2.
        let schema = Schema(versionedSchema: InkSchemaV3.self)
        let config = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        return try ModelContainer(
            for: schema,
            migrationPlan: InkMigrationPlan.self,
            configurations: config
        )
    }

    /// In-memory container for unit tests — no disk I/O.
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
