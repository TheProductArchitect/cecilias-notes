import Foundation

/// Helpers for inspecting + nudging the iCloud Drive state of a
/// single file. Step 10 — the per-file complement to
/// `CloudSyncManager`'s aggregate progress (which observes ubiquity
/// documents globally). Used by the per-element media loaders
/// (`ImageDataView`, `PDFPageDataView`, `AudioElementView`) to show
/// "downloading from iCloud…" instead of a generic
/// missing-file placeholder when the SwiftData record has synced
/// down before the underlying file bytes have.
enum UbiquitousFileStatus {

    /// Per-file state the media loaders render against.
    enum State: Equatable {
        case local                       // file exists on disk, ready to load
        case downloading(progress: Double?)  // file in iCloud, transferring; progress is nil until first poll
        case notUbiquitous               // file is neither local nor in iCloud — genuine missing
    }

    /// Cheap, synchronous read of the current state. Reads the
    /// `URLResourceValues.ubiquitousItemDownloadingStatus` +
    /// `ubiquitousItemDownloadingError` keys. Returns `.local`
    /// when the file is plainly present on disk and not flagged as
    /// ubiquitous-only.
    static func currentState(at url: URL) -> State {
        let fm = FileManager.default
        // Fast path — file is on disk and openable. Covers both
        // non-iCloud notebooks and iCloud files that have already
        // downloaded.
        if fm.fileExists(atPath: url.path) {
            // Even if the file exists locally, it could still be a
            // ubiquity stub (placeholder file). Check the ubiquity
            // status key before returning `.local`.
            if let values = try? url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .fileSizeKey
            ]),
            let status = values.ubiquitousItemDownloadingStatus {
                switch status {
                case .current, .downloaded:
                    return .local
                case .notDownloaded:
                    return .downloading(progress: nil)
                default:
                    return .local
                }
            }
            return .local
        }

        // File doesn't exist locally. The metadata-only stub iOS
        // leaves behind for not-yet-downloaded ubiquity files lives
        // alongside the would-be filename with a `.icloud` suffix
        // — its presence signals "downloadable". Anything else is
        // a genuine missing file.
        let stubURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fm.fileExists(atPath: stubURL.path) {
            return .downloading(progress: nil)
        }
        return .notUbiquitous
    }

    /// Kick the download for an iCloud file. No-op if the file is
    /// already local. Returns `true` if a download was requested
    /// (caller should poll for completion).
    @discardableResult
    static func requestDownload(at url: URL) -> Bool {
        let state = currentState(at: url)
        guard case .downloading = state else { return false }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// Poll the file's download progress percentage (0..1).
    /// Returns `nil` when the file's state isn't readable as a
    /// ubiquity download. Cheap enough to call on a 1-second
    /// polling loop while the user looks at the placeholder.
    static func downloadProgress(at url: URL) -> Double? {
        guard let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey
        ]) else { return nil }
        if let status = values.ubiquitousItemDownloadingStatus,
           status == .current || status == .downloaded {
            return 1.0
        }
        // The system doesn't expose a per-file percentage on the
        // basic URLResourceValues surface — `CloudSyncManager`
        // observes that via NSMetadataQuery. For the per-file
        // loader an indeterminate progress is the honest answer;
        // we return nil and the UI shows a spinner.
        return nil
    }
}
