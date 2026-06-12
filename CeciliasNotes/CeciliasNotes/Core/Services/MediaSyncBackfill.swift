import Foundation
import SwiftData
import os

/// One-time backfill: copy the bytes of every existing image and
/// audio attachment into the SwiftData row's
/// `@Attribute(.externalStorage)` data column so the data can sync
/// via CloudKit going forward. Pre-backfill rows had bytes only in
/// `Documents/MediaAttachments/` — a local-only path — and so were
/// invisible on every other signed-in device. After this runs once,
/// every image / audio row carries its bytes as a CKAsset and the
/// pipeline is consistent: new writes populate the column on import
/// (`EditorViewModel.commitImportedImage`,
/// `MediaInsertCoordinator.saveImageRecord`,
/// `DictationFlowCommit.finalise…`); legacy writes get patched up
/// here.
///
/// Idempotent — guarded by a UserDefaults flag plus a per-row check
/// that the column is genuinely empty before reading the file.
/// Safe to re-run; rows already backfilled cost one nil-check.
enum MediaSyncBackfill {

    private static let runOnceKey = "ceciliasnotes.mediaSyncBackfill.v1.done"
    private static let logger = Logger(
        subsystem: "app.ceciliasnotes",
        category: "MediaSyncBackfill"
    )

    /// Run the backfill at low priority, off the main actor. Safe
    /// to call on every launch — it is a no-op once complete, and
    /// re-running mid-flight (if the user kills the app) just
    /// resumes from the next un-backfilled row.
    static func runIfNeeded() {
        if UserDefaults.standard.bool(forKey: runOnceKey) { return }
        Task.detached(priority: .utility) {
            await runPass()
        }
    }

    @MainActor
    private static func runPass() async {
        let ctx = StorageService.shared.context

        let imageDescriptor = FetchDescriptor<ImageContent>()
        let images = (try? ctx.fetch(imageDescriptor)) ?? []
        var imagesBackfilled = 0
        for row in images {
            if row.imageData != nil { continue }
            let url = row.fileURL
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty
            else { continue }
            row.imageData = data
            row.updatedAt = Date()
            imagesBackfilled += 1
        }

        let audioDescriptor = FetchDescriptor<AudioContent>()
        let audios = (try? ctx.fetch(audioDescriptor)) ?? []
        var audioBackfilled = 0
        for row in audios {
            if row.audioData != nil { continue }
            let url = row.fileURL
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty
            else { continue }
            row.audioData = data
            row.updatedAt = Date()
            audioBackfilled += 1
        }

        do {
            try ctx.save()
            UserDefaults.standard.set(true, forKey: runOnceKey)
            logger.info(
                "backfill complete images=\(imagesBackfilled, privacy: .public) audio=\(audioBackfilled, privacy: .public)"
            )
        } catch {
            // Leave the run-once flag false so the next launch can
            // try again — failure is almost always recoverable
            // (transient I/O, low disk).
            logger.error(
                "backfill save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
