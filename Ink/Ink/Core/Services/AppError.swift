import Foundation

// MARK: - AppError

/// User-facing error type for the few moments where Ink absolutely needs to
/// tell the user something went wrong.
///
/// Cases name the *user-visible action* (not the underlying API), so view
/// models can pass through an `Error` from storage / printing without leaking
/// internal SwiftData / PencilKit detail into the UI.
///
/// Bucket 8 (#43) will expand `human(_:)` into a richer mapping for known
/// network / file-system / iCloud codes. For now this is the minimal set
/// needed by Bucket 2 (#4 print, #42 storage mutations).
enum AppError: LocalizedError, Equatable {

    /// Exporting the notebook for `UIPrintInteractionController` failed.
    case printFailed(underlying: Error)

    /// A storage mutation failed. `action` is a human-readable verb phrase
    /// (e.g. "rename notebook", "delete page") used in the message.
    case storageFailed(action: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .printFailed(let err):
            return "Couldn't prepare the document for printing. \(human(err))"
        case .storageFailed(let action, let err):
            return "Couldn't \(action). \(human(err))"
        }
    }

    private func human(_ error: Error) -> String {
        AppError.humanize(error)
    }

    /// Map a raw `Error` from Foundation / iCloud / Cocoa file APIs to a
    /// human-readable, action-oriented sentence.
    static func humanize(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain:
            switch ns.code {
            case NSURLErrorNotConnectedToInternet:
                return "You're offline. Connect to the internet and try again."
            case NSURLErrorTimedOut:
                return "The request took too long. Try again."
            case NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorNetworkConnectionLost:
                return "We couldn't reach the server. Try again in a moment."
            default:
                break
            }

        case NSCocoaErrorDomain:
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "We couldn't find that file. It may have been moved or deleted."
            case NSFileWriteOutOfSpaceError:
                return "Your device is out of storage. Free up space and try again."
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "Permission was denied for that file."
            case NSUserCancelledError:
                return "Cancelled."
            default:
                break
            }

        case "CKErrorDomain":
            // CloudKit error codes — match by raw code to avoid importing CloudKit
            // here. See CKError.Code in the SDK for the source of truth.
            switch ns.code {
            case 1:  return "You're not signed in to iCloud. Sign in and try again."
            case 4:  return "iCloud is unavailable right now. Try again later."
            case 7:  return "iCloud is out of storage. Free up space and try again."
            case 14: return "We need permission to use iCloud. Check iCloud settings."
            default: break
            }

        default:
            break
        }
        return error.localizedDescription
    }

    /// Wrap any Error in an AppError. Defaults to `.storageFailed`
    /// with a generic action; pass a more specific case directly when possible.
    static func from(_ error: Error, action: String = "complete that action") -> AppError {
        if let app = error as? AppError { return app }
        return .storageFailed(action: action, underlying: error)
    }

    static func == (lhs: AppError, rhs: AppError) -> Bool {
        switch (lhs, rhs) {
        case (.printFailed, .printFailed):   return true
        case (.storageFailed(let a, _), .storageFailed(let b, _)): return a == b
        default: return false
        }
    }
}
