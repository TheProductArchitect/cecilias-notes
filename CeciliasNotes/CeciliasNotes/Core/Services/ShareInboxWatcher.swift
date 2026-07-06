import Foundation
import UIKit

/// Watches the shared app-group `ShareInbox` folder for files
/// dropped in by the share extension and hands them off to the
/// main app for ingest. Mirrors the design of the iCloud-Inbox
/// `CeciliasNotesFileWatcher`, but reads from the synchronous
/// app-group container instead of an asynchronously-syncing
/// ubiquity container — files dropped by the extension show up
/// immediately, so a foreground-driven sweep is enough; no
/// NSMetadataQuery needed.
///
/// Lifecycle:
///   • Started from app launch with `start()`.
///   • Sweeps on `UIApplication.didBecomeActiveNotification` so a
///     file shared while the app was in the background is picked up
///     the moment the user returns.
///
/// Ingest routing:
///   • `.pdf` → posts `.shareInboxPDFArrived` with the file URL.
///     LibraryView observes and presents the PDF page picker.
///   • image extensions → posts `.shareInboxImageArrived` with the
///     file URL. The existing image-import path takes over.
///   • `.cnshare` → text / URL quick-capture JSON from the share
///     extension → `.shareInboxCaptureArrived`.
///
/// After a successful ingest the watcher deletes the file so the
/// next sweep doesn't re-process it.
@MainActor
final class ShareInboxWatcher {

    static let shared = ShareInboxWatcher()
    private init() {}

    private static let appGroupID = "group.app.ceciliasnotes"
    private static let inboxFolderName = "ShareInbox"

    private var didStart = false

    func start() {
        guard !didStart else { return }
        didStart = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        // Purge anything left over from a previous run that's
        // older than the freshness window. Earlier versions of
        // this watcher kept cancelled files around so the user
        // could "try again next launch", which in practice meant
        // the picker re-popped every cold start with the same
        // stale PDF forever. The picker's cancel handler now
        // consumes the file too; this sweep covers historical
        // accumulation.
        purgeStaleFiles()
        // First sweep on start so a launch-from-share-extension
        // lands without waiting for the next foreground event.
        sweepNow()
    }

    /// Files older than 24h are treated as orphaned (interrupted
    /// import, cancelled flow that didn't consume, etc.) and
    /// deleted. Anything fresher is left for the upcoming sweep
    /// to dispatch.
    private func purgeStaleFiles() {
        guard let inbox = inboxURL() else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)  // 24h
        for file in contents {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            guard modified < cutoff else { continue }
            try? fm.removeItem(at: file)
        }
    }

    @objc private func handleDidBecomeActive() {
        sweepNow()
    }

    private func sweepNow() {
        guard let inbox = inboxURL() else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in contents {
            let ext = file.pathExtension.lowercased()
            switch ext {
            case "pdf":
                NotificationCenter.default.post(
                    name: .shareInboxPDFArrived,
                    object: nil,
                    userInfo: ["fileURL": file]
                )
            case "png", "jpg", "jpeg", "heic", "heif":
                NotificationCenter.default.post(
                    name: .shareInboxImageArrived,
                    object: nil,
                    userInfo: ["fileURL": file]
                )
            case "cnshare":
                NotificationCenter.default.post(
                    name: .shareInboxCaptureArrived,
                    object: nil,
                    userInfo: ["fileURL": file]
                )
            default:
                // Unknown payload — leave it alone so we don't
                // silently drop the user's content. They can clear
                // the inbox via app reinstall if it ever piles up.
                continue
            }
        }
    }

    /// Called by the consumer once it's finished with the file so
    /// the next sweep doesn't see it again. Centralised here so the
    /// "delete" step lives next to the "read" step.
    func consume(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func inboxURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return nil }
        return container.appendingPathComponent(
            Self.inboxFolderName,
            isDirectory: true
        )
    }
}

extension Notification.Name {
    static let shareInboxPDFArrived = Notification.Name("ShareInbox.pdfArrived")
    static let shareInboxImageArrived = Notification.Name("ShareInbox.imageArrived")
    static let shareInboxCaptureArrived = Notification.Name("ShareInbox.captureArrived")
}
