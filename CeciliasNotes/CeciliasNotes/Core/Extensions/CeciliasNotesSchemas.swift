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
        // Historical V5 reference. Several V5 entities have been
        // deleted from the codebase as later steps shipped:
        //   • `ImageRecord` (Step 4 — image migration)
        //   • `AudioRecord` + `LectureRecord` (Step 5 — audio
        //     consolidation)
        // The list below drops them because the types no longer
        // compile. Anyone needing the original V5 shape can recover
        // it from git history at the respective step commits.
        [
            Subject.self,
            Folder.self,
            Notebook.self,
            Page.self,
            TextBlock.self,
        ]
    }
}

enum CeciliasNotesSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            // V5 entities kept so existing rendering keeps working
            // through Steps 2-9 of the migration. Removed in earlier
            // step commits: `ImageRecord` (Step 4),
            // `AudioRecord` + `LectureRecord` (Step 5 — consolidated
            // into `AudioContent`).
            Subject.self,
            Folder.self,
            Notebook.self,
            Page.self,
            TextBlock.self,
            // V6 unified element model — `PageElement` plus seven
            // polymorphic content entities. Live for `.text`
            // (Step 3), `.image` (Step 4), `.pdfPage` (Step 4.5
            // Workflow B), and `.audio` (Step 5); the remaining
            // kinds (.stroke, .stickyNote, .shape) are inert until
            // Steps 7-9 migrate their respective surfaces onto
            // `PageElement`.
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
