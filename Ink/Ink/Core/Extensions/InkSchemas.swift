import Foundation
import SwiftData

// MARK: - Schema
//
// Single canonical schema. The earlier multi-version setup (V2/V3/V4)
// caused SwiftData's `Duplicate version checksums detected` crash —
// every version referenced the same Swift model classes, so the
// derived checksums collided. Since the CloudKit-compatibility
// rewrite was an explicit fresh start with no backward-compatibility
// requirement, this file collapses to a single version and the
// migration plan is gone.
//
// If the schema ever needs to evolve again, the documented escape
// hatch in SwiftData is to give each version *structurally distinct*
// model types (per-version namespace, renamed class) so the
// checksums diverge. Don't try to keep two versions of the same
// type — it will crash.

enum InkSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
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
