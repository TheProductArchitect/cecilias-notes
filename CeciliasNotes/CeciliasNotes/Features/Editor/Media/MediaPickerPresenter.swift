/// MediaPickerPresenter.swift
/// Cecilia's Notes
///
/// UIKit-direct presentation of `PHPickerViewController` for the
/// toolbar's "+ Image" action. Bypasses SwiftUI's presentation
/// system entirely.
///
/// **Why this exists:** every prior attempt to present the photo
/// picker through SwiftUI (`.sheet(item:)` on `EditorView`,
/// `.sheet(item:)` on `LibraryView`) ran into a different limitation
/// of SwiftUI's presentation rules:
///
///   1. Editor's `.sheet` inside the `.fullScreenCover`: dismissing
///      the picker popped the cover with it.
///   2. Library's `.sheet` at root: iOS rejected the present because
///      the editor's `.fullScreenCover` was already counted as an
///      active presentation, with the console message
///      "Currently, only presenting a single sheet is supported".
///
/// Walking the responder chain to the topmost presented
/// `UIViewController` and calling `present` directly on it sidesteps
/// SwiftUI's accounting entirely. The picker lands on top of
/// whatever's currently visible (the editor cover, the library, a
/// settings sheet) and dismisses cleanly without affecting any of
/// them.
///
/// **Lifetime:** the picker's delegate is the only retainer of the
/// completion / cancel closures. Because UIKit doesn't retain
/// `picker.delegate` strongly, we attach it via
/// `objc_setAssociatedObject` on the picker itself — the delegate
/// then lives exactly as long as the picker is in the view hierarchy.

import ObjectiveC.runtime
import PhotosUI
import UIKit
import UniformTypeIdentifiers

enum MediaPickerPresenter {

    /// Present a `PHPickerViewController` on the topmost VC.
    /// `completion` fires once with the picked `UIImage`s (empty
    /// array allowed — caller decides if that should be treated as
    /// a cancel). `onCancel` fires when the user dismisses without
    /// picking. Both run on the main thread.
    static func presentPhotoPicker(
        completion: @escaping ([UIImage]) -> Void,
        onCancel:   @escaping () -> Void
    ) {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0       // 0 = unlimited
        config.filter         = .images

        let picker   = PHPickerViewController(configuration: config)
        let delegate = PhotoPickerDelegate(
            completion: completion,
            onCancel:   onCancel
        )
        picker.delegate = delegate
        // Retain the delegate for the lifetime of the picker. UIKit
        // holds `delegate` weakly; without this association the
        // delegate deallocates the moment this scope returns and
        // the picker callback never fires.
        objc_setAssociatedObject(
            picker,
            &Self.delegateAssociationKey,
            delegate,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        Self.presentOnTopmost(picker, debugTag: "PHPickerViewController", onUnavailable: onCancel)
    }

    /// Present the system camera (`UIImagePickerController` with
    /// `sourceType = .camera`) on the topmost VC. Used by the
    /// toolbar's long-press-on-gallery gesture for a quick capture.
    /// Same lifetime model as `presentPhotoPicker` — delegate is
    /// associated to the picker so it lives exactly as long as the
    /// picker is on screen.
    ///
    /// Falls through to `onCancel` immediately if the camera is
    /// unavailable (simulator, device without a camera, restricted
    /// by parental controls).
    static func presentCamera(
        completion: @escaping (UIImage) -> Void,
        onCancel:   @escaping () -> Void
    ) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            #if DEBUG
            dlog("[ImageInsert] camera presenter: source unavailable → onCancel")
            #endif
            onCancel()
            return
        }
        let picker            = UIImagePickerController()
        picker.sourceType     = .camera
        picker.allowsEditing  = false
        picker.cameraCaptureMode = .photo
        let delegate = CameraPickerDelegate(
            completion: completion,
            onCancel:   onCancel
        )
        picker.delegate = delegate
        objc_setAssociatedObject(
            picker,
            &Self.cameraDelegateAssociationKey,
            delegate,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        Self.presentOnTopmost(picker, debugTag: "UIImagePickerController(.camera)", onUnavailable: onCancel)
    }

    /// Present a `UIDocumentPickerViewController` scoped to PDF
    /// content. Same UIKit-direct + hardened topmost-VC walk as
    /// the photo / camera entry points — bypasses SwiftUI's
    /// `.fileImporter`, which Step 7.2 device-test surfaced as
    /// flaky when the editor cover's hosting controller is
    /// mid-transition.
    static func presentPDFDocumentPicker(
        completion: @escaping (URL) -> Void,
        onCancel:   @escaping () -> Void
    ) {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.pdf],
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        let delegate = DocumentPickerDelegate(
            completion: completion,
            onCancel:   onCancel
        )
        picker.delegate = delegate
        objc_setAssociatedObject(
            picker,
            &Self.documentDelegateAssociationKey,
            delegate,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        Self.presentOnTopmost(picker, debugTag: "UIDocumentPickerViewController(.pdf)", onUnavailable: onCancel)
    }

    // MARK: - Internals

    private static var delegateAssociationKey: UInt8 = 0
    private static var cameraDelegateAssociationKey: UInt8 = 0
    private static var documentDelegateAssociationKey: UInt8 = 0

    /// Defers the actual `present(_:animated:)` by one runloop tick
    /// so SwiftUI's hosting-controller graph has settled before
    /// UIKit checks "is the presenting VC's view in the window
    /// hierarchy?". Step 7.2 device-test surfaced a reproducible
    /// failure where the topmost VC at notification-handler time
    /// was a stale `PresentationHostingController` mid-transition;
    /// without the defer + window check, iOS rejected the present
    /// and PHPicker fired `didFinishPicking` with empty results,
    /// which the cancel path then surfaced as "user dismissed."
    ///
    /// Also re-validates the topmost VC at present-time (not at
    /// notification-handler time) and walks the chain filtering
    /// out detached VCs (`view.window == nil`).
    private static func presentOnTopmost(
        _ picker: UIViewController,
        debugTag: String,
        onUnavailable: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            guard let topVC = Self.topmostViewController() else {
                #if DEBUG
                dlog("[ImageInsert] presenter: no topmost VC reachable for \(debugTag) — cancelling")
                #endif
                onUnavailable()
                return
            }
            #if DEBUG
            dlog("[ImageInsert] presenter: presenting \(debugTag) on \(type(of: topVC))")
            #endif
            topVC.present(picker, animated: true)
        }
    }

    /// Walks the application's window scene + presented-VC chain to
    /// find the deepest currently-visible view controller. Picker
    /// `present` is called on this.
    ///
    /// Step 7.2 hardening: each step in the walk must be attached
    /// to a window. A SwiftUI `PresentationHostingController`
    /// mid-dismiss-transition keeps a non-nil `presentedViewController`
    /// pointer for one runloop tick even though its `view.window`
    /// has already gone nil — calling `present(_:)` on that stale
    /// VC produced the "whose view is not in the window hierarchy"
    /// error users saw. Skip detached VCs and use the last attached
    /// ancestor instead.
    private static func topmostViewController() -> UIViewController? {
        guard let scene = UIApplication.shared
            .connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared
                    .connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first
        else { return nil }
        guard let root = scene.keyWindow?.rootViewController
                    ?? scene.windows.first?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController,
              !presented.isBeingDismissed,
              presented.view.window != nil {
            top = presented
        }
        // Defence-in-depth: if `top` itself ended up detached
        // (root retained a stale presentation), fall back to root.
        if top.view.window == nil { return root }
        return top
    }
}

// MARK: - PhotoPickerDelegate

/// Adapts `PHPickerViewControllerDelegate` to plain closures. Loads
/// each `PHPickerResult` to a `UIImage` on the picker's image
/// loader queue, collects the results, then dispatches the
/// completion on main.
private final class PhotoPickerDelegate: NSObject, PHPickerViewControllerDelegate {

    let completion: ([UIImage]) -> Void
    let onCancel:   () -> Void
    private var hasFired = false

    init(
        completion: @escaping ([UIImage]) -> Void,
        onCancel:   @escaping () -> Void
    ) {
        self.completion = completion
        self.onCancel   = onCancel
    }

    func picker(
        _ picker: PHPickerViewController,
        didFinishPicking results: [PHPickerResult]
    ) {
        // Single-shot guard — `picker(_:didFinishPicking:)` is the
        // only delegate call, but in case any future iOS version
        // re-fires it on dismiss (the way `imagePickerControllerDidCancel`
        // sometimes did historically), don't double-deliver.
        guard !hasFired else { return }
        hasFired = true

        picker.dismiss(animated: true)

        guard !results.isEmpty else {
            // Empty results = user dismissed without picking. This
            // is the cancel path on PHPicker (there's no separate
            // delegate call for cancel).
            #if DEBUG
            dlog("[ImageInsert] presenter: results empty → onCancel")
            #endif
            DispatchQueue.main.async { [onCancel] in onCancel() }
            return
        }

        // Load each result's image off the main thread; the loader
        // emits on an arbitrary queue. Use a counter + final
        // completion to wait for all loads before firing.
        // Under Swift 6 a captured `var` in a `@Sendable` closure is
        // a race even with an external NSLock — the compiler can't
        // prove the lock guards the storage. Wrap the accumulator in
        // a reference-typed actor-bounded box so each callback sees
        // the same instance instead of capturing the var.
        let group = DispatchGroup()
        let pickedBox = _PickedImagesBox()

        for result in results {
            guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else { continue }
            group.enter()
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                defer { group.leave() }
                guard let image = object as? UIImage else { return }
                pickedBox.append(image)
            }
        }

        group.notify(queue: .main) { [completion] in
            let picked = pickedBox.snapshot()
            #if DEBUG
            dlog("[ImageInsert] presenter: loaded \(picked.count) image(s), firing completion")
            #endif
            completion(picked)
        }
    }
}

// MARK: - CameraPickerDelegate

/// Adapts `UIImagePickerControllerDelegate` to plain closures for
/// the camera-capture path. Single-shot — once the user takes a
/// photo OR cancels, the delegate fires exactly once and the picker
/// dismisses.
private final class CameraPickerDelegate: NSObject,
                                          UIImagePickerControllerDelegate,
                                          UINavigationControllerDelegate {
    let completion: (UIImage) -> Void
    let onCancel:   () -> Void
    private var hasFired = false

    init(
        completion: @escaping (UIImage) -> Void,
        onCancel:   @escaping () -> Void
    ) {
        self.completion = completion
        self.onCancel   = onCancel
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
    ) {
        guard !hasFired else { return }
        hasFired = true
        let image = (info[.originalImage] as? UIImage)
        picker.dismiss(animated: true) { [completion, onCancel] in
            if let image {
                completion(image)
            } else {
                onCancel()
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        guard !hasFired else { return }
        hasFired = true
        picker.dismiss(animated: true) { [onCancel] in onCancel() }
    }
}

// MARK: - DocumentPickerDelegate

/// Adapts `UIDocumentPickerDelegate` to plain closures for the PDF
/// document-picker path. Single-shot — fires exactly once on pick
/// or cancel and dismisses itself.
private final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let completion: (URL) -> Void
    let onCancel:   () -> Void
    private var hasFired = false

    init(
        completion: @escaping (URL) -> Void,
        onCancel:   @escaping () -> Void
    ) {
        self.completion = completion
        self.onCancel   = onCancel
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard !hasFired else { return }
        hasFired = true
        let url = urls.first
        controller.dismiss(animated: true) { [completion, onCancel] in
            if let url {
                completion(url)
            } else {
                onCancel()
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !hasFired else { return }
        hasFired = true
        controller.dismiss(animated: true) { [onCancel] in onCancel() }
    }
}

// MARK: - Image accumulator

/// Thread-safe collector for PHPicker image loads. The completions
/// callback on arbitrary background threads, so the storage is
/// guarded by an internal lock and the type is `@unchecked Sendable`
/// — the lock is the actual safety guarantee.
private nonisolated final class _PickedImagesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [UIImage] = []

    init() {}

    func append(_ image: UIImage) {
        lock.lock()
        defer { lock.unlock() }
        images.append(image)
    }

    func snapshot() -> [UIImage] {
        lock.lock()
        defer { lock.unlock() }
        return images
    }
}
