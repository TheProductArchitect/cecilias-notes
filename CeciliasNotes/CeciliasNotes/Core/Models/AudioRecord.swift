import Foundation
import SwiftData

/// SwiftData-backed audio annotation record. Phase 5A+5C Step 3
/// (audio subsystem): replaces the legacy `AudioAnnotation` @Model
/// — type renamed, fields reshaped to match the V5 spec, and the
/// `page` relationship dropped in favour of a denormalised
/// `pageId` UUID column (consistent with `LectureRecord`).
///
/// CloudKit compatibility rules followed:
///   • Every property has an inline default.
///   • No `@Attribute(.unique)` constraint — relies on `UUID()`.
///   • No relationships — `pageId` / `notebookId` are UUID columns so
///     the V5 schema doesn't force `Page` to grow an inverse array.
///     The reaper still purges per-notebook via a `notebookId`
///     fetch.
///
/// The audio bytes live at `MediaStorage.url(for: .audio, id: id)`
/// (`Documents/MediaAttachments/audio/<uuid>.m4a`). No
/// `audioRelativePath` column — the path is fully derivable from
/// the `id`.
///
/// **Reshape from `AudioAnnotation`:**
///   • `pageX` / `pageY`            → `normalizedX` / `normalizedY`
///   • `transcription: String?`      → `transcript: String` (default "")
///   • `amplitudeData: Data?` (JSON) → `amplitudes: [Float]` (native)
///   • `recordedAt: Date`            → folded into `createdAt`
///   • Dropped: `fileName`, `fileSizeBytes`, `transcriptionSegments`,
///     `isTranscribed`, `page` relationship
@Model
final class AudioRecord {

    var id: UUID = UUID()
    var pageId: UUID = UUID()
    /// Denormalised so the reaper can sweep every audio record for a
    /// notebook without joining through `Page`.
    var notebookId: UUID = UUID()

    /// Normalised top-left-origin page coordinates of the card's
    /// pin / anchor. Phase 4B's card overlay does its own vertical
    /// stacking and ignores these; they're persisted for future
    /// per-card positioning surfaces.
    var normalizedX: Double = 0
    var normalizedY: Double = 0

    var durationSeconds: Double = 0

    /// Per-window RMS amplitudes (~300 floats per recording) for the
    /// waveform render. SwiftData stores `[Float]` natively, so the
    /// previous archived-Data round-trip is gone.
    var amplitudes: [Float] = []

    /// On-device transcript text. Empty string = no transcript yet
    /// (still recording, or recognition unavailable for the locale).
    /// The `transcript.isEmpty` check replaces the old
    /// `isTranscribed` Bool — same signal, derived not stored.
    var transcript: String = ""

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Soft-delete stamp. `nil` = active.
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        pageId: UUID,
        notebookId: UUID,
        normalizedX: Double,
        normalizedY: Double,
        durationSeconds: Double = 0,
        amplitudes: [Float] = [],
        transcript: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id              = id
        self.pageId          = pageId
        self.notebookId      = notebookId
        self.normalizedX     = normalizedX
        self.normalizedY     = normalizedY
        self.durationSeconds = durationSeconds
        self.amplitudes      = amplitudes
        self.transcript      = transcript
        self.createdAt       = createdAt
        self.updatedAt       = updatedAt
        self.deletedAt       = deletedAt
    }
}
