import Foundation
import SwiftData

/// Audio content for a `PageElement` of kind `.audio`. The recorded
/// bytes live in `MediaStorage` at
/// `Documents/MediaAttachments/audio/<id>.m4a`.
///
/// V6 (Step 5): live. `AudioElementsOverlayView` renders one of
/// these per `PageElement(kind: .audio)` as a compact play-pause-
/// time-progress strip; legacy `AudioRecord` and `LectureRecord`
/// entities were removed in the same commit (consolidate
/// decision per architecture §5/§9 — short notes and long-form
/// recordings are the same operation conceptually). The full
/// paired-block dictation UX (live transcript on page above the
/// strip) lands in Step 6.
///
/// **Pairing semantics** (architecture doc §9):
///   • `anchorText` points at the FIRST `TextContent` span of the
///     transcript. The inverse on `TextContent.audioRecordings`
///     completes the bidirectional link.
///   • For multi-page recordings, subsequent transcript spans on
///     later pages reference this audio via
///     `TextContent.anchorAudioId: UUID?` — a one-directional
///     denormalised pointer so continuation spans can resolve their
///     audio without forcing a many-to-one relationship in the
///     schema.
@Model
final class AudioContent {

    var id: UUID = UUID()
    @Relationship var element: PageElement?

    /// Filename inside `MediaStorage/audio/`, e.g. `<id>.m4a`.
    var filename: String        = ""
    var durationSeconds: Double = 0

    /// Cached full transcript. Lives here in addition to the
    /// per-page `TextContent` rows so audio whose transcript failed
    /// (or which the user deleted) still carries the original
    /// transcription for AI / search.
    var transcript: String = ""

    /// First `TextContent` span of the transcript. Inverse:
    /// `TextContent.audioRecordings`. Nil while recording is
    /// in-flight before the first text span has been created.
    @Relationship var anchorText: TextContent?

    /// JSON-encoded `[(textOffset: Int, audioSeconds: Double)]`
    /// captured during recognition. Enables word-level audio
    /// scrubbing as a post-1.0 feature without re-architecting.
    /// Stored as `Data` so SwiftData's column type stays simple
    /// across schema versions.
    var timingMapData: Data? = nil

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        filename: String = "",
        durationSeconds: Double = 0,
        transcript: String = "",
        timingMapData: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id              = id
        self.filename        = filename
        self.durationSeconds = durationSeconds
        self.transcript      = transcript
        self.timingMapData   = timingMapData
        self.createdAt       = createdAt
        self.updatedAt       = updatedAt
    }

    // MARK: - Convenience

    /// On-disk URL for the audio bytes. Mirrors the convention
    /// `ImageContent.fileURL` established in Step 4 — `id` is the
    /// filename stem; extension is always `m4a` (AVAudioFile writes
    /// AAC/M4A in `AudioRecorder`).
    var fileURL: URL {
        MediaStorage.url(for: .audio, id: id)
    }
}
