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

        guard let topVC = Self.topmostViewController() else {
            #if DEBUG
            print("[ImageInsert] presenter: no topmost VC reachable — cancelling")
            #endif
            onCancel()
            return
        }
        #if DEBUG
        print("[ImageInsert] presenter: presenting PHPickerViewController on \(type(of: topVC))")
        #endif
        topVC.present(picker, animated: true)
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
            print("[ImageInsert] camera presenter: source unavailable → onCancel")
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

        guard let topVC = Self.topmostViewController() else {
            #if DEBUG
            print("[ImageInsert] camera presenter: no topmost VC reachable — cancelling")
            #endif
            onCancel()
            return
        }
        #if DEBUG
        print("[ImageInsert] camera presenter: presenting UIImagePickerController on \(type(of: topVC))")
        #endif
        topVC.present(picker, animated: true)
    }

    // MARK: - Internals

    private static var delegateAssociationKey: UInt8 = 0
    private static var cameraDelegateAssociationKey: UInt8 = 0

    /// Walks the application's window scene + presented-VC chain to
    /// find the deepest currently-visible view controller. Picker
    /// `present` is called on this.
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
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
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
            print("[ImageInsert] presenter: results empty → onCancel")
            #endif
            DispatchQueue.main.async { [onCancel] in onCancel() }
            return
        }

        // Load each result's image off the main thread; the loader
        // emits on an arbitrary queue. Use a counter + final
        // completion to wait for all loads before firing.
        let group     = DispatchGroup()
        var picked    = [UIImage]()
        let pickedLock = NSLock()

        for result in results {
            guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else { continue }
            group.enter()
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                defer { group.leave() }
                guard let image = object as? UIImage else { return }
                pickedLock.lock()
                picked.append(image)
                pickedLock.unlock()
            }
        }

        group.notify(queue: .main) { [completion] in
            #if DEBUG
            print("[ImageInsert] presenter: loaded \(picked.count) image(s), firing completion")
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
