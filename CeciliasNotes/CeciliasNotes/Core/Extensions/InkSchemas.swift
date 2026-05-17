import Foundation
import SwiftData

// MARK: - Schema
//
// Single canonical schema. Earlier multi-version setups (V2/V3/V4)
// crashed with `Duplicate version checksums detected` because every
// version referenced the same Swift model classes — the derived
// checksums collided. This file collapses to a single active
// version. Since the CloudKit-compatibility rewrite was an explicit
// fresh start with no backward-compatibility requirement, we just
// bump the version identifier each time the schema evolves; no
// migration plan is required because the container's local
// fallback wipes the store on schema mismatch
// (`ModelContainer.inkContainer()`).
//
// If the schema ever needs *online* migration, the documented
// escape hatch in SwiftData is to give each version *structurally
// distinct* model types (per-version namespace, renamed class) so
// the checksums diverge. Don't try to keep two versions of the
// same type — it will crash.
//
// V5 (Phase 5A+5C Step 2 — lectures): adds `LectureRecord` as a
// SwiftData entity. The corresponding UserDefaults JSON store
// (`lecture.store.v1`) is wiped on first launch under V5 by the
// gate in `CeciliasNotesAppDelegate`.

enum InkSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            Subject.self,
            Folder.self,
            Notebook.self,
            Page.self,
            TextBlock.self,
            AudioRecord.self,
            LectureRecord.self,
            ImageRecord.self,
        ]
    }
}
