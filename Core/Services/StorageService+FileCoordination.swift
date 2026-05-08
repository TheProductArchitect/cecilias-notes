import Foundation

// MARK: - StorageService + NSFileCoordinator
//
// When iCloud Drive is enabled, the Notebooks asset directory lives inside the
// ubiquity container. Writes to ubiquity-backed files **must** be coordinated
// through `NSFileCoordinator` — otherwise the iCloud daemon can read partial
// data while we're mid-write, and remote-edit conflicts are silently lost.
//
// These helpers are no-ops when iCloud is disabled (we just write directly to
// Application Support), so call sites can use them unconditionally.

extension StorageService {

    /// True iff `notebooksDirectoryURL` currently resolves to an iCloud ubiquity path.
    static var isUsingiCloudStorage: Bool {
        let enabled = UserDefaults.standard.bool(forKey: "ink.icloud.sync.enabled")
        guard enabled else { return false }
        return FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
    }

    /// Atomically writes data to a URL. Coordinates through NSFileCoordinator
    /// when the destination is in the iCloud container.
    static func writeFile(_ data: Data, to url: URL) throws {
        guard isUsingiCloudStorage, url.path.contains("/Documents/Notebooks/") else {
            try data.write(to: url, options: .atomic)
            return
        }
        var coordinatorError: NSError?
        var writeError:       Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forReplacing,
            error: &coordinatorError
        ) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let err = coordinatorError ?? writeError { throw err }
    }

    /// Coordinated copy. Use whenever the destination is in iCloud (or might be).
    static func copyFile(at source: URL, to destination: URL) throws {
        guard isUsingiCloudStorage, destination.path.contains("/Documents/Notebooks/") else {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        var coordinatorError: NSError?
        var copyError:        Error?
        NSFileCoordinator().coordinate(
            readingItemAt: source, options: .withoutChanges,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinatorError
        ) { readURL, writeURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: writeURL)
            } catch {
                copyError = error
            }
        }
        if let err = coordinatorError ?? copyError { throw err }
    }

    /// Coordinated remove. Pairs with the writes above.
    static func removeFile(at url: URL) throws {
        guard isUsingiCloudStorage, url.path.contains("/Documents/Notebooks/") else {
            try FileManager.default.removeItem(at: url)
            return
        }
        var coordinatorError: NSError?
        var removeError:      Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forDeleting,
            error: &coordinatorError
        ) { deleteURL in
            do {
                try FileManager.default.removeItem(at: deleteURL)
            } catch {
                removeError = error
            }
        }
        if let err = coordinatorError ?? removeError { throw err }
    }
}
