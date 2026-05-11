/// MediaAttachmentRecord.swift
/// Cecilia's Notes
///
/// Codable wire format for image attachments placed on a notebook
/// page. Sibling of `StickyNoteRecord` and
/// `PDFTextAnnotationRecord` — JSON-serialised through a
/// UserDefaults side-channel store (`MediaAttachmentStore`); the
/// actual pixels live as files on disk under
/// `Documents/media/<notebookUUID>/<attachmentUUID>.<ext>`.
///
/// The existing `MediaAttachment` SwiftData `@Model` remains in the
/// schema for CloudKit compatibility but is not used at runtime
/// for image data — this record is the source of truth.

import CoreGraphics
import Foundation

struct MediaAttachmentRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let pageId: UUID
    let notebookId: UUID

    /// File path relative to the app's `Documents/` directory.
    /// Resolved at load time so an absolute path baked at creation
    /// can't drift if the sandbox ever relocates the bundle.
    var relativeFilePath: String

    /// Position + size in normalised 0–1 top-left-origin page
    /// coordinates — same convention every other side-channel store
    /// uses, so the export path and rendering math stay consistent.
    var normalizedX:      Double
    var normalizedY:      Double
    var normalizedWidth:  Double
    var normalizedHeight: Double

    /// 0 / 90 / 180 / 270. Spec is 90° steps only — no free rotation
    /// in this pass.
    var rotationDegrees:  Double

    /// Source image pixel dimensions, captured at import. Used to
    /// preserve aspect ratio during resize when the on-page size
    /// drifts due to pinch round-off.
    var originalWidth:    Double
    var originalHeight:   Double

    let createdAt: Date
    var updatedAt: Date
    /// Soft-delete stamp. `nil` = active. Mirrors every other model.
    var deletedAt: Date?
}
