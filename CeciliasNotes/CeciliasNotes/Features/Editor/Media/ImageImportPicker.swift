/// ImageImportPicker.swift
/// Cecilia's Notes
///
/// Source-of-image picker for the image attachment feature. Three
/// rows: Camera, Photo Library, Files. Each presents its own
/// UIKit-backed picker; on selection the host receives a `UIImage`
/// + an optional file extension hint so it can write the bytes to
/// `Documents/media/<notebookId>/<uuid>.<ext>` and create the
/// corresponding `MediaAttachmentRecord`.
///
/// All three pickers run locally — Camera writes through
/// AVFoundation, Photo Library uses PhotosUI, Files uses
/// UIDocumentPickerViewController against the local-only document
/// browser. Nothing goes to the network.

import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - ImageImportPicker (entry sheet)

/// SwiftUI wrapper that surfaces the three import options as a
/// `confirmationDialog`. Selecting a row dismisses the dialog and
/// presents the corresponding UIKit picker via a child sheet.
struct ImageImportPicker: View {

    @Binding var isPresented: Bool
    /// Called with the chosen image + a file-extension hint
    /// ("jpg" / "png" / "heic"). The hint drives the on-disk
    /// filename when the host writes the bytes; if the picker
    /// can't determine the extension it returns "jpg".
    let onPicked: (UIImage, String) -> Void
    /// Called when the user dismisses the source-choice dialog
    /// or a sub-picker without picking an image. The parent uses
    /// this to clear `imageImportRequest` — without it the
    /// sheet's `.sheet(item:)` binding would stay populated and
    /// block a fresh tap from re-presenting.
    var onCancel: () -> Void = {}

    @State private var presenting: Source?

    private enum Source: Identifiable {
        case camera, photos, files
        var id: Int { hashValue }
    }

    var body: some View {
        Color.clear
            .confirmationDialog(
                "Insert image",
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                Button {
                    presenting = .camera
                } label: {
                    Label("Camera", systemImage: "camera")
                }
                Button {
                    presenting = .photos
                } label: {
                    Label("Photo Library", systemImage: "photo")
                }
                Button {
                    presenting = .files
                } label: {
                    Label("Files", systemImage: "folder")
                }
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
            }
            .sheet(item: $presenting) { source in
                pickerFor(source)
            }
    }

    @ViewBuilder
    private func pickerFor(_ source: Source) -> some View {
        // Every sub-picker's coordinator delivers `nil` on
        // cancel and a `UIImage` on success. The host sheet's
        // `imageImportRequest` is cleared either via `onPicked`
        // (success) or `onCancel` (user dismissed) — never
        // via `.onDisappear`, which was the source of the
        // notebook-collapse bug.
        switch source {
        case .camera:
            IICameraPicker { image in
                presenting = nil
                if let image {
                    onPicked(image, "jpg")
                } else {
                    onCancel()
                }
            }
            .ignoresSafeArea()
        case .photos:
            IIPhotosPicker(
                selectionLimit: 1,
                filter: .images
            ) { image, ext in
                presenting = nil
                if let image {
                    onPicked(image, ext)
                } else {
                    onCancel()
                }
            }
            .ignoresSafeArea()
        case .files:
            IIFilesPicker { image, ext in
                presenting = nil
                if let image {
                    onPicked(image, ext)
                } else {
                    onCancel()
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Camera

private struct IICameraPicker: UIViewControllerRepresentable {
    let onResult: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onResult: (UIImage?) -> Void
        init(onResult: @escaping (UIImage?) -> Void) { self.onResult = onResult }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            picker.dismiss(animated: true) { self.onResult(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { self.onResult(nil) }
        }
    }
}

// MARK: - Photo Library

private struct IIPhotosPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let filter: PHPickerFilter
    let onResult: (UIImage?, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = selectionLimit
        config.filter         = filter
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onResult: (UIImage?, String) -> Void
        init(onResult: @escaping (UIImage?, String) -> Void) { self.onResult = onResult }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                picker.dismiss(animated: true) { self.onResult(nil, "jpg") }
                return
            }
            // PHPicker returns the typeIdentifiers in priority
            // order; pull the extension from the first match so
            // HEIC stays HEIC, PNG stays PNG, etc.
            let ext = Self.fileExtension(from: provider.registeredTypeIdentifiers)
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                DispatchQueue.main.async {
                    picker.dismiss(animated: true) { self.onResult(image, ext) }
                }
            }
        }

        private static func fileExtension(from typeIdentifiers: [String]) -> String {
            for id in typeIdentifiers {
                if let utType = UTType(id) {
                    if utType.conforms(to: .png)  { return "png" }
                    if utType.conforms(to: .heic) { return "heic" }
                    if utType.conforms(to: .tiff) { return "tiff" }
                    if utType.conforms(to: .jpeg) { return "jpg" }
                }
            }
            return "jpg"
        }
    }
}

// MARK: - Files

private struct IIFilesPicker: UIViewControllerRepresentable {
    let onResult: (UIImage?, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.image, .jpeg, .png, .heic, .tiff]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onResult: (UIImage?, String) -> Void
        init(onResult: @escaping (UIImage?, String) -> Void) { self.onResult = onResult }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                controller.dismiss(animated: true) { self.onResult(nil, "jpg") }
                return
            }
            // Files picker hands us a security-scoped URL — bracket
            // the read with start/stop or `loadDataRepresentation`
            // will fail silently for items outside our sandbox.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try? Data(contentsOf: url)
            let image = data.flatMap { UIImage(data: $0) }
            let ext = (url.pathExtension.lowercased().isEmpty ? "jpg" : url.pathExtension.lowercased())
            controller.dismiss(animated: true) { self.onResult(image, ext) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            controller.dismiss(animated: true) { self.onResult(nil, "jpg") }
        }
    }
}
