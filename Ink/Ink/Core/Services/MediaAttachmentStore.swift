/// MediaAttachmentStore.swift
/// Cecilia's Notes
///
/// Phase 5A+5C Step 4: static façade over the `ImageRecord`
/// SwiftData entity. This used to be a UserDefaults JSON store
/// with a sibling `struct MediaAttachmentRecord`; the struct moved
/// to `@Model class ImageRecord` (see `Core/Models/ImageRecord.swift`)
/// and the static API here now reads/writes through SwiftData via
/// `StorageService.shared.context`.
///
/// The façade survives the rewrite because every caller in the
/// editor — `ImageAttachmentsView`, `MediaInsertCoordinator`,
/// `ExportService`, `EditorViewModel.commitImportedImage` — already
/// expects this enum-shaped API. Routing through it keeps the
/// migration to one place and isolates SwiftData-context plumbing
/// from the call sites.
///
/// `.mediaAttachmentsChanged` is still posted from `save(_:)` /
/// `softDelete(_:_:)` so `ImageAttachmentsView` re-renders on any
/// external mutation without caller-side changes.

import Foundation
import SwiftData
import UIKit

enum MediaAttachmentStore {

    // MARK: - Filesystem helpers

    /// Per-notebook media directory: `Documents/media/<uuid>/`.
    /// Image bytes that pre-date Step 4 still live here; new image
    /// inserts go through `MediaStorage.url(for: .images, id:)` (the
    /// unified `Documents/MediaAttachments/images/` tree). The
    /// reaper sweeps both paths.
    static func mediaDirectory(for notebookId: UUID) -> URL {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(notebookId.uuidString, isDirectory: true)
    }

    /// Resolve the on-disk URL for a record's image bytes.
    /// `MediaStorage` owns the canonical path under
    /// `Documents/MediaAttachments/images/<uuid>.jpg`.
    static func absoluteURL(for record: ImageRecord) -> URL {
        MediaStorage.url(for: .images, id: record.id)
    }

    // MARK: - Read

    /// Active records for a page, ordered by `createdAt`. Used by
    /// the canvas render layer and the export pipeline.
    static func records(for pageId: UUID) -> [ImageRecord] {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<ImageRecord>(
            predicate: #Predicate { $0.pageId == pageId && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Every active record across every page. Debug tooling only —
    /// not part of any hot path.
    static func allActiveRecords() -> [ImageRecord] {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<ImageRecord>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Mutate

    /// Insert or update a record. Drag / resize / rotate all flow
    /// through here on commit. The on-disk file is NOT touched —
    /// the caller is responsible for writing pixels before saving.
    static func save(_ record: ImageRecord) {
        let context = StorageService.shared.context
        if record.modelContext == nil {
            context.insert(record)
        }
        record.updatedAt = Date()
        try? context.save()
        NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
    }

    /// Soft-delete — stamps `deletedAt`. The on-disk file stays in
    /// place so an undo could restore the image without re-keying.
    /// The reaper hard-deletes both on notebook purge.
    static func softDelete(id: UUID, pageId: UUID) {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<ImageRecord>(
            predicate: #Predicate { $0.id == id && $0.pageId == pageId }
        )
        guard let record = try? context.fetch(descriptor).first else { return }
        record.deletedAt = Date()
        record.updatedAt = Date()
        try? context.save()
        NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
    }

    /// Hard-delete every record for the given pages AND remove the
    /// underlying image files from disk. Called by
    /// `StorageService.purgeNotebookFiles` on reaper purge. Files
    /// are removed before the record is deleted so we can still
    /// resolve their absolute paths.
    static func forget(pageIds: [UUID]) {
        guard !pageIds.isEmpty else { return }
        let context = StorageService.shared.context
        let pageIdSet = Set(pageIds)
        let descriptor = FetchDescriptor<ImageRecord>(
            predicate: #Predicate { pageIdSet.contains($0.pageId) }
        )
        let fm = FileManager.default
        let records = (try? context.fetch(descriptor)) ?? []
        for record in records {
            try? fm.removeItem(at: absoluteURL(for: record))
            context.delete(record)
        }
        try? context.save()
        NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
    }
}

// MARK: - Change notification

extension Notification.Name {
    /// Posted whenever `MediaAttachmentStore` mutates. Parallel to
    /// `.pdfTextAnnotationsChanged` and `.stickyNotesChanged`.
    static let mediaAttachmentsChanged = Notification.Name("mediaAttachmentsChanged")
}
