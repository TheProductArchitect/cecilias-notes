import Foundation
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
    /// is missing. Safe to call repeatedly.
    static func ensureDirectoriesExist() {
        let fm = FileManager.default
        for category in Category.allCases {
            try? fm.createDirectory(at: directory(for: category),
                                    withIntermediateDirectories: true)
        }
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
