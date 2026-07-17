import Foundation
import SwiftData

/// Watches the iCloud Inbox folder for `.inkbook` files dropped by
/// external agents (e.g. `cecilias-notes-mcp` on macOS) and hands
/// each new/changed file to `CeciliasNotesImporter`.
///
/// **Where it watches.** The app has a private iCloud container
/// (`iCloud.app.ceciliasnotes`, see `CeciliasNotes.entitlements`).
/// External writers drop files into
/// `<ubiquity-container>/Documents/Inbox/`, which the user sees as a
/// folder under Files.app › iCloud Drive › Cecilia's Notes once the
/// `NSUbiquitousContainerIsDocumentScopePublic` Info.plist key is
/// set. We deliberately stay inside the app's own container rather
/// than poking at general `com~apple~CloudDocs` — iOS does not let an
/// app metadata-query arbitrary CloudDocs paths.
///
/// **How it watches.** NSMetadataQuery scoped to the app's ubiquity
/// container. Matches the pattern used by `CloudSyncManager`. The
/// query stays live for the lifetime of the watcher — every gather
/// + every update notification re-checks the result set, materialises
/// anything not yet downloaded, and dispatches the URL to the
/// importer. The importer is idempotent so spurious re-fires are
/// harmless.
@MainActor
final class CeciliasNotesFileWatcher {

    static let shared = CeciliasNotesFileWatcher()

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    /// `lastSeenModification[url] = mtime` — used to suppress
    /// re-imports when the metadata query fires for an unchanged
    /// file (which it does every time it gathers).
    private var lastSeenModification: [URL: Date] = [:]

    /// In-memory ring buffer of recent inbox events. Drives the
    /// Settings → cloud diagnostic so the user can verify that
    /// files dropped by an external agent actually reached the iPad
    /// (vs failed to leave the Mac, failed to upload to iCloud, or
    /// failed to download to this device).
    struct InboxEvent: Identifiable {
        let id = UUID()
        let date: Date
        let filename: String
        let kind: Kind
        enum Kind: String {
            case detected            // metadata query saw it
            case downloading         // waiting for iCloud to materialise
            case imported            // handed to importer
            case skippedDuplicate    // same mtime as last seen
            case unknownExtension
        }
    }
    /// Most-recent-first. Cap at 50 so the buffer stays light.
    private(set) var recentEvents: [InboxEvent] = []
    private static let eventBufferSize = 50

    func recordEvent(filename: String, kind: InboxEvent.Kind) {
        recentEvents.insert(
            InboxEvent(date: Date(), filename: filename, kind: kind),
            at: 0
        )
        if recentEvents.count > Self.eventBufferSize {
            recentEvents.removeLast(recentEvents.count - Self.eventBufferSize)
        }
        NotificationCenter.default.post(name: .ceciliasNotesInboxEventsChanged, object: nil)
    }

    /// Container identifier from the .entitlements file. Must match
    /// `com.apple.developer.ubiquity-container-identifiers` exactly.
    private static let containerIdentifier = "iCloud.app.ceciliasnotes"

    private init() {}

    /// Boot the watcher. Idempotent — safe to call from `App.onAppear`
    /// every cold launch. Resolves the Inbox URL, ensures the folder
    /// exists, then starts the metadata query.
    func start() {
        guard query == nil else { return }
        guard let inbox = inboxURL() else {
            log("iCloud ubiquity container unavailable; watcher idle.")
            return
        }

        // Materialise the inbox directory inside the container so the
        // user can see it in Files.app even when empty, and so the
        // metadata query has a concrete path to scan.
        try? FileManager.default.createDirectory(
            at: inbox, withIntermediateDirectories: true
        )

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // `BEGINSWITH` matches anything inside the Inbox subtree; the
        // extension filter keeps it narrow. We accept:
        //   • `.inkbook`     — agent-authored notebooks (existing flow).
        //   • `.json`        — quiz MCP responses (handled by
        //                      `QuizMCPImporter` after dispatch).
        //   • `.ceciliabook` — full-fidelity archives from multipeer
        //                      "Send to Device". The dispatch switch
        //                      below always handled these, but the
        //                      query never surfaced them — the branch
        //                      was unreachable until this clause.
        q.predicate = NSPredicate(
            format: "(%K BEGINSWITH %@) AND ((%K ENDSWITH %@) OR (%K ENDSWITH %@) OR (%K ENDSWITH %@))",
            NSMetadataItemPathKey, inbox.path,
            NSMetadataItemFSNameKey, ".inkbook",
            NSMetadataItemFSNameKey, ".json",
            NSMetadataItemFSNameKey, ".\(NotebookArchive.fileExtension)"
        )

        let center = NotificationCenter.default
        for name in [
            NSNotification.Name.NSMetadataQueryDidFinishGathering,
            NSNotification.Name.NSMetadataQueryDidUpdate
        ] {
            let token = center.addObserver(
                forName: name, object: q, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleQueryUpdate()
                }
            }
            observers.append(token)
        }

        query = q
        q.start()
        log("started; inbox=\(inbox.path)")
    }

    /// Stop the watcher and drop all observers. Used on test teardown
    /// and when the user signs out of iCloud.
    func stop() {
        query?.stop()
        query = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        lastSeenModification.removeAll()
    }

    /// Re-run the current query gather and re-import anything that
    /// looks new. Public hook for a "Sync from Mac" pull-to-refresh
    /// or manual menu item.
    func rescan() {
        query?.disableUpdates()
        query?.enableUpdates()
        handleQueryUpdate()
    }

    // MARK: Internals

    private func handleQueryUpdate() {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }

        let fm = FileManager.default
        for i in 0 ..< q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
            else { continue }

            // Trigger a download if iCloud hasn't materialised the
            // file locally yet. Re-fires will pick it up once the
            // status flips to `.current`.
            let downloadStatus = (try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]
            ).ubiquitousItemDownloadingStatus) ?? .notDownloaded
            if downloadStatus != .current {
                try? fm.startDownloadingUbiquitousItem(at: url)
                recordEvent(filename: url.lastPathComponent, kind: .downloading)
                continue
            }

            // De-dupe by content modification time so re-gathers
            // don't re-import unchanged files.
            let mtime = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            if let prev = lastSeenModification[url], prev == mtime {
                continue
            }
            // First time we've seen this URL at this mtime.
            let wasNew = lastSeenModification[url] == nil
            lastSeenModification[url] = mtime
            if wasNew {
                recordEvent(filename: url.lastPathComponent, kind: .detected)
            }

            // Dispatch by extension and filename prefix.
            switch url.pathExtension.lowercased() {
            case "inkbook":
                recordEvent(filename: url.lastPathComponent, kind: .imported)
                CeciliasNotesImporter.shared.importFile(at: url)
            case NotebookArchive.fileExtension:
                // Full-fidelity notebook received (multipeer send or a
                // .ceciliabook dropped into the Inbox). Import as a
                // fresh editable copy with all elements + media —
                // decode runs off-main (`importArchiveAsync`); only
                // the SwiftData reconstruct touches the main actor.
                recordEvent(filename: url.lastPathComponent, kind: .imported)
                Task { @MainActor in
                    if let data = try? Data(contentsOf: url),
                       let nb = await NotebookArchiveIO.importArchiveAsync(data: data) {
                        MultipeerNotebookHint.broadcastNotebookChanged(notebookId: nb.id)
                    }
                    try? FileManager.default.removeItem(at: url)
                }
            case "json" where url.lastPathComponent.hasPrefix("quiz_generation_response"):
                recordEvent(filename: url.lastPathComponent, kind: .imported)
                QuizMCPImporter.shared.importResponse(at: url)
            case "json" where url.lastPathComponent.hasPrefix("delete_notebook_request_"):
                recordEvent(filename: url.lastPathComponent, kind: .imported)
                handleDeleteRequest(at: url)
            default:
                recordEvent(filename: url.lastPathComponent, kind: .unknownExtension)
                continue
            }
        }
    }

    /// Public read of the Inbox URL so the MCP request writer can place
    /// outgoing files alongside incoming ones.
    static func sharedInboxURL() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: containerIdentifier)?
            .appendingPathComponent("Documents")
            .appendingPathComponent("Inbox")
    }

    /// Absolute URL of the iCloud Inbox folder, or nil when the
    /// device has no iCloud account / sandbox can't reach the
    /// container. Uses the explicit container identifier from the
    /// entitlements file rather than `nil` so the resolution is
    /// deterministic when multiple containers are provisioned.
    private func inboxURL() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: Self.containerIdentifier)?
            .appendingPathComponent("Documents")
            .appendingPathComponent("Inbox")
    }

    // MARK: - Delete request handler

    /// Processes a `delete_notebook_request_<uuid>.json` file written by MCP.
    ///
    /// Expected payload: `{ "action": "delete_notebook", "notebook_id": "<uuid>" }`
    ///
    /// After soft-deleting the notebook in SwiftData the request file is
    /// removed from the Inbox so the watcher doesn't re-fire on the same file.
    private func handleDeleteRequest(at url: URL) {
        Task.detached(priority: .utility) {
            struct DeleteRequest: Decodable {
                let action: String
                let notebook_id: String
            }

            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordError: NSError?
            var payload: Data?

            coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                payload = try? Data(contentsOf: readURL)
            }

            guard let data   = payload,
                  let req    = try? JSONDecoder().decode(DeleteRequest.self, from: data),
                  req.action == "delete_notebook",
                  let nbId   = UUID(uuidString: req.notebook_id)
            else { return }

            await MainActor.run {
                let context = StorageService.shared.context
                let descriptor = FetchDescriptor<Notebook>(
                    predicate: #Predicate { $0.id == nbId && $0.isDeleted == false }
                )
                if let notebook = (try? context.fetch(descriptor))?.first {
                    try? StorageService.shared.deleteNotebook(notebook)
                }
            }

            // Remove the processed request file so it doesn't re-trigger.
            var removeError: NSError?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &removeError) { delURL in
                try? FileManager.default.removeItem(at: delURL)
            }
        }
    }

    private func log(_ message: String) {
        #if DEBUG
        dlog("[CeciliasNotesFileWatcher] \(message)")
        #endif
    }
}

extension Notification.Name {
    /// Posted whenever the file watcher's `recentEvents` buffer
    /// changes. The Settings → cloud diagnostic listens to refresh
    /// its activity list without polling.
    static let ceciliasNotesInboxEventsChanged = Notification.Name("ceciliasnotes.inbox.eventsChanged")
}
