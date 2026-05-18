import Foundation
import SwiftData

/// Audio content for a `PageElement` of kind `.audio`. The recorded
/// bytes live in `MediaStorage` at
/// `Documents/MediaAttachments/audio/<id>.m4a`.
///
/// V6 (Step 1): inert. The legacy `AudioRecord` (and
/// `LectureRecord`) entities still serve recording + playback until
/// Steps 5-6 migrate onto this row and build the paired-block
/// recording flow.
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
}
