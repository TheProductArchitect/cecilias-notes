import Foundation
import SwiftData

// MARK: - Versioned schemas

/// V2 = the schema before `Folder` shipped. Listed here so SwiftData has a
/// "from" anchor for lightweight migration. Existing users on disk are at
/// V2; we want them to upgrade non-destructively to V3.
///
/// V2's `models` list intentionally does NOT include `Folder.self`. The
/// model types referenced (Subject, Notebook, etc.) are the same Swift
/// types as V3 — for additive lightweight migrations, SwiftData diffs the
/// ON-DISK schema against the CURRENT schema and synthesises ALTER TABLE
/// for any missing columns. New tables (Folder) are created. New optional
/// columns (Notebook.folderId) are added with NULL defaults, which is
/// exactly the semantics we want: existing notebooks get `folderId = nil`,
/// landing in their subject root.
enum InkSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            Subject.self,
            Notebook.self,
            Page.self,
            TextBlock.self,
            MediaAttachment.self,
            AudioAnnotation.self,
        ]
    }
}

/// V3 = current schema. Adds `Folder` and the `Notebook.folderId` column.
enum InkSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            Subject.self,
            Folder.self,
            Notebook.self,
            Page.self,
            TextBlock.self,
            MediaAttachment.self,
            AudioAnnotation.self,
        ]
    }
}

// MARK: - Migration plan

/// Production migration plan. V2 → V3 is lightweight (additive only).
///
/// Note: bumping past V3 with the *same* model types as V3 crashes
/// SwiftData with "Duplicate version checksums detected" because two
/// versions referencing identical model classes hash identically. A
/// future bump must either introduce new model types, change a model's
/// shape (different stored properties), OR define each version's
/// models as enum-scoped distinct types.
///
/// When a future schema bump arrives:
///   1. Add an `InkSchemaV4` enum with at least one *different* model
///      type from V3 (a renamed class or a per-version namespace).
///   2. Append `.lightweight` (or `.custom` for non-additive changes)
///      for V3 → V4.
///   3. Bump the active schema in `ModelContainer.inkContainer()`.
enum InkMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [InkSchemaV2.self, InkSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: InkSchemaV2.self, toVersion: InkSchemaV3.self),
        ]
    }
}
