import Foundation
import PDFKit
import SwiftData
import UIKit

/// Imports selected pages of a PDF into a notebook. The caller
/// chooses the destination: each PDF page becomes its own notebook
/// page (default), or all selected pages embed as `PageElement`s on
/// the current page (legacy stacked behaviour). Workflow B from
/// architecture doc §13 — distinct from Workflow A (PDF-as-notebook).
@MainActor
enum PDFReferenceImporter {

    /// Where the picked PDF pages land.
    enum Destination {
        /// One PDF page per fresh notebook page, inserted after the
        /// current page in order. Each PDF page fills its page edge
        /// to edge — the fix for the stacked-element bug where many
        /// pages on one canvas was unreadable.
        case afterCurrentPage
        /// Legacy: embed every selected PDF page as a single
        /// `PageElement` on the current page, stacked with a small
        /// stagger so multiples don't perfectly overlap.
        case onCurrentPage
    }

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
        into viewModel: EditorViewModel,
        destination: Destination = .afterCurrentPage
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

        // Insert on main actor. Branch on destination — the legacy
        // "stack on current page" mode is retained for users who
        // explicitly chose it; the default now expands each PDF
        // page onto its own notebook page so multi-page imports
        // are actually readable.
        let context = StorageService.shared.context
        let notebookId = viewModel.notebook.id

        switch destination {
        case .onCurrentPage:
            let currentPageId = viewModel.currentPage.id
            let baseZIndex = nextZIndex(forPageId: currentPageId, context: context)
            let baseY: Double = 0.1

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

        case .afterCurrentPage:
            // Each PDF page becomes its own notebook page, inserted
            // in order directly after the page the user is on. The
            // PDF element fills the entire page (normalised 0…1 in
            // both axes); aspect mismatches letterbox naturally
            // inside the renderer.
            var anchorPageNumber = viewModel.currentPage.pageNumber
            for payload in payloads {
                guard let newPage = try? StorageService.shared.createPage(
                    in: viewModel.notebook,
                    after: anchorPageNumber,
                    pageSize: viewModel.notebook.pageSize,
                    backgroundTemplate: viewModel.notebook.defaultTemplate
                ) else { continue }
                anchorPageNumber = newPage.pageNumber

                let element = PageElement(
                    id: UUID(),
                    pageId: newPage.id,
                    notebookId: notebookId,
                    kind: .pdfPage,
                    normalizedX: 0,
                    normalizedY: 0,
                    normalizedWidth: 1,
                    normalizedHeight: 1,
                    zIndex: 0
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
        }

        do {
            try context.save()
        } catch {
            #if DEBUG
            print("[PDFImport] save failed: \(error)")
            #endif
        }
        if destination == .afterCurrentPage {
            viewModel.refreshPages()
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
