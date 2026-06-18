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
        /// pages on one canvas was unreadable. In-editor only.
        case afterCurrentPage
        /// Legacy: embed every selected PDF page as a single
        /// `PageElement` on the current page, stacked with a small
        /// stagger so multiples don't perfectly overlap. In-editor
        /// only.
        case onCurrentPage
        /// Create a new notebook in the given subject (nil =
        /// uncategorised), populate it with one notebook page per
        /// PDF page, and signal LibraryView to swap the editor
        /// cover to it.
        case newNotebook(subjectId: UUID?)
        /// Append the selected PDF pages onto the end of an
        /// existing notebook (one PDF page per new notebook page).
        case existingNotebook(notebookId: UUID)
    }

    /// Posted after a `.newNotebook` import succeeds. `userInfo`
    /// carries the new notebook's UUID under the
    /// `notebookId` key. LibraryView observes this and re-points
    /// the editor cover.
    static let requestSwitchNotebookNotification = Notification.Name(
        "PDFImport.requestSwitchNotebook"
    )

    /// Library-context entry: ingest the selected PDF pages without
    /// an `EditorViewModel`. Used by the share-inbox picker, where
    /// the user has chosen pages + a destination (new notebook in a
    /// subject, or appending into an existing notebook) but the
    /// editor isn't on screen. Returns the resulting notebook's
    /// UUID so the caller can swap the editor cover to it.
    @discardableResult
    static func importPagesFromLibrary(
        from sourceURL: URL,
        pageIndices: [Int],
        destination: Destination
    ) async -> UUID? {
        guard !pageIndices.isEmpty else { return nil }
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }
        let hash = MediaStorage.sha256Hex(of: data)
        let pdfDocumentId = MediaStorage.writePDF(from: data, hash: hash)
        guard let document = PDFDocument(url: MediaStorage.url(forPDF: pdfDocumentId)) else { return nil }

        struct PerPagePayload {
            let pageIndex: Int
            let previewFilename: String?
            let originalSize: CGSize
            let aspect: Double
            /// Plain text from `PDFPage.string` — populated for
            /// digital PDFs, nil for scanned/image-only PDFs.
            /// Stashed on `PDFPageContent.extractedText` so quiz
            /// generation can read PDF content without OCR.
            let extractedText: String?
        }
        let payloads: [PerPagePayload] = await Task.detached(priority: .userInitiated) {
            var out: [PerPagePayload] = []
            for index in pageIndices {
                guard index >= 0, index < document.pageCount,
                      let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let aspect = max(0.01, Double(bounds.height) / Double(bounds.width))
                let preview = renderPreviewImage(for: page, sourceBounds: bounds)
                let contentId = UUID()
                let previewName: String? = preview.flatMap {
                    MediaStorage.writePDFPreview($0, contentId: contentId)
                }
                _ = contentId
                out.append(PerPagePayload(
                    pageIndex: index,
                    previewFilename: previewName,
                    originalSize: bounds.size,
                    aspect: aspect,
                    extractedText: extractPageText(page)
                ))
            }
            return out
        }.value

        let context = StorageService.shared.context
        let targetNotebook: Notebook
        switch destination {
        case .newNotebook(let subjectId):
            do {
                targetNotebook = try StorageService.shared.createNotebook(
                    title: uniqueImportedNotebookTitle(from: sourceURL),
                    subjectId: subjectId,
                    coverColorHex: "#FAFAF8",
                    coverTexture: .none,
                    pageSize: .a4,
                    template: .blank
                )
                // The user already chose to import a PDF — they did
                // not ask to customise covers / page size. Suppress
                // the floating Customise pill for this notebook.
                EditorViewModel.suppressCustomisePill(for: targetNotebook.id)
                // `createNotebook` seeds a blank page 1. For a PDF
                // import the user expects "PDF page 1 → notebook
                // page 1," not "blank → PDF page 1 → PDF page 2 …"
                // Drop the seeded blank so the first PDF page
                // becomes the first page of the notebook.
                removeSeededBlankPage(from: targetNotebook, context: context)
            } catch {
                #if DEBUG
                dlog("[PDFImport-Library] createNotebook failed: \(error)")
                #endif
                return nil
            }
        case .existingNotebook(let id):
            let descriptor = FetchDescriptor<Notebook>(
                predicate: #Predicate<Notebook> { $0.id == id }
            )
            guard let existing = (try? context.fetch(descriptor))?.first else {
                #if DEBUG
                dlog("[PDFImport-Library] existingNotebook(\(id)) not found")
                #endif
                return nil
            }
            targetNotebook = existing
        case .afterCurrentPage, .onCurrentPage:
            // These require an editor; library-context callers
            // should never hit this branch (the picker only offers
            // the two destinations above when launched from the
            // library). Defensive only.
            #if DEBUG
            dlog("[PDFImport-Library] editor-only destination in library context")
            #endif
            return nil
        }

        let existingPages = (targetNotebook.pages ?? [])
            .filter { !$0.isDeleted }
            .map(\.pageNumber)
        var anchorPageNumber = existingPages.max() ?? 0
        for payload in payloads {
            guard let newPage = try? StorageService.shared.createPage(
                in: targetNotebook,
                after: anchorPageNumber,
                pageSize: targetNotebook.pageSize,
                backgroundTemplate: targetNotebook.defaultTemplate
            ) else { continue }
            anchorPageNumber = newPage.pageNumber

            let element = PageElement(
                id: UUID(),
                pageId: newPage.id,
                notebookId: targetNotebook.id,
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
                previewImageFilename: payload.previewFilename,
                extractedText: payload.extractedText
            )
            element.pdfPageContent = content
            context.insert(element)
        }
        try? context.save()
        NotificationCenter.default.post(name: .pdfPageElementsChanged, object: nil)
        return targetNotebook.id
    }

    /// Legacy convenience: ingest every page of `sourceURL` into a
    /// freshly-created notebook with no editor in play. Kept as a
    /// thin wrapper over `importPagesFromLibrary` so the earlier
    /// share-inbox callsite (which had no page selection UI) still
    /// works without changes.
    static func importAllPagesIntoNewNotebook(
        from sourceURL: URL
    ) async -> Notebook? {
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }
        let hash = MediaStorage.sha256Hex(of: data)
        let pdfDocumentId = MediaStorage.writePDF(from: data, hash: hash)
        guard let document = PDFDocument(url: MediaStorage.url(forPDF: pdfDocumentId)) else { return nil }

        let allIndices = Array(0..<document.pageCount)
        guard !allIndices.isEmpty else { return nil }

        struct PerPagePayload {
            let pageIndex: Int
            let previewFilename: String?
            let originalSize: CGSize
            let aspect: Double
            let extractedText: String?
        }
        let payloads: [PerPagePayload] = await Task.detached(priority: .userInitiated) {
            var out: [PerPagePayload] = []
            for index in allIndices {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let aspect = max(0.01, Double(bounds.height) / Double(bounds.width))
                let preview = renderPreviewImage(for: page, sourceBounds: bounds)
                let contentId = UUID()
                let previewName: String? = preview.flatMap {
                    MediaStorage.writePDFPreview($0, contentId: contentId)
                }
                _ = contentId
                out.append(PerPagePayload(
                    pageIndex: index,
                    previewFilename: previewName,
                    originalSize: bounds.size,
                    aspect: aspect,
                    extractedText: extractPageText(page)
                ))
            }
            return out
        }.value

        let context = StorageService.shared.context
        let title = uniqueImportedNotebookTitle(from: sourceURL)
        let notebook: Notebook
        do {
            notebook = try StorageService.shared.createNotebook(
                title: title,
                subjectId: nil,
                coverColorHex: "#FAFAF8",
                coverTexture: .none,
                pageSize: .a4,
                template: .blank
            )
            EditorViewModel.suppressCustomisePill(for: notebook.id)
            removeSeededBlankPage(from: notebook, context: context)
        } catch {
            return nil
        }

        var anchorPageNumber: Int = 0
        for payload in payloads {
            guard let newPage = try? StorageService.shared.createPage(
                in: notebook,
                after: anchorPageNumber,
                pageSize: notebook.pageSize,
                backgroundTemplate: notebook.defaultTemplate
            ) else { continue }
            anchorPageNumber = newPage.pageNumber

            let element = PageElement(
                id: UUID(),
                pageId: newPage.id,
                notebookId: notebook.id,
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
                previewImageFilename: payload.previewFilename,
                extractedText: payload.extractedText
            )
            element.pdfPageContent = content
            context.insert(element)
        }
        try? context.save()
        return notebook
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
            dlog("[PDFImport] couldn't read source bytes from \(sourceURL.lastPathComponent)")
            #endif
            return
        }

        let hash = MediaStorage.sha256Hex(of: data)
        let pdfDocumentId = MediaStorage.writePDF(from: data, hash: hash)

        guard let document = PDFDocument(url: MediaStorage.url(forPDF: pdfDocumentId)) else {
            #if DEBUG
            dlog("[PDFImport] PDFKit failed to load stored copy of \(sourceURL.lastPathComponent)")
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
            let extractedText: String?
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
                    aspect: aspect,
                    extractedText: extractPageText(page)
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

        // For .newNotebook we create the target notebook here so
        // the rest of the switch can treat it uniformly with
        // `viewModel.notebook` (a freshly created notebook fills
        // the same role for the importer — it's "the notebook we're
        // writing into for this run"). The resulting notebook ID
        // is broadcast at the end so LibraryView can swap the
        // editor cover atomically; we don't tear down the cover
        // ourselves.
        let targetNotebook: Notebook
        var createdNotebookId: UUID?
        switch destination {
        case .afterCurrentPage, .onCurrentPage:
            targetNotebook = viewModel.notebook
        case .newNotebook(let subjectId):
            // Subject picked by the user (in-editor: defaults to the
            // source notebook's subject; library/share-inbox: defaults
            // to the currently-selected subject or nil). Carry it
            // verbatim into the freshly-created notebook.
            do {
                let created = try StorageService.shared.createNotebook(
                    title: defaultNotebookTitle(from: sourceURL),
                    subjectId: subjectId ?? viewModel.notebook.subjectId,
                    coverColorHex: viewModel.notebook.coverColorHex,
                    coverTexture: viewModel.notebook.coverTexture,
                    pageSize: viewModel.notebook.pageSize,
                    template: viewModel.notebook.defaultTemplate
                )
                targetNotebook = created
                createdNotebookId = created.id
            } catch {
                #if DEBUG
                dlog("[PDFImport] createNotebook failed: \(error)")
                #endif
                return
            }
        case .existingNotebook(let id):
            let descriptor = FetchDescriptor<Notebook>(
                predicate: #Predicate<Notebook> { $0.id == id }
            )
            guard let existing = (try? context.fetch(descriptor))?.first else {
                #if DEBUG
                dlog("[PDFImport] existingNotebook(\(id)) not found")
                #endif
                return
            }
            targetNotebook = existing
            createdNotebookId = existing.id   // signal editor swap
        }
        let notebookId = targetNotebook.id

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
                    previewImageFilename: payload.previewFilename,
                    extractedText: payload.extractedText
                )
                element.pdfPageContent = content
                context.insert(element)
            }

        case .afterCurrentPage, .newNotebook, .existingNotebook:
            // Each PDF page becomes its own notebook page. Anchor
            // depends on destination:
            //   • afterCurrentPage → after the editor's current page
            //   • newNotebook      → fresh notebook, anchor at 0
            //   • existingNotebook → append after the last existing
            //                        page in the target notebook
            var anchorPageNumber: Int = {
                switch destination {
                case .afterCurrentPage:
                    return viewModel.currentPage.pageNumber
                case .newNotebook:
                    return 0
                case .existingNotebook:
                    let existingPages = (targetNotebook.pages ?? [])
                        .filter { !$0.isDeleted }
                        .map(\.pageNumber)
                    return existingPages.max() ?? 0
                case .onCurrentPage:
                    return 0   // unreachable in this branch
                }
            }()
            for payload in payloads {
                guard let newPage = try? StorageService.shared.createPage(
                    in: targetNotebook,
                    after: anchorPageNumber,
                    pageSize: targetNotebook.pageSize,
                    backgroundTemplate: targetNotebook.defaultTemplate
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
                    previewImageFilename: payload.previewFilename,
                    extractedText: payload.extractedText
                )
                element.pdfPageContent = content
                context.insert(element)
            }
        }

        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[PDFImport] save failed: \(error)")
            #endif
        }
        if case .afterCurrentPage = destination {
            viewModel.refreshPages()
        }
        NotificationCenter.default.post(name: .pdfPageElementsChanged, object: nil)

        // `.newNotebook` is the only path that needs a cover-level
        // swap. We post a single notification carrying the new
        // notebook's UUID; LibraryView observes this and flips the
        // `editingNotebook` binding directly. SwiftUI treats that
        // as a binding swap (one transition), not a dismiss-then-
        // present, so the user sees a clean replace rather than a
        // flash of the library.
        if let createdNotebookId {
            NotificationCenter.default.post(
                name: requestSwitchNotebookNotification,
                object: nil,
                userInfo: ["notebookId": createdNotebookId]
            )
        }
    }

    /// Best-effort title for the auto-created notebook: PDF
    /// filename minus its extension, trimmed. Falls back to
    /// "Imported PDF" when the filename is empty after trimming
    /// (rare — mostly defensive against directories named without
    /// a basename).
    private static func defaultNotebookTitle(from url: URL) -> String {
        let trimmed = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Imported PDF" : trimmed
    }

    /// Wraps `defaultNotebookTitle` with a duplicate-aware suffix so
    /// re-importing the same PDF produces "Foo", then "Foo Copy",
    /// then "Foo Copy 2", etc. — instead of multiple notebooks
    /// sharing the same display name. Reads the current notebook
    /// list once per import; the storage layer is already warm
    /// from earlier in the flow.
    @MainActor
    private static func uniqueImportedNotebookTitle(from url: URL) -> String {
        let base = defaultNotebookTitle(from: url)
        let existingTitles = Set(
            StorageService.shared.fetchAllNotebooks().map(\.title)
        )
        if !existingTitles.contains(base) { return base }
        let copyOne = "\(base) Copy"
        if !existingTitles.contains(copyOne) { return copyOne }
        var n = 2
        while existingTitles.contains("\(base) Copy \(n)") { n += 1 }
        return "\(base) Copy \(n)"
    }

    /// Removes the blank starter page that `StorageService
    /// .createNotebook` inserts on every notebook. PDF imports
    /// want the first PDF page to be page 1, not page 2.
    /// Safe-by-default: only drops the page if it has no text
    /// blocks — the notebook is brand-new so there shouldn't be
    /// any other content, but the guard keeps us from accidentally
    /// wiping a user-touched page if this is ever called later.
    @MainActor
    private static func removeSeededBlankPage(
        from notebook: Notebook,
        context: ModelContext
    ) {
        guard let pages = notebook.pages, pages.count == 1,
              let seed = pages.first,
              (seed.textBlocks ?? []).isEmpty
        else { return }
        context.delete(seed)
        notebook.pages = []
        notebook.totalPageCount = 0
        try? context.save()
    }

    // MARK: - Helpers

    /// Pulls the embedded text layer from a `PDFPage` and returns
    /// it as a single string, or nil if the page has no text
    /// (image-only / scanned PDF). Trimmed so a page whose text
    /// layer is just whitespace doesn't masquerade as content
    /// downstream. Runs on the detached payload-build task — pure
    /// PDFKit I/O, no UI dependencies, safe off the main actor.
    nonisolated static func extractPageText(_ page: PDFPage) -> String? {
        let raw = page.string
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #if DEBUG
        // Diagnostic for "imported PDF, quiz can't generate" reports.
        // If you see `nil` or `0` for every page, the PDF is
        // image-only / scanned — there's no embedded text layer
        // for the quiz pipeline to read. OCR is on the roadmap but
        // not in v1; the fix is a PDF whose source had a text layer
        // (most digital PDFs do).
        let pageLabel = page.label ?? "?"
        if let raw, !trimmed.isEmpty {
            dlog("[PDFExtract] page=\(pageLabel) chars=\(trimmed.count) rawChars=\(raw.count)")
        } else {
            dlog("[PDFExtract] page=\(pageLabel) NO TEXT LAYER (image-only or scanned PDF) — quiz generation will skip this page")
        }
        #endif
        return trimmed.isEmpty ? nil : trimmed
    }

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
