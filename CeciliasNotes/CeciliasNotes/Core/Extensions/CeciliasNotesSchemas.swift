import Foundation
import SwiftData

// MARK: - Schema
//
// Single active versioned schema at a time. Earlier multi-version
// setups (V2/V3/V4) crashed with `Duplicate version checksums
// detected` because every version referenced the same Swift model
// classes — the derived checksums collided. The version identifier
// bumps each time the schema evolves, and the container's local
// fallback wipes the store on schema mismatch
// (`ModelContainer.ceciliasNotesContainer()`).
//
// If the schema ever needs *online* migration, the documented
// escape hatch in SwiftData is to give each version *structurally
// distinct* model types (per-version namespace, renamed class) so
// the checksums diverge. Don't try to keep two versions of the
// same type — it will crash.
//
// V5 (Phase 5A+5C Step 2 — lectures): added `LectureRecord` as a
// SwiftData entity. Kept here as a historical reference; V6 is the
// active container schema once the unification migration starts.
//
// V6 (architectural unification, Step 1 of the unified
// PageElement migration): adds `PageElement` plus the 7
// polymorphic content entities (`StrokeContent`, `ImageContent`,
// `AudioContent`, `TextContent`, `StickyNoteContent`,
// `PDFPageContent`, `ShapeContent`) alongside the existing V5
// entities. The legacy V5 entities (`TextBlock`, `ImageRecord`,
// `AudioRecord`, `LectureRecord`) remain in the V6 model list so
// existing rendering keeps working while Steps 2-9 migrate each
// primitive onto `PageElement` in sequence.

enum CeciliasNotesSchemaV5: VersionedSchema {
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

enum CeciliasNotesSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            // V5 entities kept so existing rendering keeps working
            // through Steps 2-9 of the migration.
            Subject.self,
            Folder.self,
            Notebook.self,
            Page.self,
            TextBlock.self,
            AudioRecord.self,
            LectureRecord.self,
            ImageRecord.self,
            // V6 unified element model — inert in Step 1. No view
            // code reads or writes these yet; Steps 2-9 migrate the
            // per-primitive stores onto `PageElement` one at a time.
            PageElement.self,
            StrokeContent.self,
            ImageContent.self,
            AudioContent.self,
            TextContent.self,
            StickyNoteContent.self,
            PDFPageContent.self,
            ShapeContent.self,
        ]
    }
}
