import Combine
import Foundation
import PhotosUI
import UIKit
import VisionKit
import UniformTypeIdentifiers
import PDFKit

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

    func insertPhotos()    { viewModel?.activeMediaSource = .photos }
    func insertFromFiles() { viewModel?.activeMediaSource = .files }
    func insertFromCamera() { viewModel?.activeMediaSource = .camera }
    func insertScan()      { viewModel?.activeMediaSource = .scan }
    func dismiss()         { viewModel?.activeMediaSource = nil }

    // MARK: - Pipeline entry points

    /// Called by photo picker with selected UIImages.
    func handlePickedImages(_ images: [UIImage]) async {
        guard let vm = viewModel else { return }
        viewModel?.activeMediaSource = nil
        await processAndInsert(images: images.map { .uiImage($0) }, into: vm)
    }

    /// Called by document picker with URLs.
    func handlePickedFileURLs(_ urls: [URL]) async {
        guard let vm = viewModel else { return }
        viewModel?.activeMediaSource = nil
        var inputs: [ImageInput] = []
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

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
        viewModel?.activeMediaSource = nil
        var images: [UIImage] = []
        for i in 0..<scan.pageCount {
            images.append(scan.imageOfPage(at: i))
        }
        guard !images.isEmpty else { return }

        let pageSize = vm.currentPage.pageSize.pointSize
        let mediaDir = mediaDirectory(for: vm)

        isProcessing = true
        defer { isProcessing = false; processingProgress = 0 }

        var processed: [ProcessedImage] = []
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        for (i, img) in images.enumerated() {
            if let result = try? await ImageProcessingService.shared.processImage(.uiImage(img), mediaDir: mediaDir) {
                processed.append(result)
            }
            await MainActor.run { processingProgress = Double(i + 1) / Double(images.count) }
        }

        guard !processed.isEmpty else { return }

        // First scanned page → current page
        let first = processed[0]
        let rect  = centredRect(for: first.originalSize, pageSize: pageSize)
        try? StorageService.shared.addPreprocessedImage(
            to: vm.currentPage, id: first.id, fileName: first.fileName,
            fileSizeBytes: first.fileSizeBytes,
            originalWidth: Int(first.originalSize.width),
            originalHeight: Int(first.originalSize.height),
            at: MediaLayoutState.normalise(rect, pageSize: pageSize)
        )

        // Pages 2+ → new pages
        for extra in processed.dropFirst() {
            vm.addPage()
            guard let newPage = vm.pages.last else { continue }
            let r = centredRect(for: extra.originalSize, pageSize: pageSize)
            try? StorageService.shared.addPreprocessedImage(
                to: newPage, id: extra.id, fileName: extra.fileName,
                fileSizeBytes: extra.fileSizeBytes,
                originalWidth: Int(extra.originalSize.width),
                originalHeight: Int(extra.originalSize.height),
                at: MediaLayoutState.normalise(r, pageSize: pageSize)
            )
        }

        vm.refreshCurrentPageAttachments()
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

        for i in 0..<pageCount {
            guard let pdfPage = doc.page(at: i)?.pageRef else { continue }
            if let img = try? await ImageProcessingService.shared.rasterisePDFPage(pdfPage) {
                let input: ImageInput = .uiImage(img)
                if let processed = try? await ImageProcessingService.shared.processImage(input, mediaDir: mediaDir) {
                    let r = centredRect(for: processed.originalSize, pageSize: pageSize)

                    if i == 0 {
                        try? StorageService.shared.addPreprocessedImage(
                            to: viewModel.currentPage, id: processed.id,
                            fileName: processed.fileName,
                            fileSizeBytes: processed.fileSizeBytes,
                            originalWidth: Int(processed.originalSize.width),
                            originalHeight: Int(processed.originalSize.height),
                            at: MediaLayoutState.normalise(r, pageSize: pageSize)
                        )
                    } else {
                        viewModel.addPage()
                        if let newPage = viewModel.pages.last {
                            try? StorageService.shared.addPreprocessedImage(
                                to: newPage, id: processed.id,
                                fileName: processed.fileName,
                                fileSizeBytes: processed.fileSizeBytes,
                                originalWidth: Int(processed.originalSize.width),
                                originalHeight: Int(processed.originalSize.height),
                                at: MediaLayoutState.normalise(r, pageSize: pageSize)
                            )
                        }
                    }
                }
            }
            await MainActor.run { processingProgress = Double(i + 1) / Double(pageCount) }
        }
        viewModel.refreshCurrentPageAttachments()
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

        // Insert cascade: first at centre, each subsequent +16pt right+down
        var insertedIds: [UUID] = []
        for (i, processed) in results.enumerated() {
            let offset = CGFloat(i) * 16
            var rect   = centredRect(for: processed.originalSize, pageSize: pageSize)
            rect.origin.x = min(rect.origin.x + offset, pageSize.width  - rect.width  - 8)
            rect.origin.y = min(rect.origin.y + offset, pageSize.height - rect.height - 8)
            let norm = MediaLayoutState.normalise(rect, pageSize: pageSize)

            if let att = try? StorageService.shared.addPreprocessedImage(
                to: vm.currentPage,
                id: processed.id,
                fileName: processed.fileName,
                fileSizeBytes: processed.fileSizeBytes,
                originalWidth: Int(processed.originalSize.width),
                originalHeight: Int(processed.originalSize.height),
                at: norm
            ) {
                insertedIds.append(att.id)
            }
        }

        vm.refreshCurrentPageAttachments()
        vm.selectedAttachmentIds = Set(insertedIds)
    }

    // MARK: - Helpers

    private func mediaDirectory(for vm: EditorViewModel) -> URL {
        StorageService.notebooksDirectoryURL
            .appendingPathComponent(vm.notebook.id.uuidString)
            .appendingPathComponent("media")
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
}
