import CryptoKit
import Foundation
import SwiftData
import os
import UIKit

/// Single namespace for every media-byte file the editor produces.
///
/// **One root, three subdirectories:**
/// ```
/// Documents/MediaAttachments/
///   images/<id>.jpg|png
///   audio/<id>.m4a
///   lectures/<id>.m4a
/// ```
///
/// **Why this exists**: prior to the unification, three separate code
/// paths wrote three different on-disk layouts —
/// `Documents/media/<notebookId>/...`,
/// `Documents/Notebooks/<notebookId>/audio/...`, and a stale
/// `Documents/Notebooks/<notebookId>/media/...` for an unused SwiftData
/// entity. There was no single answer to "where do I put this image?".
/// See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.B.
///
/// **Contract**:
/// - All metadata records (`PageElement(kind: .image)` +
///   `ImageContent` since Step 4; `AudioRecord`, `LectureRecord`
///   pending Step 5) keep their persisted metadata in SwiftData.
///   Only the file *bytes* live here.
/// - All writes go through `writeImage(_:id:format:)` etc, which run
///   their disk I/O off the main actor.
/// - `migrateExistingFilesIfNeeded()` runs idempotently at app launch
///   and moves bytes from the legacy directories into the unified
///   layout, updating record references in the same pass. Records whose
///   files are missing are dropped cleanly with a logged warning.
/// - `diagnostics()` returns per-category byte totals + counts. The
///   Settings → Storage section surfaces them.
enum MediaStorage {

    // MARK: - Layout

    enum Category: String, CaseIterable, Sendable {
        case images, audio, lectures

        var fileExtension: String {
            switch self {
            case .images:   return "jpg"
            case .audio:    return "m4a"
            case .lectures: return "m4a"
            }
        }
    }

    private static let logger = Logger(subsystem: "app.ink", category: "MediaStorage")
    private static let migrationFlagKey = "media.storage.migrated.v1"
    private static let rootName = "MediaAttachments"

    /// `Documents/`.
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// `Documents/MediaAttachments/`.
    static var rootURL: URL {
        documentsURL.appendingPathComponent(rootName, isDirectory: true)
    }

    /// `Documents/MediaAttachments/<category>/`.
    static func directory(for category: Category) -> URL {
        rootURL.appendingPathComponent(category.rawValue, isDirectory: true)
    }

    /// `Documents/MediaAttachments/<category>/<id>.<ext>`.
    static func url(for category: Category, id: UUID, fileExtension: String? = nil) -> URL {
        let ext = fileExtension ?? category.fileExtension
        return directory(for: category)
            .appendingPathComponent("\(id.uuidString).\(ext)")
    }

    /// Documents-relative path string used by records that store a path
    /// rather than just an id. Round-trips through `documentsURL` so a
    /// sandbox relocate can't invalidate it.
    static func relativePath(forCategory category: Category, id: UUID, fileExtension: String? = nil) -> String {
        let ext = fileExtension ?? category.fileExtension
        return "\(rootName)/\(category.rawValue)/\(id.uuidString).\(ext)"
    }

    // MARK: - Directory bring-up

    /// Idempotent. Creates the root + every category directory if any
    /// is missing. Safe to call repeatedly. Also brings up the
    /// PDF directories Step 4.5 added so the dedup index has a
    /// place to land.
    static func ensureDirectoriesExist() {
        let fm = FileManager.default
        for category in Category.allCases {
            try? fm.createDirectory(at: directory(for: category),
                                    withIntermediateDirectories: true)
        }
        try? fm.createDirectory(at: pdfDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: pdfPreviewDirectory, withIntermediateDirectories: true)
    }

    // MARK: - PDF storage (Step 4.5)
    //
    // PDFs live outside `Category` because they're not 1:1 with a
    // SwiftData record id — the same file can be referenced from
    // many `PDFPageContent` rows when a user pulls multiple pages
    // out of one document. The filename is the deduplicated
    // `pdfDocumentId`, computed via `writePDF(from:hash:)`.

    /// `Documents/MediaAttachments/pdfs/`.
    static var pdfDirectory: URL {
        rootURL.appendingPathComponent("pdfs", isDirectory: true)
    }

    /// `Documents/MediaAttachments/pdf-previews/`.
    static var pdfPreviewDirectory: URL {
        rootURL.appendingPathComponent("pdf-previews", isDirectory: true)
    }

    /// `Documents/MediaAttachments/pdfs/<pdfDocumentId>.pdf`.
    static func url(forPDF id: UUID) -> URL {
        pdfDirectory.appendingPathComponent("\(id.uuidString).pdf")
    }

    /// SHA-256 → `pdfDocumentId` mapping. Persisted as a single
    /// JSON file (`pdfs/_index.json`) so dedup checks survive
    /// launches without paying SwiftData's per-row cost for a
    /// small lookup table. Read on demand; the in-memory cache
    /// behind `pdfDocumentId(forHash:)` keeps repeated lookups
    /// during a single import batch cheap.
    private static let pdfIndexFilename = "_index.json"
    private static var pdfHashIndexCache: [String: UUID]?

    private static var pdfIndexURL: URL {
        pdfDirectory.appendingPathComponent(pdfIndexFilename)
    }

    private static func loadPDFHashIndex() -> [String: UUID] {
        if let cached = pdfHashIndexCache { return cached }
        guard let data = try? Data(contentsOf: pdfIndexURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            pdfHashIndexCache = [:]
            return [:]
        }
        var map: [String: UUID] = [:]
        for (hash, uuidString) in decoded {
            if let uuid = UUID(uuidString: uuidString) {
                map[hash] = uuid
            }
        }
        pdfHashIndexCache = map
        return map
    }

    private static func savePDFHashIndex(_ map: [String: UUID]) {
        pdfHashIndexCache = map
        let stringMap = map.mapValues { $0.uuidString }
        guard let data = try? JSONEncoder().encode(stringMap) else { return }
        try? data.write(to: pdfIndexURL, options: .atomic)
    }

    /// Returns the existing `pdfDocumentId` for a content hash, or
    /// `nil` if this hash has never been imported.
    static func pdfDocumentId(forHash hash: String) -> UUID? {
        loadPDFHashIndex()[hash]
    }

    /// Idempotent. Writes `data` to
    /// `pdfs/<pdfDocumentId>.pdf` if no row with this hash exists;
    /// otherwise reuses the prior document id. Returns the id the
    /// caller should store on its `PDFPageContent` rows.
    @discardableResult
    static func writePDF(from data: Data, hash: String) -> UUID {
        ensureDirectoriesExist()
        var index = loadPDFHashIndex()
        if let existing = index[hash],
           FileManager.default.fileExists(atPath: url(forPDF: existing).path) {
            return existing
        }
        let newId = UUID()
        let dest = url(forPDF: newId)
        do {
            try data.write(to: dest, options: .atomic)
            index[hash] = newId
            savePDFHashIndex(index)
            return newId
        } catch {
            logger.error("writePDF failed hash=\(hash, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return newId  // best-effort — caller stores the id even if write failed
        }
    }

    /// SHA-256 hex digest of `data`. Used to key `pdfHashIndex`.
    /// Computed on whatever thread the caller is on; small enough
    /// even for large PDFs (~30ms for 50MB on a modern iPad).
    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Write a per-`PDFPageContent` preview PNG to
    /// `pdf-previews/<contentId>.png`. The filename returned (just
    /// the basename) is what the row stores. Synchronous because
    /// PNG encoding is fast and the import pipeline already runs
    /// inside a Task.
    @discardableResult
    static func writePDFPreview(_ image: UIImage, contentId: UUID) -> String? {
        ensureDirectoriesExist()
        let name = "\(contentId.uuidString).png"
        let dest = pdfPreviewDirectory.appendingPathComponent(name)
        guard let pngData = image.pngData() else { return nil }
        do {
            try pngData.write(to: dest, options: .atomic)
            return name
        } catch {
            logger.error("writePDFPreview failed contentId=\(contentId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Hard-delete threshold for the orphan sweeps. A file is
    /// only deleted if it both (a) has no active SwiftData row
    /// pointing at it AND (b) was modified more than this far in
    /// the past. The grace window protects against race
    /// conditions — a freshly-written file that the row commit
    /// hasn't reached yet, an in-flight CloudKit reconcile, etc.
    /// 30 days matches the architecture spec's conservative
    /// default.
    private static let orphanGracePeriod: TimeInterval = 30 * 24 * 60 * 60

    /// Background-priority garbage collection. For each PDF on
    /// disk, query SwiftData for any active `PDFPageContent`
    /// referencing the id; delete the file if none AND the file
    /// is older than `orphanGracePeriod`. Same logic for orphaned
    /// preview thumbnails. Step 10 wires this into the app-launch
    /// background task; also callable from debug tooling.
    static func purgeOrphanedPDFs(context: ModelContext) {
        let fm = FileManager.default
        let pdfFiles = (try? fm.contentsOfDirectory(at: pdfDirectory, includingPropertiesForKeys: nil)) ?? []
        let descriptor = FetchDescriptor<PDFPageContent>()
        let activeContents = (try? context.fetch(descriptor)) ?? []
        let referencedIds = Set(activeContents.map(\.pdfDocumentId))
        let referencedPreviewNames = Set(activeContents.compactMap(\.previewImageFilename))

        // Index also gets reaped — drop any entry whose value isn't
        // in `referencedIds`.
        var index = loadPDFHashIndex()
        var indexChanged = false

        for fileURL in pdfFiles where fileURL.pathExtension.lowercased() == "pdf" {
            let stem = fileURL.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: stem) else { continue }
            if !referencedIds.contains(uuid), isPastGracePeriod(fileURL) {
                try? fm.removeItem(at: fileURL)
                for (hash, id) in index where id == uuid {
                    index.removeValue(forKey: hash)
                    indexChanged = true
                }
            }
        }
        if indexChanged { savePDFHashIndex(index) }

        let previewFiles = (try? fm.contentsOfDirectory(at: pdfPreviewDirectory, includingPropertiesForKeys: nil)) ?? []
        for fileURL in previewFiles where fileURL.pathExtension.lowercased() == "png" {
            let name = fileURL.lastPathComponent
            if !referencedPreviewNames.contains(name), isPastGracePeriod(fileURL) {
                try? fm.removeItem(at: fileURL)
            }
        }
    }

    /// Step 10 — orphan sweep for `Documents/MediaAttachments/images/`.
    /// For each on-disk image file, look up an active
    /// `ImageContent` by id (the filename stem is the UUID); if
    /// none AND the file is older than `orphanGracePeriod`, delete.
    static func purgeOrphanedImages(context: ModelContext) {
        let fm = FileManager.default
        let dir = directory(for: .images)
        let imageFiles = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let descriptor = FetchDescriptor<ImageContent>()
        let active = (try? context.fetch(descriptor)) ?? []
        let referencedIds = Set(active.map(\.id))
        for fileURL in imageFiles {
            let stem = fileURL.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: stem) else { continue }
            if !referencedIds.contains(uuid), isPastGracePeriod(fileURL) {
                try? fm.removeItem(at: fileURL)
            }
        }
    }

    /// Step 10 — orphan sweep for `Documents/MediaAttachments/audio/`
    /// and `lectures/`. Same shape as `purgeOrphanedImages`; both
    /// audio categories key off `AudioContent.id` since Step 5
    /// consolidated short notes + lectures into a single content
    /// entity.
    static func purgeOrphanedAudio(context: ModelContext) {
        let fm = FileManager.default
        let descriptor = FetchDescriptor<AudioContent>()
        let active = (try? context.fetch(descriptor)) ?? []
        let referencedIds = Set(active.map(\.id))
        for category in [Category.audio, Category.lectures] {
            let dir = directory(for: category)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for fileURL in files {
                let stem = fileURL.deletingPathExtension().lastPathComponent
                guard let uuid = UUID(uuidString: stem) else { continue }
                if !referencedIds.contains(uuid), isPastGracePeriod(fileURL) {
                    try? fm.removeItem(at: fileURL)
                }
            }
        }
    }

    /// Umbrella that runs every orphan sweep in sequence. Cheap to
    /// call repeatedly — the grace period gate makes the sweep a
    /// no-op for any file that isn't yet eligible.
    static func purgeAllOrphans(context: ModelContext) {
        purgeOrphanedImages(context: context)
        purgeOrphanedAudio(context: context)
        purgeOrphanedPDFs(context: context)
    }

    /// `true` when the file at `url` was last modified more than
    /// `orphanGracePeriod` ago. Missing modification date errs on
    /// the safe side and returns `false` (don't delete unknown).
    private static func isPastGracePeriod(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate
        else { return false }
        return Date().timeIntervalSince(modified) > orphanGracePeriod
    }

    // MARK: - Writes

    /// Encode + write an image off the main actor. Returns the
    /// documents-relative path on success.
    @discardableResult
    static func writeImage(
        _ image: UIImage,
        id: UUID,
        format: ImageFormat = .jpeg(quality: 0.85)
    ) async -> String? {
        ensureDirectoriesExist()
        let ext = format.fileExtension
        let url = Self.url(for: .images, id: id, fileExtension: ext)
        let data: Data? = await Task.detached(priority: .userInitiated) { () -> Data? in
            switch format {
            case .jpeg(let quality): return image.jpegData(compressionQuality: quality)
            case .png:               return image.pngData()
            }
        }.value
        guard let data else { return nil }
        do {
            try await Task.detached(priority: .userInitiated) {
                try data.write(to: url, options: .atomic)
            }.value
            return relativePath(forCategory: .images, id: id, fileExtension: ext)
        } catch {
            logger.error("writeImage failed id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    enum ImageFormat: Sendable {
        case jpeg(quality: CGFloat)
        case png

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png:  return "png"
            }
        }
    }

    /// Move an existing audio recording into `audio/<id>.m4a`. Used by
    /// the audio annotation flow and the audio-file picker. Idempotent —
    /// if the destination already matches the source path, returns the
    /// existing relative path.
    @discardableResult
    static func adoptAudio(at sourceURL: URL, id: UUID) async -> String? {
        ensureDirectoriesExist()
        let dest = url(for: .audio, id: id)
        return await moveOrCopy(source: sourceURL, dest: dest, category: .audio, id: id)
    }

    /// Same as `adoptAudio` for long-form lecture recordings.
    @discardableResult
    static func adoptLecture(at sourceURL: URL, id: UUID) async -> String? {
        ensureDirectoriesExist()
        let dest = url(for: .lectures, id: id)
        return await moveOrCopy(source: sourceURL, dest: dest, category: .lectures, id: id)
    }

    private static func moveOrCopy(source: URL, dest: URL, category: Category, id: UUID) async -> String? {
        if source.standardizedFileURL.path == dest.standardizedFileURL.path {
            return relativePath(forCategory: category, id: id)
        }
        let result: String? = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: source, to: dest)
                return relativePath(forCategory: category, id: id)
            } catch {
                // Move can fail across volumes — fall back to copy + delete.
                do {
                    try fm.copyItem(at: source, to: dest)
                    try? fm.removeItem(at: source)
                    return relativePath(forCategory: category, id: id)
                } catch {
                    return nil
                }
            }
        }.value
        if result == nil {
            logger.error("adopt failed category=\(category.rawValue, privacy: .public) id=\(id, privacy: .public)")
        }
        return result
    }

    // MARK: - Reads

    /// Resolve a documents-relative path stored in a record. Returns
    /// the absolute URL even if the file doesn't exist; callers
    /// responsible for `FileManager.fileExists`-checking when it
    /// matters (e.g. to decide whether to drop the record).
    static func absoluteURL(forRelativePath relPath: String) -> URL {
        documentsURL.appendingPathComponent(relPath)
    }

    static func fileExists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: absoluteURL(forRelativePath: relativePath).path)
    }

    // MARK: - Deletes

    static func delete(category: Category, id: UUID, fileExtension: String? = nil) {
        let url = Self.url(for: category, id: id, fileExtension: fileExtension)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Diagnostics

    struct Diagnostics: Sendable {
        var imageCount: Int
        var imageBytes: Int64
        var audioCount: Int
        var audioBytes: Int64
        var lectureCount: Int
        var lectureBytes: Int64

        var totalCount: Int  { imageCount + audioCount + lectureCount }
        var totalBytes: Int64 { imageBytes + audioBytes + lectureBytes }
    }

    /// Walk the unified tree. Returns counts + bytes per category. Runs
    /// on the calling actor — small (single-directory enumeration), but
    /// callers reaching for it from a UI path should hop off main first.
    static func diagnostics() -> Diagnostics {
        ensureDirectoriesExist()
        let (imgCount, imgBytes) = enumerate(directory(for: .images))
        let (audCount, audBytes) = enumerate(directory(for: .audio))
        let (lecCount, lecBytes) = enumerate(directory(for: .lectures))
        return Diagnostics(
            imageCount:   imgCount, imageBytes:   imgBytes,
            audioCount:   audCount, audioBytes:   audBytes,
            lectureCount: lecCount, lectureBytes: lecBytes
        )
    }

    private static func enumerate(_ dir: URL) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return (0, 0) }
        var count = 0
        var bytes: Int64 = 0
        for url in items {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(v?.fileSize ?? 0)
        }
        return (count, bytes)
    }

    // MARK: - One-shot launch migration
    //
    // Idempotent. Runs on app launch. Walks each metadata store, moves
    // bytes from legacy paths into the unified layout, and updates the
    // record's path reference. Records whose underlying file is missing
    // are dropped with a warning (we cannot recover lost bytes; better
    // to drop than to render forever-grey placeholders for ghost records).
    //
    // Safe to call multiple times — every step uses `fileExists` /
    // record-already-points-here checks, so a second run after a clean
    // first pass does nothing.

    /// Phase 3b deletion: the launch-migration body that walked three
    /// legacy directories and rewrote record paths is gone. The app
    /// never shipped, so no install in the wild has data in the old
    /// layouts. New writes target the unified tree directly (see
    /// `EditorViewModel.commitImportedImage`,
    /// `EditorViewModel.startRecording`, `LectureRecorder.start`,
    /// `AudioFilePicker.handlePickedAudioFile`).
    ///
    /// The flag is still written so any future migration code can use
    /// the same gate without colliding with old installs that *did*
    /// write the flag during the brief pre-Phase-3b period.
    static func migrateExistingFilesIfNeeded() async {
        ensureDirectoriesExist()
        UserDefaults.standard.set(true, forKey: migrationFlagKey)
    }
}
