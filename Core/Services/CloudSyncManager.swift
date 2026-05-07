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

    func enable() async throws {
        guard !isEnabled else { return }
        try verifyiCloudAvailable()

        // Mirror the Notebooks directory into iCloud Drive ubiquity container
        try await startUbiquityMirroring()

        isEnabled  = true
        syncStatus = .checking
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        await reconcileAfterLaunch()
    }

    func disable() async throws {
        guard isEnabled else { return }
        // Stop evicting; leave files already uploaded in iCloud as-is
        await MainActor.run {
            isEnabled  = false
            syncStatus = .disabled
        }
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
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

    // MARK: - iCloud Drive mirroring

    private func startUbiquityMirroring() async throws {
        guard let ubiquityURL = ubiquityDocumentsURL() else {
            throw CloudSyncError.iCloudUnavailable
        }
        let notebooksSource = StorageService.notebooksDirectoryURL
        let notebooksDest   = ubiquityURL.appendingPathComponent("Notebooks")

        let fm = FileManager.default
        try fm.createDirectory(at: notebooksDest, withIntermediateDirectories: true)

        // Copy any existing local notebooks to iCloud if not already there
        if let items = try? fm.contentsOfDirectory(
            at: notebooksSource,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            for item in items {
                let dest = notebooksDest.appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: item, to: dest)
                }
            }
        }

        // Set the ubiquity attribute to upload
        try fm.setUbiquitous(true, itemAt: notebooksDest, destinationURL: notebooksDest)
    }

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
