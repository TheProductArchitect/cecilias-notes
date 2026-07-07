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

    /// Encoded audio bytes — canonical source for sync and AI.
    /// `@Attribute(.externalStorage)` keeps the bytes outside the
    /// SQLite row and lets CloudKit promote them to a CKAsset
    /// automatically, so a recording made on one device is
    /// reachable on every signed-in device. The local file path is
    /// still maintained as a playback cache (AVPlayer wants a
    /// URL); when the column is populated but the file is missing
    /// — e.g. on a freshly-synced second device — the audio
    /// loader materialises the file from the column on first
    /// playback. See [[image-data-design]] for the parallel
    /// `ImageContent.imageData` field.
    @Attribute(.externalStorage)
    var audioData: Data? = nil

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
        audioData: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id              = id
        self.filename        = filename
        self.durationSeconds = durationSeconds
        self.transcript      = transcript
        self.timingMapData   = timingMapData
        self.audioData       = audioData
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

    /// Returns the local file URL, materialising the file from
    /// `audioData` on demand if the file is missing. Use this when
    /// a URL is required (AVPlayer / share / export) — it covers
    /// the cross-device case where the SwiftData row arrived via
    /// CloudKit but the local cache is empty. Returns `nil` only
    /// when both the file *and* the data column are missing
    /// (legacy row that hasn't been backfilled yet and whose file
    /// didn't survive — the caller surfaces a placeholder).
    func resolvedFileURL() -> URL? {
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let lectureURL = MediaStorage.url(for: .lectures, id: id)
        if FileManager.default.fileExists(atPath: lectureURL.path) { return lectureURL }
        guard let data = audioData, !data.isEmpty else { return nil }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Decoded `TimingMap` from `timingMapData`, or nil if the field
    /// is empty (recordings made before this feature shipped, or if
    /// recognition produced no segments). Read/write round-trips
    /// through JSON so the stored bytes stay schema-version-stable.
    @MainActor var timingMap: TimingMap? {
        get {
            guard let data = timingMapData else { return nil }
            return try? JSONDecoder().decode(TimingMap.self, from: data)
        }
        set {
            timingMapData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }
}
