import Foundation
import SwiftData

@Model
final class AudioAnnotation {
    // MARK: Identity
    var id: UUID

    // MARK: Data
    var pageId: UUID {
        willSet { updatedAt = Date() }
    }
    /// Denormalised from page.notebookId — required for building audio file URLs.
    var notebookId: UUID {
        willSet { updatedAt = Date() }
    }
    var fileName: String {
        willSet { updatedAt = Date() }
    }
    var durationSeconds: Double {
        willSet { updatedAt = Date() }
    }
    var fileSizeBytes: Int64 {
        willSet { updatedAt = Date() }
    }
    /// Plain-text transcription from on-device speech recognition.
    var transcription: String? {
        willSet { updatedAt = Date() }
    }
    /// Archived [TranscriptionSegment] for word-level highlighting.
    var transcriptionSegments: Data? {
        willSet { updatedAt = Date() }
    }
    /// True once updateTranscription has been called with a successful result.
    var isTranscribed: Bool {
        willSet { updatedAt = Date() }
    }
    /// Archived [Float] RMS amplitudes, one per 50ms window. Used to render static waveform.
    var amplitudeData: Data? {
        willSet { updatedAt = Date() }
    }

    // MARK: Pin position — normalised 0.0–1.0 in page coordinate space
    var pageX: Double {
        willSet { updatedAt = Date() }
    }
    var pageY: Double {
        willSet { updatedAt = Date() }
    }

    // MARK: Timestamps
    var recordedAt: Date
    var createdAt: Date
    var updatedAt: Date

    // MARK: Soft delete
    var isDeleted: Bool {
        willSet { updatedAt = Date() }
    }
    var deletedAt: Date?

    // MARK: Init
    init(
        id: UUID = UUID(),
        pageId: UUID,
        notebookId: UUID,
        fileName: String,
        durationSeconds: Double,
        fileSizeBytes: Int64 = 0,
        pageX: Double,
        pageY: Double
    ) {
        self.id                     = id
        self.pageId                 = pageId
        self.notebookId             = notebookId
        self.fileName               = fileName
        self.durationSeconds        = durationSeconds
        self.fileSizeBytes          = fileSizeBytes
        self.transcription          = nil
        self.transcriptionSegments  = nil
        self.isTranscribed          = false
        self.amplitudeData          = nil
        self.pageX                  = pageX
        self.pageY                  = pageY
        self.recordedAt             = Date()
        self.createdAt              = Date()
        self.updatedAt              = Date()
        self.isDeleted              = false
        self.deletedAt              = nil
    }
}
