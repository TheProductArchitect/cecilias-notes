import Combine
@preconcurrency import CoreGraphics
import Foundation
import PhotosUI
import SwiftData
import UIKit
import VisionKit
import UniformTypeIdentifiers
@preconcurrency import PDFKit

// MARK: - MediaSource

enum MediaSource: Identifiable {
    case photos
    case files
    case camera
    case scan

    var id: String { "\(self)" }
}

// MARK: - MediaInsertCoordinator

/// Drives all four media insertion flows. Held by EditorViewModel.
@MainActor
final class MediaInsertCoordinator: ObservableObject {

    @Published var isProcessing: Bool = false
    @Published var processingProgress: Double = 0

    weak var viewModel: EditorViewModel?

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }

    func insertPhotos() {
        #if DEBUG
        dlog("[ImageInsert] 1. insertPhotos() called — posting imageImportRequested (centre coords)")
        #endif
        // Photo picker is routed through `LibraryView`'s root-level
        // `.sheet(item: $viewModel.pendingImageImport)` rather than
        // the editor's own sheet. Presenting the sheet from inside
        // a `.fullScreenCover` destination causes SwiftUI to pop
        // the destination on dismiss (confirmed by the
        // `[ImageInsert] 3. EditorView.onDisappear fired` line that
        // appears immediately after the picker closes). Routing
        // through the notification → library sheet decouples the
        // picker lifecycle from the editor cover entirely.
        //
        // No specific tap location → default to page centre. The
        // editor's `commitImportedImage` honours this by dropping
        // the image at (0.5, 0.5) of the current page.
        NotificationCenter.default.post(
            name: .imageImportRequested,
            object: nil,
            userInfo: [
                ImageImportUserInfoKey.normalizedX: 0.5,
                ImageImportUserInfoKey.normalizedY: 0.5,
            ]
        )
    }
    // Files / camera / scan still route through `activeMediaSource`
    // and the editor's own `.sheet(item:)`. They use different
    // pickers (`UIDocumentPickerViewController`,
    // `UIImagePickerController` source `.camera`,
    // `VNDocumentCameraViewController`) which aren't wired into the
    // library's `ImageImportPicker` host. If they exhibit the same
    // dismiss-pops-the-cover symptom, they need analogous root-level
    // sheets — separate fix.
    func insertFromFiles() { viewModel?.activeMediaSource = .files }
    func insertFromCamera() { viewModel?.activeMediaSource = .camera }
    func insertScan()      { viewModel?.activeMediaSource = .scan }
    func dismiss()         { viewModel?.activeMediaSource = nil }

    // MARK: - Pipeline entry points

    /// Called by photo picker with selected UIImages.
    func handlePickedImages(_ images: [UIImage]) async {
        #if DEBUG
        dlog("[ImageInsert] 5. handlePickedImages called with \(images.count) image(s); first size=\(images.first?.size ?? .zero)")
        #endif
        guard let vm = viewModel else {
            #if DEBUG
            dlog("[ImageInsert] 5b. handlePickedImages: viewModel is nil — editor was already dismissed before picker returned")
            #endif
            return
        }
        viewModel?.activeMediaSource = nil
        await processAndInsert(images: images.map { .uiImage($0) }, into: vm)
    }

    /// Called by document picker with URLs.
    func handlePickedFileURLs(_ urls: [URL]) async {
        guard let vm = viewModel else { return }
        viewModel?.activeMediaSource = nil
        var inputs: [ImageInput] = []
        for url in urls {
            // `FilesPicker` opens with `asCopy: true`, so the URL is a
            // plain tmp-Inbox copy inside our own sandbox — NOT a
            // security-scoped URL. `startAccessingSecurityScopedResource()`
            // returns false for those, and the old
            // `guard ... else { continue }` silently dropped every
            // picked file (device log: PDF picked → Inbox copy created
            // → no import ever ran). Call it for the URLs that need it,
            // but never gate the read on its result.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                await handlePDF(url: url, viewModel: vm)
            } else {
                inputs.append(.fileURL(url))
            }
        }
        if !inputs.isEmpty {
            await processAndInsert(images: inputs, into: vm)
        }
    }

    /// Called by camera picker with one UIImage.
    func handleCameraImage(_ image: UIImage) async {
        guard let vm = viewModel else { return }
        viewModel?.activeMediaSource = nil
        await processAndInsert(images: [.uiImage(image)], into: vm)
    }

    /// Called by VNDocumentCameraViewController.
    func handleScannedDocument(_ scan: VNDocumentCameraScan) async {
        guard let vm = viewModel else { return }
        // Show the processing HUD BEFORE dismissing the scanner and
        // BEFORE pulling page images. `imageOfPage(at:)` is a heavy
        // synchronous decode; with the camera service already dying
        // (device log: Fig err=-17281 + "quad is nil" × N) doing that
        // loop with no HUD made the app look frozen on scan page 3+.
        isProcessing = true
        processingProgress = 0
        defer { isProcessing = false; processingProgress = 0 }
        viewModel?.activeMediaSource = nil

        // Yield once so SwiftUI can paint the HUD and dismiss the
        // scanner sheet before we start decoding page bitmaps.
        await Task.yield()

        let pageCount = scan.pageCount
        guard pageCount > 0 else { return }

        var images: [UIImage] = []
        images.reserveCapacity(pageCount)
        for i in 0..<pageCount {
            images.append(scan.imageOfPage(at: i))
            processingProgress = Double(i + 1) / Double(pageCount) * 0.35
            // Keep the runloop breathing between large page decodes.
            await Task.yield()
        }
        guard !images.isEmpty else { return }

        let pageSize = vm.currentPage.pageSize.pointSize
        let mediaDir = mediaDirectory(for: vm)

        var processed: [ProcessedImage] = []
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        for (i, img) in images.enumerated() {
            if let result = try? await ImageProcessingService.shared.processImage(.uiImage(img), mediaDir: mediaDir) {
                processed.append(result)
            }
            processingProgress = 0.35 + Double(i + 1) / Double(images.count) * 0.45
        }

        guard !processed.isEmpty else { return }

        // First scanned page → current page.
        let first = processed[0]
        let firstRect = centredRect(for: first.originalSize, pageSize: pageSize)
        saveImageRecord(first, on: vm.currentPage, notebookId: vm.notebook.id,
                        rect: firstRect, pageSize: pageSize,
                        persistImmediately: false, notify: false)

        // Pages 2+ → CONSECUTIVE new pages after the current one,
        // anchor rolling forward per insert. The old no-arg
        // `vm.addPage()` targeted the notebook's LAST page: scan
        // page 2 landed at the end of the document.
        var anchorPageId = vm.currentPage.id
        for (offset, extra) in processed.dropFirst().enumerated() {
            guard let newPage = vm.addPage(afterPageId: anchorPageId) else { continue }
            anchorPageId = newPage.id
            let r = centredRect(for: extra.originalSize, pageSize: pageSize)
            saveImageRecord(extra, on: newPage, notebookId: vm.notebook.id,
                            rect: r, pageSize: pageSize,
                            persistImmediately: false, notify: false)
            processingProgress = 0.80 + Double(offset + 1) / Double(max(processed.count - 1, 1)) * 0.20
            await Task.yield()
        }

        // One save + one overlay refresh for the whole scan — the
        // previous per-page context.save() of multi-MB externalStorage
        // blobs + `.mediaAttachmentsChanged` fan-out blocked the main
        // thread for seconds on 3+ page scans.
        let context = StorageService.shared.context
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[Image] batched scan save failed: \(error)")
            #endif
        }
        NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
        processingProgress = 1
    }

    // MARK: - PDF handling

    private func handlePDF(url: URL, viewModel: EditorViewModel) async {
        guard let doc = PDFDocument(url: url) else {
            viewModel.mediaError = "Couldn't open the PDF."
            return
        }
        let pageCount = doc.pageCount
        guard pageCount > 0 else { return }

        let pageSize = viewModel.currentPage.pageSize.pointSize
        let mediaDir = mediaDirectory(for: viewModel)
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        isProcessing = true
        defer { isProcessing = false; processingProgress = 0 }

        // First SUCCESSFULLY processed page → current page; every
        // subsequent one → consecutive new pages, anchor rolling
        // forward. Keyed on success rather than `i == 0` so a PDF
        // whose first page fails to rasterise doesn't silently drop
        // all the others (the old anchor stayed nil forever).
        var pdfAnchorPageId: UUID?
        for i in 0..<pageCount {
            guard let pdfPage = doc.page(at: i)?.pageRef else { continue }
            if let img = try? await ImageProcessingService.shared.rasterisePDFPage(pdfPage) {
                let input: ImageInput = .uiImage(img)
                if let processed = try? await ImageProcessingService.shared.processImage(input, mediaDir: mediaDir) {
                    // A PDF page IS a page — fill the notebook page
                    // (aspect-fit), unlike photos which land at 60%.
                    let r = fullPageRect(for: processed.originalSize, pageSize: pageSize)

                    if pdfAnchorPageId == nil {
                        pdfAnchorPageId = viewModel.currentPage.id
                        saveImageRecord(processed, on: viewModel.currentPage,
                                        notebookId: viewModel.notebook.id,
                                        rect: r, pageSize: pageSize,
                                        persistImmediately: false, notify: false)
                    } else if let anchor = pdfAnchorPageId,
                              let newPage = viewModel.addPage(afterPageId: anchor) {
                        // Consecutive after the current page — same
                        // rolling-anchor fix as the scan path above.
                        pdfAnchorPageId = newPage.id
                        saveImageRecord(processed, on: newPage,
                                        notebookId: viewModel.notebook.id,
                                        rect: r, pageSize: pageSize,
                                        persistImmediately: false, notify: false)
                    }
                }
            }
            processingProgress = Double(i + 1) / Double(pageCount)
            await Task.yield()
        }
        if pdfAnchorPageId != nil {
            let context = StorageService.shared.context
            do {
                try context.save()
            } catch {
                #if DEBUG
                dlog("[Image] batched PDF save failed: \(error)")
                #endif
            }
            NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
        }
    }

    // MARK: - Main pipeline

    private func processAndInsert(images: [ImageInput], into vm: EditorViewModel) async {
        let pageSize = vm.currentPage.pageSize.pointSize
        let mediaDir = mediaDirectory(for: vm)
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        isProcessing = true
        defer { isProcessing = false; processingProgress = 0 }

        // Process all images in parallel via TaskGroup.
        var results: [ProcessedImage] = []
        let total = images.count
        await withTaskGroup(of: ProcessedImage?.self) { group in
            for input in images {
                group.addTask {
                    try? await ImageProcessingService.shared.processImage(input, mediaDir: mediaDir)
                }
            }
            var count = 0
            for await result in group {
                count += 1
                if let r = result { results.append(r) }
                let c = count
                await MainActor.run { processingProgress = Double(c) / Double(total) }
            }
        }

        guard !results.isEmpty else {
            vm.mediaError = "No images could be processed."
            return
        }

        // Insert cascade: first at centre, each subsequent +16pt right+down.
        // Batch the SwiftData save + overlay notification so multi-select
        // imports don't pay N synchronous externalStorage commits.
        for (i, processed) in results.enumerated() {
            let offset = CGFloat(i) * 16
            var rect   = centredRect(for: processed.originalSize, pageSize: pageSize)
            rect.origin.x = min(rect.origin.x + offset, pageSize.width  - rect.width  - 8)
            rect.origin.y = min(rect.origin.y + offset, pageSize.height - rect.height - 8)
            saveImageRecord(processed, on: vm.currentPage,
                            notebookId: vm.notebook.id,
                            rect: rect, pageSize: pageSize,
                            persistImmediately: false, notify: false)
        }
        let context = StorageService.shared.context
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[Image] batched insert save failed: \(error)")
            #endif
        }
        NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
    }

    // MARK: - Helpers

    /// Phase 5A+5C Step 4: images now live under the unified
    /// `MediaStorage.images/` tree (`Documents/MediaAttachments/images/`)
    /// rather than the per-notebook `notebooks/<uuid>/media/` path.
    /// `MediaAttachmentStore.absoluteURL(for:)` resolves through
    /// `MediaStorage.url(for: .images, id:)`, so file writes must
    /// land there for the renderer to find them. Per-notebook
    /// cleanup is handled by `MediaAttachmentStore.forget(pageIds:)`
    /// which iterates records and deletes each file by id —
    /// per-notebook directory isolation is no longer needed.
    private func mediaDirectory(for vm: EditorViewModel) -> URL {
        MediaStorage.ensureDirectoriesExist()
        return MediaStorage.directory(for: .images)
    }

    /// Aspect-fit `imageSize` to the FULL page, centred. Used for
    /// imported PDF pages, which should read as the page itself —
    /// the photo-style 60% `centredRect` made every Files-app PDF
    /// import land as a small floating image in the page centre.
    /// A4-ish PDFs on A4-ish notebook pages fill edge to edge;
    /// mismatched aspects (landscape slides on portrait pages)
    /// letterbox rather than distort.
    private func fullPageRect(for imageSize: CGSize, pageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: pageSize)
        }
        let scale = min(pageSize.width / imageSize.width,
                        pageSize.height / imageSize.height)
        let w = imageSize.width  * scale
        let h = imageSize.height * scale
        return CGRect(
            x: (pageSize.width  - w) / 2,
            y: (pageSize.height - h) / 2,
            width:  w,
            height: h
        )
    }

    private func centredRect(for imageSize: CGSize, pageSize: CGSize) -> CGRect {
        // Scale image to fit within 60% of the page, preserving aspect.
        let maxW = pageSize.width  * 0.60
        let maxH = pageSize.height * 0.60
        let scaleW = maxW / imageSize.width
        let scaleH = maxH / imageSize.height
        let scale  = min(scaleW, scaleH, 1.0)
        let w = imageSize.width  * scale
        let h = imageSize.height * scale
        return CGRect(
            x: (pageSize.width  - w) / 2,
            y: (pageSize.height - h) / 2,
            width:  w,
            height: h
        )
    }

    /// Persist a `ProcessedImage` as a V6 `PageElement(kind: .image)`
    /// + `ImageContent`. The image bytes were already written by
    /// `ImageProcessingService.processImage(_:mediaDir:)` into
    /// `MediaStorage.directory(for: .images)/<id>.jpg`, which
    /// matches `ImageContent.fileURL` exactly — no extra file
    /// write needed here, only the SwiftData insert.
    ///
    /// Step 4 rewired this off the legacy `ImageRecord` /
    /// `MediaAttachmentStore` flow.
    private func saveImageRecord(
        _ processed: ProcessedImage,
        on page: Page,
        notebookId: UUID,
        rect: CGRect,
        pageSize: CGSize,
        persistImmediately: Bool = true,
        notify: Bool = true
    ) {
        let context = StorageService.shared.context
        let element = PageElement(
            id: UUID(),
            pageId: page.id,
            notebookId: notebookId,
            kind: .image,
            normalizedX:      rect.origin.x / pageSize.width,
            normalizedY:      rect.origin.y / pageSize.height,
            normalizedWidth:  rect.width    / pageSize.width,
            normalizedHeight: rect.height   / pageSize.height
        )
        let content = ImageContent(
            id: processed.id,
            filename: processed.fileName,
            fileFormat: "jpg",  // ImageProcessingService writes JPG only
            originalPixelWidth: Int(processed.originalSize.width),
            originalPixelHeight: Int(processed.originalSize.height),
            imageData: processed.fullData
        )
        element.imageContent = content
        context.insert(element)
        // Thumbnails key on `page.updatedAt` and now composite image
        // elements — without the stamp a freshly inserted photo
        // never appears in the strip until the next stroke.
        StrokeCommit.stampPage(pageId: page.id, context: context)
        if persistImmediately {
            do {
                try context.save()
            } catch {
                #if DEBUG
                dlog("[Image] save failed in MediaInsertCoordinator: \(error)")
                #endif
            }
        }
        PageElementUndo.registerCreate(
            elementId: element.id,
            kind: .image,
            canvas: viewModel?.canvasView,
            actionName: "Insert Image"
        )
        if notify {
            NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
        }
    }
}
