import SwiftUI
import PhotosUI
import VisionKit
import UniformTypeIdentifiers

// MARK: - PhotoLibraryPicker

struct PhotoLibraryPicker: UIViewControllerRepresentable {

    let onPick: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 10
        config.filter = .images
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([UIImage]) -> Void
        init(onPick: @escaping ([UIImage]) -> Void) { self.onPick = onPick }

        // DISMISSAL RULE for every picker in this file: never call
        // `dismiss(animated:)` from a delegate. These representables
        // are the CONTENT of the editor's SwiftUI `.sheet` — a UIKit
        // dismissal races SwiftUI's presentation bookkeeping, and
        // when the picker ALSO dismisses itself (VNDocumentCamera
        // does on camera-service failure — the Fig err=-17281 storm
        // in the 2026-07-18 device log) the second dismiss climbs
        // the presentation chain and pops the editor's
        // fullScreenCover: "after scanning an image the notebook
        // went back to home screen". Every completion/cancel path
        // clears `activeMediaSource`, and THAT is what dismisses
        // the sheet.
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                // PHPicker signals cancel as empty results; route it
                // through onPick so `activeMediaSource` still clears
                // and the sheet closes.
                onPick([])
                return
            }
            // PHPicker callbacks fire on arbitrary threads. A
            // captured-var accumulator trips Swift 6 even with an
            // external lock; route through a reference-typed box
            // whose mutation is guarded internally.
            let box = _PHPickerImageBox()
            let group = DispatchGroup()
            for result in results {
                let provider = result.itemProvider
                if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { obj, _ in
                        if let img = obj as? UIImage { box.append(img) }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { [weak self] in
                self?.onPick(box.snapshot())
            }
        }
    }
}

// MARK: - FilesPicker

struct FilesPicker: UIViewControllerRepresentable {

    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.image, .pdf]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

// MARK: - CameraPicker

struct CameraPicker: UIViewControllerRepresentable {

    let onPick: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType   = .camera
        picker.allowsEditing = false
        picker.delegate     = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // No UIKit dismiss — see the dismissal rule above.
            if let img = info[.originalImage] as? UIImage {
                onPick(img)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

// MARK: - DocumentScannerPicker

struct DocumentScannerPicker: UIViewControllerRepresentable {

    let onScan: (VNDocumentCameraScan) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: (VNDocumentCameraScan) -> Void
        let onCancel: () -> Void
        init(onScan: @escaping (VNDocumentCameraScan) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan; self.onCancel = onCancel
        }

        // No UIKit dismiss in any callback — see the dismissal rule
        // at the top of the file. The failure path is the one that
        // bit: VNDocumentCamera dismisses ITSELF when the capture
        // service dies, and our extra dismiss then popped the
        // editor's cover.
        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            onScan(scan)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            #if DEBUG
            dlog("[ImageInsert] scanner didFailWithError: \(error)")
            #endif
            onCancel()
        }
    }
}

// MARK: - PHPicker image accumulator

/// Lock-guarded image accumulator for PHPicker results. Swift 6 can't
/// prove an external NSLock guards a captured `var`, so each
/// `loadObject` callback writes through this reference box instead.
private nonisolated final class _PHPickerImageBox: @unchecked Sendable {
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
