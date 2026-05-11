/// MediaAttachmentStore.swift
/// Cecilia's Notes
///
/// Side-channel store for image attachments. Mirrors
/// `StickyNoteStore` and `PDFTextAnnotationStore`:
/// `UserDefaults.standard`, JSON-encoded dictionary keyed by
/// `pageId.uuidString`, soft-delete via `deletedAt`, hard-delete
/// via `forget(pageIds:)` from the reaper. Image bytes live as
/// files on disk; the record only carries metadata.
///
/// Why a side-channel rather than SwiftData: image pixels are
/// large, position/size mutates often during gestures, and adding
/// a new SwiftData entity type forces a schema version bump with
/// structurally-distinct Swift types. See `InkSchemas.swift` and
/// `ARCHITECTURE.md`.

import Foundation
import UIKit

enum MediaAttachmentStore {

    private static let storageKey = "media.attachments.v1"

    // MARK: - Filesystem helpers

    /// Per-notebook media directory: `Documents/media/<uuid>/`.
    /// Mirrors the audio + PDF file layout so a notebook's assets
    /// stay grouped under a single subdirectory the reaper can
    /// sweep wholesale.
    static func mediaDirectory(for notebookId: UUID) -> URL {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(notebookId.uuidString, isDirectory: true)
    }

    /// Resolve a record's `relativeFilePath` against `Documents/`.
    /// Returns the absolute URL — `nil` only if Documents itself is
    /// unreachable, which shouldn't happen.
    static func absoluteURL(for record: MediaAttachmentRecord) -> URL {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(record.relativeFilePath)
    }

    // MARK: - Read

    /// Active records for a page, ordered by `createdAt`. Used by
    /// the canvas render layer and the export pipeline.
    static func records(
        for pageId: UUID,
        defaults: UserDefaults = .standard
    ) -> [MediaAttachmentRecord] {
        readMap(defaults: defaults)[pageId.uuidString]?
            .filter { $0.deletedAt == nil }
            .sorted { $0.createdAt < $1.createdAt } ?? []
    }

    /// Every active record. Used by debug tooling — not part of any
    /// hot path.
    static func allActiveRecords(
        defaults: UserDefaults = .standard
    ) -> [MediaAttachmentRecord] {
        readMap(defaults: defaults).values.flatMap { $0 }
            .filter { $0.deletedAt == nil }
    }

    // MARK: - Mutate

    /// Insert or replace by `id`. Drag / resize / rotate all flow
    /// through here on commit. The on-disk file is NOT touched —
    /// the caller is responsible for writing pixels before saving
    /// the record, and the file path inside the record never
    /// changes after creation.
    static func save(
        _ record: MediaAttachmentRecord,
        defaults: UserDefaults = .standard
    ) {
        var map = readMap(defaults: defaults)
        var arr = map[record.pageId.uuidString] ?? []
        if let idx = arr.firstIndex(where: { $0.id == record.id }) {
            arr[idx] = record
        } else {
            arr.append(record)
        }
        map[record.pageId.uuidString] = arr
        writeMap(map, defaults: defaults)
    }

    /// Soft-delete — stamps `deletedAt`, leaves the record + the
    /// on-disk file in place so an undo path could restore the
    /// image without re-keying. The reaper hard-deletes both on
    /// notebook purge.
    static func softDelete(
        id: UUID,
        pageId: UUID,
        defaults: UserDefaults = .standard
    ) {
        var map = readMap(defaults: defaults)
        guard var arr = map[pageId.uuidString],
              let idx = arr.firstIndex(where: { $0.id == id })
        else { return }
        arr[idx].deletedAt = Date()
        arr[idx].updatedAt = Date()
        map[pageId.uuidString] = arr
        writeMap(map, defaults: defaults)
    }

    /// Hard-delete: drops every record for the given pages AND
    /// removes the underlying image files from disk. Called by
    /// `StorageService.purgeNotebookFiles` on reaper purge. Files
    /// are removed before the record reference goes away so we can
    /// still resolve the absolute path.
    static func forget(
        pageIds: [UUID],
        defaults: UserDefaults = .standard
    ) {
        guard !pageIds.isEmpty else { return }
        var map = readMap(defaults: defaults)
        let fm = FileManager.default
        for pid in pageIds {
            if let arr = map[pid.uuidString] {
                for record in arr {
                    let url = absoluteURL(for: record)
                    try? fm.removeItem(at: url)
                }
            }
            map.removeValue(forKey: pid.uuidString)
        }
        writeMap(map, defaults: defaults)
    }

    // MARK: - Internals

    private static func readMap(
        defaults: UserDefaults
    ) -> [String: [MediaAttachmentRecord]] {
        guard let raw  = defaults.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let map  = try? JSONDecoder().decode(
                  [String: [MediaAttachmentRecord]].self, from: data
              )
        else { return [:] }
        return map
    }

    private static func writeMap(
        _ map: [String: [MediaAttachmentRecord]],
        defaults: UserDefaults
    ) {
        let compact = map.filter { !$0.value.isEmpty }
        if compact.isEmpty {
            defaults.removeObject(forKey: storageKey)
            NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
            return
        }
        guard let data = try? JSONEncoder().encode(compact),
              let str  = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(str, forKey: storageKey)
        // Reactive render layer: `ImageAttachmentsView` listens for
        // this notification and refreshes without polling.
        NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
    }
}

// MARK: - Change notification

extension Notification.Name {
    /// Posted whenever `MediaAttachmentStore` mutates. Parallel to
    /// `.pdfTextAnnotationsChanged` and `.stickyNotesChanged`.
    static let mediaAttachmentsChanged = Notification.Name("mediaAttachmentsChanged")
}
