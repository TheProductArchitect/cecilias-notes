import Foundation
import SwiftData

/// Full-fidelity, self-contained notebook archive — the `.ceciliabook`
/// format. Unlike `.inkbook` (text-only, agent-authored mirror), this
/// carries EVERY V6 element (text with rich formatting, images, audio,
/// Pencil ink, sticky notes, shapes, highlights, PDF pages) plus the
/// media bytes, so a notebook can be exported to a file, shared (Drive,
/// AirDrop, multipeer), and re-opened in Cecilia's Notes on another
/// device as an editable copy.
///
/// One self-contained JSON file (media base64-embedded) so tapping it
/// opens the app and imports cleanly — no bundle/zip unpacking needed.
///
/// Back/forward compatible: every content field is optional and the
/// importer skips unknown element kinds, so an older build opening a
/// newer file drops only what it can't represent.
nonisolated struct NotebookArchive: Codable {
    static let formatIdentifier = "ceciliabook"
    static let currentVersion = 1
    static let fileExtension = "ceciliabook"

    var format: String = NotebookArchive.formatIdentifier
    var formatVersion: Int = NotebookArchive.currentVersion
    var exportedAt: String
    var notebook: ArchiveNotebook
    var pages: [ArchivePage]
    /// content-id → base64 bytes for image / audio blobs.
    var media: [String: String]?
    /// pdfDocumentId → base64 bytes for embedded source PDFs.
    var pdfDocuments: [String: String]?

    struct ArchiveNotebook: Codable {
        var title: String
        var subjectName: String?
        var coverColorHex: String
        var coverTexture: String
        var pageSize: String
        var defaultTemplate: String
    }

    struct ArchivePage: Codable {
        var index: Int
        var pageSize: String
        var backgroundTemplate: String
        var elements: [ArchiveElement]
    }

    struct ArchiveElement: Codable {
        var kind: String
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var rotation: Double
        var zIndex: Int
        var opacity: Double
        var isLocked: Bool

        var text: ArchiveText?
        var image: ArchiveImage?
        var audio: ArchiveAudio?
        var stroke: ArchiveStroke?
        var sticky: ArchiveSticky?
        var shape: ArchiveShape?
        var highlight: ArchiveHighlight?
        var pdfPage: ArchivePDFPage?
    }

    struct ArchiveText: Codable {
        var text: String
        var source: String
        var size: String
        /// base64 of the archived NSAttributedString (rich formatting).
        var attributedTextData: String?
    }

    struct ArchiveImage: Codable {
        /// key into `media`.
        var contentId: String
        var fileFormat: String
        var originalPixelWidth: Int
        var originalPixelHeight: Int
        var cropOriginX: Double?
        var cropOriginY: Double?
        var cropWidth: Double?
        var cropHeight: Double?
    }

    struct ArchiveAudio: Codable {
        /// key into `media`.
        var contentId: String
        var durationSeconds: Double
        var transcript: String
        /// base64 of the timing map, when present.
        var timingMapData: String?
    }

    struct ArchiveStroke: Codable {
        /// base64 of the PKDrawing data.
        var strokeData: String
        var toolKind: String
        var colorHex: String
        var widthBase: Double
        var opacity: Double
    }

    struct ArchiveSticky: Codable {
        var text: String
        var colorVariant: String
    }

    struct ArchiveShape: Codable {
        var shapeKind: String
        var strokeColorHex: String
        var strokeWidth: Double
        var strokeStyle: String
        var fillColorHex: String?
        var fillOpacity: Double
        var containedText: String?
        var containedTextStyle: String?
    }

    struct ArchiveHighlight: Codable {
        /// Stable key linking to the owning pdfPage element within this
        /// archive (remapped on import).
        var pdfPageRef: String
        var rectOriginX: Double
        var rectOriginY: Double
        var rectWidth: Double
        var rectHeight: Double
        var style: String
        var colorVariant: String
        var capturedText: String?
    }

    struct ArchivePDFPage: Codable {
        /// key into `pdfDocuments` (many pages share one document).
        var pdfDocumentId: String
        var pageIndex: Int
        var originalPageWidth: Double
        var originalPageHeight: Double
        var extractedText: String?
        /// Stable per-content key so highlights can reference it.
        var contentRef: String
    }
}
