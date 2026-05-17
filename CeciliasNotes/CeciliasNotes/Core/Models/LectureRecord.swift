import Foundation
import SwiftData

/// SwiftData-backed lecture record. Phase 5A+5C Step 2 (lectures
/// subsystem): replaces the legacy `struct LectureRecord` + UserDefaults
/// JSON store that lived in `LectureStore.swift`.
///
/// CloudKit compatibility rules followed (the container is configured
/// with `cloudKitDatabase: .private("iCloud.com.wave.venu.Ink")` —
/// see `ModelContainer+CeciliasNotes.swift`):
///   • Every property has an inline default. CloudKit refuses entities
///     whose required properties lack defaults — the sync schema
///     validator rejects the model at registration time otherwise.
///   • No `@Attribute(.unique)` constraint. CloudKit doesn't support
///     unique constraints; we trust `UUID()` to avoid collisions and
///     dedupe by id in code where it matters.
///   • No relationships yet — `pageId` / `notebookId` are denormalised
///     UUID columns so the V5 schema can ship without forcing
///     `Page` / `Notebook` to gain inverse arrays. That's how the
///     existing `AudioAnnotation` shapes its links too.
///
/// The audio bytes live at `MediaStorage.url(for: .lectures, id: id)`
/// (`Documents/MediaAttachments/lectures/<uuid>.m4a`). `audioRelativePath`
/// is the persisted Documents-relative path for back-compat with
/// readers that resolve via `FileManager.default.urls(for: .documentDirectory)`.
@Model
final class LectureRecord {

    var id: UUID = UUID()
    var pageId: UUID = UUID()
    /// Denormalised so the reaper can sweep every lecture for a
    /// notebook without walking pages first. Mirrors
    /// `AudioAnnotation.notebookId`.
    var notebookId: UUID = UUID()

    var title: String = ""
    var audioRelativePath: String = ""
    var transcript: String = ""
    var durationSeconds: Double = 0

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Soft-delete stamp. `nil` = active. The reaper hard-deletes on
    /// notebook purge.
    var deletedAt: Date? = nil

    // MARK: AI summary (Pass B fields, kept identical to the struct shape)
    var summary: String? = nil
    var summaryBullets: [String] = []

    /// True when both summary fields are populated. Single source of
    /// truth for the "show summary" gate in `LectureBlockView`.
    var hasSummary: Bool { summary != nil && !summaryBullets.isEmpty }

    init(
        id: UUID = UUID(),
        pageId: UUID,
        notebookId: UUID = UUID(),
        title: String = "",
        audioRelativePath: String = "",
        transcript: String = "",
        durationSeconds: Double = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id                = id
        self.pageId            = pageId
        self.notebookId        = notebookId
        self.title             = title
        self.audioRelativePath = audioRelativePath
        self.transcript        = transcript
        self.durationSeconds   = durationSeconds
        self.createdAt         = createdAt
        self.updatedAt         = updatedAt
        self.deletedAt         = deletedAt
    }
}
