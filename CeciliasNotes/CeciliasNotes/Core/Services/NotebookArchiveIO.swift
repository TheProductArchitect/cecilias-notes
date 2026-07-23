import Foundation
import SwiftData

/// Reads and writes the full-fidelity `.ceciliabook` archive
/// (`NotebookArchive`). Export builds a self-contained JSON file with
/// media base64-embedded; import reconstructs a fresh notebook (all
/// new IDs, so it can't collide with the sender's copy) and writes the
/// media back to `MediaStorage`.
@MainActor
enum NotebookArchiveIO {

    private static let iso = ISO8601DateFormatter()

    // MARK: - Export

    /// Serialize a notebook to a `.ceciliabook` file on disk and return
    /// its URL (written into the exports temp area). Returns nil if the
    /// notebook can't be read.
    static func exportToFile(_ notebook: Notebook) -> URL? {
        guard let archive = buildArchive(for: notebook) else { return nil }
        guard let data = try? JSONEncoder().encode(archive) else { return nil }
        let safeName = notebook.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safeName.isEmpty ? "Notebook" : safeName
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceciliabook-export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(base).\(NotebookArchive.fileExtension)")
        try? FileManager.default.removeItem(at: url)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Serialize a notebook straight to `Data` (for the multipeer send
    /// path, which frames bytes rather than files).
    static func archiveData(for notebook: Notebook) -> Data? {
        guard let archive = buildArchive(for: notebook) else { return nil }
        return try? JSONEncoder().encode(archive)
    }

    static func buildArchive(for notebook: Notebook) -> NotebookArchive? {
        let storage = StorageService.shared
        let pages = storage.fetchPages(in: notebook)
        guard !pages.isEmpty else { return nil }

        let subjectName = notebook.subjectId.flatMap { sid in
            storage.fetchSubjects().first { $0.id == sid }?.name
        }

        var media: [String: String] = [:]
        var pdfDocs: [String: String] = [:]
        var archivePages: [NotebookArchive.ArchivePage] = []

        for page in pages {
            let elements = fetchElements(pageId: page.id)
            var archiveElements: [NotebookArchive.ArchiveElement] = []
            for el in elements {
                guard let ae = archiveElement(el, media: &media, pdfDocs: &pdfDocs) else { continue }
                archiveElements.append(ae)
            }
            archivePages.append(NotebookArchive.ArchivePage(
                index: page.pageNumber,
                pageSize: page.pageSize.rawValue,
                backgroundTemplate: page.backgroundTemplate.jsonString,
                elements: archiveElements
            ))
        }

        return NotebookArchive(
            exportedAt: iso.string(from: Date()),
            notebook: .init(
                title: notebook.title,
                subjectName: subjectName,
                coverColorHex: notebook.coverColorHex,
                coverTexture: notebook.coverTexture.rawValue,
                pageSize: notebook.pageSize.rawValue,
                defaultTemplate: notebook.defaultTemplate.jsonString
            ),
            pages: archivePages,
            media: media.isEmpty ? nil : media,
            pdfDocuments: pdfDocs.isEmpty ? nil : pdfDocs
        )
    }

    private static func archiveElement(
        _ el: PageElement,
        media: inout [String: String],
        pdfDocs: inout [String: String]
    ) -> NotebookArchive.ArchiveElement? {
        var out = NotebookArchive.ArchiveElement(
            kind: el.kind.rawValue,
            x: el.normalizedX, y: el.normalizedY,
            w: el.normalizedWidth, h: el.normalizedHeight,
            rotation: el.rotation, zIndex: el.zIndex,
            opacity: el.opacity, isLocked: el.isLocked
        )
        switch el.kind {
        case .text:
            guard let c = el.textContent else { return nil }
            out.text = .init(
                text: c.text,
                source: c.source.rawValue,
                size: c.size.rawValue,
                attributedTextData: c.attributedTextData?.base64EncodedString()
            )
        case .image:
            guard let c = el.imageContent else { return nil }
            let cid = c.id.uuidString
            if let bytes = c.imageData ?? (try? Data(contentsOf: c.fileURL)) {
                media[cid] = bytes.base64EncodedString()
            }
            out.image = .init(
                contentId: cid,
                fileFormat: c.fileFormat,
                originalPixelWidth: c.originalPixelWidth,
                originalPixelHeight: c.originalPixelHeight,
                cropOriginX: c.cropOriginX, cropOriginY: c.cropOriginY,
                cropWidth: c.cropWidth, cropHeight: c.cropHeight
            )
        case .audio:
            guard let c = el.audioContent else { return nil }
            let cid = c.id.uuidString
            if let bytes = c.audioData ?? (try? Data(contentsOf: c.fileURL)) {
                media[cid] = bytes.base64EncodedString()
            }
            out.audio = .init(
                contentId: cid,
                durationSeconds: c.durationSeconds,
                transcript: c.transcript,
                timingMapData: c.timingMapData?.base64EncodedString()
            )
        case .stroke:
            guard let c = el.strokeContent, !c.strokeData.isEmpty else { return nil }
            out.stroke = .init(
                strokeData: c.strokeData.base64EncodedString(),
                toolKind: c.toolKind, colorHex: c.colorHex,
                widthBase: c.widthBase, opacity: c.opacity
            )
        case .stickyNote:
            guard let c = el.stickyNoteContent else { return nil }
            out.sticky = .init(text: c.text, colorVariant: c.colorVariant)
        case .shape:
            guard let c = el.shapeContent else { return nil }
            out.shape = .init(
                shapeKind: c.shapeKind.rawValue,
                strokeColorHex: c.strokeColorHex, strokeWidth: c.strokeWidth,
                strokeStyle: c.strokeStyle.rawValue,
                fillColorHex: c.fillColorHex, fillOpacity: c.fillOpacity,
                containedText: c.containedText, containedTextStyle: c.containedTextStyle
            )
        case .pdfPage:
            guard let c = el.pdfPageContent else { return nil }
            let docKey = c.pdfDocumentId.uuidString
            if pdfDocs[docKey] == nil,
               let bytes = try? Data(contentsOf: MediaStorage.url(forPDF: c.pdfDocumentId)) {
                pdfDocs[docKey] = bytes.base64EncodedString()
            }
            out.pdfPage = .init(
                pdfDocumentId: docKey,
                pageIndex: c.pageIndex,
                originalPageWidth: c.originalPageWidth,
                originalPageHeight: c.originalPageHeight,
                extractedText: c.extractedText,
                contentRef: c.id.uuidString
            )
        case .highlight:
            guard let c = el.highlightContent else { return nil }
            out.highlight = .init(
                pdfPageRef: c.pdfPageContentId.uuidString,
                rectOriginX: c.rectOriginX, rectOriginY: c.rectOriginY,
                rectWidth: c.rectWidth, rectHeight: c.rectHeight,
                style: c.style.rawValue, colorVariant: c.colorVariant,
                capturedText: c.capturedText
            )
        }
        return out
    }

    private static func fetchElements(pageId: UUID) -> [PageElement] {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pageId && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.zIndex), SortDescriptor(\.createdAt)]
        )
        return (try? StorageService.shared.context.fetch(descriptor)) ?? []
    }

    // MARK: - Import

    @discardableResult
    static func importArchive(from url: URL) -> Notebook? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return importArchive(data: data)
    }

    @discardableResult
    static func importArchive(data: Data) -> Notebook? {
        guard let archive = decodeArchive(data) else { return nil }
        return reconstruct(archive)
    }

    /// Decode is the expensive half (a media-heavy archive is tens
    /// of MB of JSON + base64) and is pure value work — split out
    /// so `importArchiveAsync` can run it OFF the main actor. Only
    /// `reconstruct` (SwiftData writes) needs the main actor.
    nonisolated private static func decodeArchive(_ data: Data) -> NotebookArchive? {
        guard let archive = try? JSONDecoder().decode(NotebookArchive.self, from: data),
              archive.format == NotebookArchive.formatIdentifier else { return nil }
        return archive
    }

    /// Import with the decode off-main. Use this from user-facing
    /// entry points (tap-to-open, inbox watcher) — the synchronous
    /// `importArchive(data:)` decoded up to 32 MB of JSON inside
    /// `onOpenURL` on the main thread, a guaranteed multi-second
    /// ANR for a media-heavy notebook (2026-07-17 audit).
    @discardableResult
    static func importArchiveAsync(data: Data) async -> Notebook? {
        let archive = await Task.detached(priority: .userInitiated) {
            decodeArchive(data)
        }.value
        guard let archive else { return nil }
        return reconstruct(archive)
    }

    private static func reconstruct(_ archive: NotebookArchive) -> Notebook? {
        let storage = StorageService.shared
        let context = storage.context

        // The media writes below (`try? bytes.write`) fail silently if
        // the MediaAttachments tree doesn't exist yet — possible on a
        // fresh install whose first action is receiving a share.
        // Images/audio would still render from their in-row bytes, but
        // PDFs have NO in-row fallback: a missing pdfs/ directory means
        // every imported PDF page renders a placeholder forever.
        MediaStorage.ensureDirectoriesExist()

        // Resolve subject by name (find-or-fallback); nil lets
        // createNotebook drop it into the first subject / Imports.
        let subjectId: UUID? = archive.notebook.subjectName.flatMap { name in
            storage.fetchSubjects().first {
                $0.name.compare(name, options: .caseInsensitive) == .orderedSame
            }?.id
        }

        guard let notebook = try? storage.createNotebook(
            title: uniqueTitle(archive.notebook.title, storage: storage),
            subjectId: subjectId,
            coverColorHex: archive.notebook.coverColorHex,
            coverTexture: CoverTexture(rawValue: archive.notebook.coverTexture) ?? .none,
            pageSize: PageSize(rawValue: archive.notebook.pageSize) ?? .a4,
            template: PageTemplate.from(jsonString: archive.notebook.defaultTemplate)
        ) else { return nil }

        // Surface the import at the TOP of its subject. `createNotebook`
        // assigns the highest `sortOrder` (append-to-end), and the
        // library sorts by `sortOrder` ascending — so a fresh import
        // otherwise lands at the very bottom of a long list and reads
        // as "nothing was imported." Give it the lowest order so it's
        // the first card the user sees.
        let minOrder = storage.fetchNotebooks(subjectId: subjectId).map(\.sortOrder).min() ?? 0
        notebook.sortOrder = minOrder - 1

        let sortedPages = archive.pages.sorted { $0.index < $1.index }

        // A well-formed archive always has ≥1 page (the exporter
        // guards it). A corrupt/hand-crafted file with zero pages
        // would otherwise leave an empty notebook once the seed is
        // deleted — which the editor can't open. Keep the seed page
        // in that degenerate case.
        guard !sortedPages.isEmpty else { return notebook }

        // Drop the auto-seeded blank page — we rebuild pages from the
        // archive verbatim.
        for seed in storage.fetchPages(in: notebook) { context.delete(seed) }

        // Remap archive content refs → fresh IDs so highlights re-link
        // to their pdfPage, and PDFs de-dupe per document.
        var pdfDocIdMap: [String: UUID] = [:]
        var pdfPageContentIdMap: [String: UUID] = [:]
        for (offset, ap) in sortedPages.enumerated() {
            let page = Page(
                notebookId: notebook.id,
                pageNumber: offset + 1,
                pageSize: PageSize(rawValue: ap.pageSize) ?? notebook.pageSize,
                backgroundTemplate: PageTemplate.from(jsonString: ap.backgroundTemplate)
            )
            page.notebook = notebook
            context.insert(page)

            // Build PDF pages BEFORE anything else on the page so a
            // highlight's `pdfPageRef` always resolves to an
            // already-created pdfPage content id (highlights re-link
            // via `pdfPageContentIdMap`), regardless of the element
            // order in the file. Partition preserves relative order.
            let pdfKind = ElementKind.pdfPage.rawValue
            let ordered = ap.elements.filter { $0.kind == pdfKind }
                + ap.elements.filter { $0.kind != pdfKind }
            for ae in ordered {
                buildElement(
                    ae, page: page, notebook: notebook,
                    media: archive.media, pdfDocuments: archive.pdfDocuments,
                    pdfDocIdMap: &pdfDocIdMap, pdfPageContentIdMap: &pdfPageContentIdMap,
                    context: context
                )
            }
        }
        notebook.totalPageCount = sortedPages.count

        do {
            try context.save()
        } catch {
            // Atomicity: `createNotebook` already SAVED the notebook
            // (with its seed page) before the page rebuild. If this
            // final save fails, returning nil used to leave that
            // empty husk behind in the library — the on-device
            // "imported notebook was all empty" report. Roll the husk
            // back so a failed import leaves no trace.
            dlog("[Archive] import save FAILED: \(error) — rolling back notebook husk \(notebook.id)")
            context.rollback()
            let nbId = notebook.id
            let husks = (try? context.fetch(
                FetchDescriptor<Notebook>(predicate: #Predicate { $0.id == nbId })
            )) ?? []
            for husk in husks { context.delete(husk) }
            let orphanPages = (try? context.fetch(
                FetchDescriptor<Page>(predicate: #Predicate { $0.notebookId == nbId })
            )) ?? []
            for p in orphanPages { context.delete(p) }
            let orphanEls = (try? context.fetch(
                FetchDescriptor<PageElement>(predicate: #Predicate { $0.notebookId == nbId })
            )) ?? []
            for e in orphanEls { context.delete(e) }
            try? context.save()
            return nil
        }
        NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
        StorageService.shared.scheduleWidgetSnapshot()
        return notebook
    }

    private static func buildElement(
        _ ae: NotebookArchive.ArchiveElement,
        page: Page,
        notebook: Notebook,
        media: [String: String]?,
        pdfDocuments: [String: String]?,
        pdfDocIdMap: inout [String: UUID],
        pdfPageContentIdMap: inout [String: UUID],
        context: ModelContext
    ) {
        guard let kind = ElementKind(rawValue: ae.kind) else { return }
        let element = PageElement(
            pageId: page.id, notebookId: notebook.id, kind: kind,
            normalizedX: ae.x, normalizedY: ae.y,
            normalizedWidth: ae.w, normalizedHeight: ae.h,
            rotation: ae.rotation, zIndex: ae.zIndex,
            opacity: ae.opacity, isLocked: ae.isLocked
        )

        switch kind {
        case .text:
            guard let t = ae.text else { return }
            let c = TextContent(
                text: t.text,
                source: TextSource(rawValue: t.source) ?? .typed,
                size: TextSize(rawValue: t.size) ?? .body
            )
            if let b64 = t.attributedTextData { c.attributedTextData = Data(base64Encoded: b64) }
            element.textContent = c
        case .image:
            guard let i = ae.image else { return }
            let newId = UUID()
            let bytes = media?[i.contentId].flatMap { Data(base64Encoded: $0) }
            let c = ImageContent(
                id: newId,
                filename: "\(newId.uuidString).\(i.fileFormat)",
                fileFormat: i.fileFormat,
                originalPixelWidth: i.originalPixelWidth,
                originalPixelHeight: i.originalPixelHeight,
                imageData: bytes
            )
            c.cropOriginX = i.cropOriginX; c.cropOriginY = i.cropOriginY
            c.cropWidth = i.cropWidth; c.cropHeight = i.cropHeight
            element.imageContent = c
            if let bytes {
                let dst = MediaStorage.url(for: .images, id: newId, fileExtension: i.fileFormat)
                try? bytes.write(to: dst, options: .atomic)
            }
        case .audio:
            guard let a = ae.audio else { return }
            let newId = UUID()
            let bytes = media?[a.contentId].flatMap { Data(base64Encoded: $0) }
            let c = AudioContent(
                id: newId,
                filename: "\(newId.uuidString).m4a",
                durationSeconds: a.durationSeconds,
                transcript: a.transcript,
                audioData: bytes
            )
            if let tm = a.timingMapData { c.timingMapData = Data(base64Encoded: tm) }
            element.audioContent = c
            if let bytes {
                let dst = MediaStorage.url(for: .audio, id: newId)
                try? bytes.write(to: dst, options: .atomic)
            }
        case .stroke:
            guard let s = ae.stroke, let blob = Data(base64Encoded: s.strokeData) else { return }
            let c = StrokeContent(
                strokeData: blob, toolKind: s.toolKind,
                colorHex: s.colorHex, widthBase: s.widthBase, opacity: s.opacity
            )
            element.strokeContent = c
        case .stickyNote:
            guard let s = ae.sticky else { return }
            element.stickyNoteContent = StickyNoteContent(text: s.text, colorVariant: s.colorVariant)
        case .shape:
            guard let s = ae.shape else { return }
            let c = ShapeContent(
                shapeKind: ShapeKind(rawValue: s.shapeKind) ?? .rectangle,
                strokeColorHex: s.strokeColorHex, strokeWidth: s.strokeWidth,
                strokeStyle: ShapeStrokeStyle(rawValue: s.strokeStyle) ?? .solid
            )
            c.fillColorHex = s.fillColorHex; c.fillOpacity = s.fillOpacity
            c.containedText = s.containedText; c.containedTextStyle = s.containedTextStyle
            element.shapeContent = c
        case .pdfPage:
            guard let p = ae.pdfPage else { return }
            let newDocId = pdfDocIdMap[p.pdfDocumentId] ?? {
                let id = UUID()
                pdfDocIdMap[p.pdfDocumentId] = id
                if let b64 = pdfDocuments?[p.pdfDocumentId], let bytes = Data(base64Encoded: b64) {
                    try? bytes.write(to: MediaStorage.url(forPDF: id), options: .atomic)
                }
                return id
            }()
            let c = PDFPageContent(
                pdfDocumentId: newDocId,
                pageIndex: p.pageIndex,
                originalPageWidth: p.originalPageWidth,
                originalPageHeight: p.originalPageHeight
            )
            c.extractedText = p.extractedText
            element.pdfPageContent = c
            pdfPageContentIdMap[p.contentRef] = c.id
        case .highlight:
            guard let h = ae.highlight else { return }
            let c = HighlightContent(
                pdfPageContentId: pdfPageContentIdMap[h.pdfPageRef] ?? UUID(),
                rectOriginX: h.rectOriginX, rectOriginY: h.rectOriginY,
                rectWidth: h.rectWidth, rectHeight: h.rectHeight,
                style: HighlightStyle(rawValue: h.style) ?? .highlight,
                colorVariant: h.colorVariant
            )
            c.capturedText = h.capturedText
            element.highlightContent = c
        }
        context.insert(element)
    }

    private static func uniqueTitle(_ base: String, storage: StorageService) -> String {
        let existing = Set(storage.fetchAllNotebooks().map(\.title))
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "Shared Notebook" : trimmed
        guard existing.contains(candidate) else { return candidate }
        var n = 2
        while existing.contains("\(candidate) (\(n))") { n += 1 }
        return "\(candidate) (\(n))"
    }
}
