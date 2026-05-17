import Foundation

public enum CeciliasNotesStorageError: LocalizedError {
    case modelContextUnavailable
    case fileWriteFailed(Error)
    case fileSizeLimitExceeded
    case pageNumberInvalid
    case notebookNotFound
    case attachmentFileMissing

    public var errorDescription: String? {
        switch self {
        case .modelContextUnavailable:
            return "The data store is unavailable. Please restart Ink."
        case .fileWriteFailed(let underlying):
            return "A file could not be written: \(underlying.localizedDescription)"
        case .fileSizeLimitExceeded:
            return "The file exceeds the maximum allowed size."
        case .pageNumberInvalid:
            return "The specified page number is out of range."
        case .notebookNotFound:
            return "The notebook could not be found."
        case .attachmentFileMissing:
            return "The attachment file is missing from storage."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .modelContextUnavailable:
            return "Force-quit Ink and reopen it."
        case .fileWriteFailed:
            return "Check that the device has available storage."
        case .fileSizeLimitExceeded:
            return "Choose a smaller file and try again."
        case .pageNumberInvalid:
            return "The notebook page structure may be corrupted. Try reopening the notebook."
        case .notebookNotFound:
            return "The notebook may have been deleted."
        case .attachmentFileMissing:
            return "The original file may have been removed from device storage."
        }
    }
}
