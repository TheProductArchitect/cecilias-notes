import Foundation
import Combine

// MARK: - CloudSyncManager

@MainActor
final class CloudSyncManager: ObservableObject {

    @Published private(set) var isEnabled: Bool
    @Published private(set) var syncStatus: SyncStatus
    /// Timestamp of the last successful sync. `nil` when the user has
    /// never enabled sync (or has just toggled it on for the first
    /// time and reconciliation hasn't completed).
    @Published private(set) var lastSyncedAt: Date?

    enum SyncStatus: Equatable {
        case disabled
        case checking
        case upToDate
        case syncing(progress: Double)
        /// iCloud account or network unreachable — writes still go to
        /// local store; sync resumes when reachable.
        case waitingForNetwork
        case error(String)
    }

    // MARK: Persistence keys
    private static let enabledKey      = "ceciliasnotes.icloud.sync.enabled"
    private static let lastSyncedKey   = "ceciliasnotes.icloud.sync.lastSyncedAt"

    // MARK: Init

    init() {
        let persisted = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.isEnabled  = persisted
        self.syncStatus = persisted ? .checking : .disabled
        if let interval = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? TimeInterval {
            self.lastSyncedAt = Date(timeIntervalSince1970: interval)
        } else {
            self.lastSyncedAt = nil
        }
        if persisted { Task { await self.reconcileAfterLaunch() } }

        // A paired peer just told us a notebook changed — its media
        // assets (images, audio) travel via the ubiquity container,
        // so kick a metadata pass now instead of waiting for the
        // next scheduled one. Debounced: hint bursts (every stroke
        // save broadcasts) collapse into one pass per 10 s.
        NotificationCenter.default.publisher(for: MultipeerNotebookHint.changedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isEnabled else { return }
                self.scheduleHintSync()
            }
            .store(in: &hintCancellables)
    }

    private var hintCancellables = Set<AnyCancellable>()
    private var hintSyncTask: Task<Void, Never>?

    private func scheduleHintSync() {
        guard hintSyncTask == nil else { return }
        hintSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self else { return }
            self.hintSyncTask = nil
            await self.syncNow()
        }
    }

    /// Stamp `lastSyncedAt` and persist. Called whenever the manager
    /// transitions into `.upToDate` after a successful reconcile.
    func markSyncCompleted(at date: Date = Date()) {
        lastSyncedAt = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastSyncedKey)
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

        guard let ubiquityRoot = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/Notebooks")
        else { throw CloudSyncError.iCloudUnavailable }

        // File I/O on background thread — never block the main actor.
        let local = StorageService.localNotebooksDirectoryURL
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try fm.createDirectory(at: ubiquityRoot, withIntermediateDirectories: true)
            if fm.fileExists(atPath: local.path) {
                let items = (try? fm.contentsOfDirectory(at: local,
                                                         includingPropertiesForKeys: nil,
                                                         options: .skipsHiddenFiles)) ?? []
                for src in items {
                    let dst = ubiquityRoot.appendingPathComponent(src.lastPathComponent)
                    guard !fm.fileExists(atPath: dst.path) else { continue }
                    do {
                        try fm.setUbiquitous(true, itemAt: src, destinationURL: dst)
                    } catch {
                        try? fm.moveItem(at: src, to: dst)
                    }
                }
            }
        }.value

        // Persist AFTER the move — partial-migration safety.
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        isEnabled  = true
        syncStatus = .checking
        await reconcileAfterLaunch()
    }

    /// Disables iCloud sync. Moves files BACK from the ubiquity container into
    /// local Application Support so they remain accessible offline. Uses
    /// NSFileCoordinator since we're reading from iCloud-backed paths.
    func disable() async throws {
        guard isEnabled else { return }

        guard let ubiquityRoot = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/Notebooks")
        else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            isEnabled  = false
            syncStatus = .disabled
            return
        }

        let local = StorageService.localNotebooksDirectoryURL
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try fm.createDirectory(at: local, withIntermediateDirectories: true)
            let items = (try? fm.contentsOfDirectory(at: ubiquityRoot,
                                                     includingPropertiesForKeys: nil,
                                                     options: .skipsHiddenFiles)) ?? []
            for src in items {
                let dst = local.appendingPathComponent(src.lastPathComponent)
                guard !fm.fileExists(atPath: dst.path) else { continue }
                var coordError: NSError?
                var moveError:  Error?
                NSFileCoordinator().coordinate(
                    readingItemAt: src, options: .withoutChanges,
                    writingItemAt: dst, options: .forMoving,
                    error: &coordError
                ) { readURL, writeURL in
                    do { try fm.moveItem(at: readURL, to: writeURL) }
                    catch { moveError = error }
                }
                if let err = coordError ?? moveError { throw err }
            }
        }.value

        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        isEnabled  = false
        syncStatus = .disabled
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
        syncStatus = .checking
        do {
            try verifyiCloudAvailable()
            await runMetadataQuery()
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - iCloud Drive sync helpers

    /// Public retry hook — called by `SyncStatusIndicator`'s "Try
    /// again" menu item when the user wants to recover from an
    /// error state. Re-runs availability check + restarts the
    /// NSMetadataQuery. Idempotent.
    func reconcileAfterLaunchForExternalRetry() async {
        await reconcileAfterLaunch()
    }

    private func reconcileAfterLaunch() async {
        syncStatus = .checking

        // Download any items marked as not downloaded by the OS
        guard let ubiquityURL = ubiquityDocumentsURL() else {
            syncStatus = .error(CloudSyncError.iCloudUnavailable.localizedDescription)
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
        syncStatus = .checking
        // Single NSMetadataQuery passes are snapshots — a file that is
        // 75% uploaded at gather time leaves the status frozen at
        // `.syncing(0.75)` forever. Re-poll until iCloud reports every
        // item `.current`, so the indicator actually advances to
        // `.upToDate`. Capped so a perpetually-stalled upload can't
        // spin the loop indefinitely.
        var passes = 0
        let maxPasses = 40
        while passes < maxPasses {
            passes += 1
            let stillSyncing = await runSingleMetadataPass()
            if !stillSyncing { return }
            try? await Task.sleep(for: .seconds(1.5))
        }
        // Re-poll budget exhausted — iCloud is taking unusually long
        // (or the simulator's metadata never settles). Resolve to a
        // resting state instead of leaving the indicator spinning
        // forever; a later `syncNow()` will re-check.
        if case .syncing = syncStatus { syncStatus = .upToDate }
        if case .checking = syncStatus { syncStatus = .upToDate }
    }

    /// Runs one NSMetadataQuery gather and folds the result into
    /// `syncStatus`. Returns `true` while items are still in flight.
    private func runSingleMetadataPass() async -> Bool {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            (ubiquityDocumentsURL()?.appendingPathComponent("Notebooks").path ?? "")
        )
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]

        // Single-shot query — gather results synchronously via a continuation.
        // NSMetadataQuery is non-Sendable; the addObserver block is @Sendable.
        // Wrap the query and the observer token in @unchecked Sendable boxes so
        // the closure captures compile under Swift 6, and hop to @MainActor
        // before touching MainActor-isolated state on `self`.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let queryBox    = _MetadataQueryBox(query)
            let observerBox = _ObserverTokenBox()
            observerBox.token = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: queryBox.query,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    queryBox.query.stop()
                    if let o = observerBox.token {
                        NotificationCenter.default.removeObserver(o)
                    }
                    let stillSyncing = self?.processQueryResults(queryBox.query) ?? false
                    continuation.resume(returning: stillSyncing)
                }
            }
            OperationQueue.main.addOperation { queryBox.query.start() }
        }
    }

    /// Folds query results into `syncStatus`; returns `true` while
    /// items remain in flight.
    @MainActor
    @discardableResult
    private func processQueryResults(_ query: NSMetadataQuery) -> Bool {
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
            return true
        } else {
            // Light tap on first transition to upToDate from a non-idle state.
            let wasSyncing: Bool = {
                if case .syncing = syncStatus { return true }
                if case .checking = syncStatus { return true }
                return false
            }()
            syncStatus = .upToDate
            markSyncCompleted()
#if os(iOS)
            if wasSyncing { HapticManager.shared.iCloudSyncCompleted() }
#endif
            return false
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

// MARK: - Sendable boxes
//
// Two concrete (non-generic) wrappers rather than one generic class.
// The generic _UnsafeSendableBox<T> caused a swift-frontend crash in
// Release builds: the EarlyPerfInliner pass segfaulted while inlining
// the synthesised deinit (Swift 6.3.2 / Xcode 26). Concrete classes
// avoid that optimizer path entirely.
//
// **Queue contract.** Both boxes are accessed exclusively from main —
// the query is started via `OperationQueue.main.addOperation` and its
// `NSMetadataQueryDidFinishGathering` observer is registered with
// `queue: .main`. The single token write happens immediately after
// `addObserver` returns (same main-actor frame); the read happens
// inside the observer callback (also main). The `@unchecked Sendable`
// is therefore correct *as long as the surrounding call site stays
// main-actor isolated*. If a future change starts the query from a
// background queue or moves the observer to a non-main queue, the
// `nonisolated(unsafe) var token` write/read would race — at that
// point the box needs a proper lock or the access needs to move
// inside an actor. Calling out the contract here so the next
// audit doesn't flag the box without context.

private final class _MetadataQueryBox: @unchecked Sendable {
    nonisolated(unsafe) let query: NSMetadataQuery
    nonisolated init(_ query: NSMetadataQuery) { self.query = query }
}

private final class _ObserverTokenBox: @unchecked Sendable {
    nonisolated(unsafe) var token: NSObjectProtocol?
    nonisolated init() {}
}
