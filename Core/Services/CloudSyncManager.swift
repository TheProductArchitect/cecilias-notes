import Foundation
import Combine

// MARK: - CloudSyncManager

final class CloudSyncManager: ObservableObject {

    @Published private(set) var isEnabled: Bool
    @Published private(set) var syncStatus: SyncStatus

    enum SyncStatus: Equatable {
        case disabled
        case checking
        case upToDate
        case syncing(progress: Double)
        case error(String)
    }

    // MARK: Persistence key
    private static let enabledKey = "ink.icloud.sync.enabled"

    // MARK: Init

    init() {
        let persisted = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.isEnabled  = persisted
        self.syncStatus = persisted ? .checking : .disabled
        if persisted { Task { await self.reconcileAfterLaunch() } }
    }

    // MARK: Public API

    /// Enables iCloud sync. Moves the local Notebooks asset directory into the
    /// ubiquity container so subsequent reads/writes (via the now-dynamic
    /// `StorageService.notebooksDirectoryURL`) target iCloud automatically.
    /// Sets the persisted flag *after* the move so a crash mid-migration leaves
    /// the app reading from the local directory it still owns.
    func enable() async throws {
        guard !isEnabled else { return }
        try verifyiCloudAvailable()

        // Establish destination
        guard let ubiquityRoot = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/Notebooks")
        else { throw CloudSyncError.iCloudUnavailable }

        let fm = FileManager.default
        try fm.createDirectory(at: ubiquityRoot, withIntermediateDirectories: true)

        // Move every notebook directory currently in local Application Support
        // into the ubiquity root. Existing iCloud items are left in place.
        let local = StorageService.localNotebooksDirectoryURL
        if fm.fileExists(atPath: local.path) {
            let items = (try? fm.contentsOfDirectory(at: local,
                                                     includingPropertiesForKeys: nil,
                                                     options: .skipsHiddenFiles)) ?? []
            for src in items {
                let dst = ubiquityRoot.appendingPathComponent(src.lastPathComponent)
                guard !fm.fileExists(atPath: dst.path) else { continue }
                // setUbiquitous handles the move + ubiquity attribute in one
                // shot; fall back to plain move if it refuses (e.g. permissions).
                do {
                    try fm.setUbiquitous(true, itemAt: src, destinationURL: dst)
                } catch {
                    try? fm.moveItem(at: src, to: dst)
                }
            }
        }

        // Persist AFTER the move — partial-migration safety.
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        await MainActor.run {
            isEnabled  = true
            syncStatus = .checking
        }
        await reconcileAfterLaunch()
    }

    /// Disables iCloud sync. Moves files BACK from the ubiquity container into
    /// local Application Support so they remain accessible offline. Uses
    /// NSFileCoordinator since we're reading from iCloud-backed paths.
    func disable() async throws {
        guard isEnabled else { return }

        let fm = FileManager.default
        guard let ubiquityRoot = fm.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/Notebooks")
        else {
            // No ubiquity → nothing to move. Just flip the flag.
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            await MainActor.run {
                isEnabled  = false
                syncStatus = .disabled
                stopMetadataQueryObserver()
            }
            return
        }

        let local = StorageService.localNotebooksDirectoryURL
        try fm.createDirectory(at: local, withIntermediateDirectories: true)

        let items = (try? fm.contentsOfDirectory(at: ubiquityRoot,
                                                 includingPropertiesForKeys: nil,
                                                 options: .skipsHiddenFiles)) ?? []
        for src in items {
            let dst = local.appendingPathComponent(src.lastPathComponent)
            guard !fm.fileExists(atPath: dst.path) else { continue }

            // Coordinator-wrapped move — required for ubiquity reads.
            var coordError: NSError?
            var moveError:  Error?
            NSFileCoordinator().coordinate(
                readingItemAt: src, options: .withoutChanges,
                writingItemAt: dst, options: .forMoving,
                error: &coordError
            ) { readURL, writeURL in
                do {
                    try fm.moveItem(at: readURL, to: writeURL)
                } catch {
                    moveError = error
                }
            }
            if let err = coordError ?? moveError { throw err }
        }

        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        await MainActor.run {
            isEnabled  = false
            syncStatus = .disabled
            stopMetadataQueryObserver()
        }
    }

    /// Stops any in-flight metadata observation. Single-shot queries clean
    /// themselves up; this is a guard against future refactors that hold one.
    @MainActor
    private func stopMetadataQueryObserver() {
        // Currently no persistent query — runMetadataQuery() is single-shot.
        // Hook for future use; intentionally empty.
    }

    func syncNow() async {
        guard isEnabled else { return }
        await MainActor.run { syncStatus = .checking }
        do {
            try verifyiCloudAvailable()
            await runMetadataQuery()
        } catch {
            await MainActor.run { syncStatus = .error(error.localizedDescription) }
        }
    }

    // MARK: - iCloud Drive sync helpers

    private func reconcileAfterLaunch() async {
        await MainActor.run { syncStatus = .checking }

        // Download any items marked as not downloaded by the OS
        guard let ubiquityURL = ubiquityDocumentsURL() else {
            await MainActor.run { syncStatus = .error(CloudSyncError.iCloudUnavailable.localizedDescription) }
            return
        }

        let notebooksDest = ubiquityURL.appendingPathComponent("Notebooks")
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: notebooksDest,
            includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey],
            options: .skipsHiddenFiles
        )) ?? []

        for item in items {
            let status = try? item.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
            if status != .current {
                try? fm.startDownloadingUbiquitousItem(at: item)
            }
        }

        await runMetadataQuery()
    }

    private func runMetadataQuery() async {
        // Use NSMetadataQuery to observe upload/download progress
        await MainActor.run { syncStatus = .checking }

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            (ubiquityDocumentsURL()?.appendingPathComponent("Notebooks").path ?? "")
        )
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]

        // Single-shot query — gather results synchronously via a continuation
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                query.stop()
                if let o = observer { NotificationCenter.default.removeObserver(o) }
                self?.processQueryResults(query)
                continuation.resume()
            }
            OperationQueue.main.addOperation { query.start() }
        }
    }

    @MainActor
    private func processQueryResults(_ query: NSMetadataQuery) {
        var uploading   = 0
        var downloading = 0

        for i in 0 ..< query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem else { continue }
            let uploadPct   = item.value(forAttribute: NSMetadataUbiquitousItemPercentUploadedKey) as? Double ?? 100
            let downloadPct = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double ?? 100
            if uploadPct   < 100 { uploading   += 1 }
            if downloadPct < 100 { downloading += 1 }
        }

        if uploading + downloading > 0 {
            let total    = query.resultCount > 0 ? query.resultCount : 1
            let progress = Double(total - uploading - downloading) / Double(total)
            syncStatus = .syncing(progress: progress)
        } else {
            syncStatus = .upToDate
        }
    }

    // MARK: - Helpers

    private func verifyiCloudAvailable() throws {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            throw CloudSyncError.iCloudUnavailable
        }
    }

    private func ubiquityDocumentsURL() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents")
    }
}

// MARK: - CloudSyncError

private enum CloudSyncError: LocalizedError {
    case iCloudUnavailable

    var errorDescription: String? {
        "iCloud is not available. Sign in to iCloud in Settings and try again."
    }
}
