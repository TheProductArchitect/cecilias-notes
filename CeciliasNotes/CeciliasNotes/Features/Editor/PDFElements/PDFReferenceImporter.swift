import Foundation
import PDFKit
import SwiftData
import UIKit

/// Imports selected pages of a PDF as V6 `PageElement(kind: .pdfPage)`
/// rows on the editor's current page. Workflow B from architecture
/// doc §13 — distinct from Workflow A (PDF-as-notebook).
///
/// Pipeline:
///   1. Load PDF bytes, compute SHA-256 hash, dedup or copy into
///      `MediaStorage.pdfDirectory`.
///   2. For each selected page index:
///      a. Render a small preview PNG (~400pt wide) to
///         `MediaStorage.pdfPreviewDirectory/<contentId>.png`.
///      b. Create `PDFPageContent` (referencing the shared file)
///         + `PageElement` (sized to ~60% of page width preserving
///         aspect ratio, vertically staggered ~10% per page so
///         multiples don't perfectly overlap).
///   3. Insert + save in one transaction; post
///      `.pdfPageElementsChanged` so the overlay refetches.
@MainActor
enum PDFReferenceImporter {

    /// Default target width (normalised) for inserted pages.
    /// Centered horizontally; vertical stagger applied to multiples.
    private static let targetWidth: Double = 0.6
    /// Vertical offset between successive multi-page inserts.
    private static let staggerNormalizedY: Double = 0.04
    /// Preview-image longest dimension in points (~400pt) — small
    /// enough to render quickly at import time, large enough to
    /// look crisp while PDFKit's high-res render is in flight.
    nonisolated private static let previewLongestEdge: CGFloat = 400

    /// Run the import. Synchronous SwiftData calls hop to the main
    /// actor; the PDF read + preview rendering happen on a detached
    /// task. Caller passes the source PDF URL (security-scoped if
    /// from the document picker), the picked page indices, and the
    /// target editor view-model.
    static func importPages(
        from sourceURL: URL,
        pageIndices: [Int],
        into viewModel: EditorViewModel
    ) async {
        guard !pageIndices.isEmpty else { return }

        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: sourceURL) else {
            #if DEBUG
            print("[PDFImport] couldn't read source bytes from \(sourceURL.lastPathComponent)")
            #endif
            return
        }

        let hash = MediaStorage.sha256Hex(of: data)
        let pdfDocumentId = MediaStorage.writePDF(from: data, hash: hash)

        guard let document = PDFDocument(url: MediaStorage.url(forPDF: pdfDocumentId)) else {
            #if DEBUG
            print("[PDFImport] PDFKit failed to load stored copy of \(sourceURL.lastPathComponent)")
            #endif
            return
        }

        // Render previews + compute per-page sizing on a background
        // task so the main actor isn't blocked by PDFKit work.
        struct PerPagePayload {
            let pageIndex: Int
            let previewFilename: String?
            let originalSize: CGSize
            let aspect: Double  // height / width
        }
        let payloads: [PerPagePayload] = await Task.detached(priority: .userInitiated) {
            var out: [PerPagePayload] = []
            for index in pageIndices {
                guard index >= 0, index < document.pageCount,
                      let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let aspect = max(0.01, Double(bounds.height) / Double(bounds.width))
                let preview = renderPreviewImage(
                    for: page,
                    sourceBounds: bounds
                )
                let contentId = UUID()
                let previewName: String? = preview.flatMap {
                    MediaStorage.writePDFPreview($0, contentId: contentId)
                }
                // Attach contentId via parallel field — order matters
                // so the caller can match preview filenames to the
                // content rows it creates. Use index in `pageIndices`
                // ordering, not the PDF page index.
                _ = contentId  // We re-generate contentIds on main actor below; preview is keyed on filename only.
                out.append(PerPagePayload(
                    pageIndex: index,
                    previewFilename: previewName,
                    originalSize: bounds.size,
                    aspect: aspect
                ))
            }
            return out
        }.value

        // Insert on main actor.
        let context = StorageService.shared.context
        let currentPageId = viewModel.currentPage.id
        let notebookId = viewModel.notebook.id
        let baseZIndex = (nextZIndex(forPageId: currentPageId, context: context))
        let baseY: Double = 0.1  // First insert anchors near the top; stagger fans down.

        for (offset, payload) in payloads.enumerated() {
            let normalizedHeight = targetWidth * payload.aspect
            let normalizedX = max(0, min(1 - targetWidth, (1 - targetWidth) / 2))
            let stagger = Double(offset) * staggerNormalizedY
            let normalizedY = min(
                1 - normalizedHeight,
                baseY + stagger
            )

            let element = PageElement(
                id: UUID(),
                pageId: currentPageId,
                notebookId: notebookId,
                kind: .pdfPage,
                normalizedX: normalizedX,
                normalizedY: normalizedY,
                normalizedWidth: targetWidth,
                normalizedHeight: max(0.05, normalizedHeight),
                zIndex: baseZIndex + offset
            )
            let content = PDFPageContent(
                id: UUID(),
                pdfDocumentId: pdfDocumentId,
                pageIndex: payload.pageIndex,
                originalPageWidth: Double(payload.originalSize.width),
                originalPageHeight: Double(payload.originalSize.height),
                previewImageFilename: payload.previewFilename
            )
            element.pdfPageContent = content
            context.insert(element)
        }

        do {
            try context.save()
        } catch {
            #if DEBUG
            print("[PDFImport] save failed: \(error)")
            #endif
        }
        NotificationCenter.default.post(name: .pdfPageElementsChanged, object: nil)
    }

    // MARK: - Helpers

    private nonisolated static func renderPreviewImage(
        for page: PDFPage,
        sourceBounds: CGRect
    ) -> UIImage? {
        let longest = max(sourceBounds.width, sourceBounds.height)
        let scale: CGFloat = longest > 0 ? previewLongestEdge / longest : 1.0
        let pixelSize = CGSize(
            width: sourceBounds.width * scale,
            height: sourceBounds.height * scale
        )
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: pixelSize)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: pixelSize.height)
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: cg)
        }
    }

    private static func nextZIndex(forPageId pageId: UUID, context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pageId && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.zIndex, order: .reverse)]
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        return (elements.first?.zIndex ?? 0) + 1
    }
}
