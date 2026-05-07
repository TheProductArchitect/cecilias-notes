import Foundation
import PencilKit
import SwiftData
import UIKit

// MARK: - StorageService

@MainActor
final class StorageService: ObservableObject {

    // MARK: Singleton
    static let shared = StorageService()

    // MARK: Directory URLs

    static var inkDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ink")
    }
    static var notebooksDirectoryURL: URL {
        inkDirectoryURL.appendingPathComponent("Notebooks")
    }

    // MARK: Core

    private let container: ModelContainer
    private let context: ModelContext

    /// Designated init — callers pass a container for testability.
    init(container: ModelContainer) {
        self.container = container
        self.context   = container.mainContext
        try? FileManager.default.createDirectory(
            at: Self.notebooksDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    /// Convenience init used by the singleton and InkApp. Container failure is
    /// genuinely terminal (no DB → no app), so we surface a precondition with a
    /// clear message rather than a bare `try!`.
    private convenience init() {
        do {
            let c = try ModelContainer.inkContainer()
            self.init(container: c)
        } catch {
            // Safe: SwiftData container init only fails when the on-disk SQLite
            // file is corrupt or Application Support is unwritable — unrecoverable
            // at startup. A descriptive crash is more useful than a zombie app.
            preconditionFailure( // Safe: terminal startup failure
                "Failed to open the Ink SwiftData container: \(error). "
              + "This is unrecoverable; the app cannot start without on-disk storage."
            )
        }
    }
}

// MARK: - File helpers

private extension StorageService {
    func notebookDir(_ notebookId: UUID) -> URL {
        Self.notebooksDirectoryURL.appendingPathComponent(notebookId.uuidString)
    }
    func mediaDir(_ notebookId: UUID) -> URL {
        notebookDir(notebookId).appendingPathComponent("media")
    }
    func audioDir(_ notebookId: UUID) -> URL {
        notebookDir(notebookId).appendingPathComponent("audio")
    }
    func exportsDir(_ notebookId: UUID) -> URL {
        notebookDir(notebookId).appendingPathComponent("exports")
    }

    func ensureDir(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw InkStorageError.fileWriteFailed(error)
        }
    }

    func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .flatMap { Int64($0) } ?? 0
            total += size
        }
        return total
    }
}

// MARK: - Subjects

extension StorageService {

    func createSubject(name: String, colorHex: String) throws -> Subject {
        guard name.count <= 50 else { throw InkStorageError.fileSizeLimitExceeded }
        guard InkColorPresets.subjectColors.contains(colorHex) else {
            throw InkStorageError.fileWriteFailed(
                NSError(domain: "Ink", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid subject colour hex: \(colorHex)"])
            )
        }
        let nextOrder = (fetchSubjects().map(\.sortOrder).max() ?? -1) + 1
        let subject = Subject(name: name, colorHex: colorHex, sortOrder: nextOrder)
        context.insert(subject)
        try context.save()
        return subject
    }

    func fetchSubjects() -> [Subject] {
        let descriptor = FetchDescriptor<Subject>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func updateSubject(_ subject: Subject, name: String?, colorHex: String?) throws {
        if let name {
            guard name.count <= 50 else { throw InkStorageError.fileSizeLimitExceeded }
            subject.name = name
        }
        if let colorHex {
            guard InkColorPresets.subjectColors.contains(colorHex) else {
                throw InkStorageError.fileWriteFailed(
                    NSError(domain: "Ink", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid colour hex"])
                )
            }
            subject.colorHex = colorHex
        }
        subject.updatedAt = Date()
        try context.save()
    }

    /// Soft-deletes the subject and moves its notebooks to Uncategorised (subjectId = nil).
    func deleteSubject(_ subject: Subject) throws {
        for notebook in subject.notebooks where !notebook.isDeleted {
            notebook.subjectId = nil
            notebook.updatedAt = Date()
        }
        subject.isDeleted = true
        subject.deletedAt = Date()
        subject.updatedAt = Date()
        try context.save()
    }

    func reorderSubjects(_ subjects: [Subject]) throws {
        for (index, subject) in subjects.enumerated() {
            subject.sortOrder = index
            subject.updatedAt = Date()
        }
        try context.save()
    }
}

// MARK: - Notebooks

extension StorageService {

    func createNotebook(
        title: String,
        subjectId: UUID?,
        coverColorHex: String,
        coverTexture: CoverTexture,
        pageSize: PageSize,
        template: PageTemplate
    ) throws -> Notebook {
        guard title.count <= 80 else { throw InkStorageError.fileSizeLimitExceeded }

        let notebook = Notebook(
            title: title,
            subjectId: subjectId,
            coverColorHex: coverColorHex,
            coverTexture: coverTexture,
            pageSize: pageSize,
            defaultTemplate: template
        )
        let nextOrder = (fetchNotebooks(subjectId: subjectId).map(\.sortOrder).max() ?? -1) + 1
        notebook.sortOrder = nextOrder
        context.insert(notebook)

        // Link to subject relationship
        if let subjectId {
            let pred = #Predicate<Subject> { $0.id == subjectId && $0.isDeleted == false }
            if let subject = (try? context.fetch(FetchDescriptor(predicate: pred)))?.first {
                subject.notebooks.append(notebook)
            }
        }

        // Create first page
        let page = Page(
            notebookId: notebook.id,
            pageNumber: 1,
            pageSize: pageSize,
            backgroundTemplate: template
        )
        context.insert(page)
        notebook.pages.append(page)
        notebook.totalPageCount = 1

        try context.save()
        try ensureDir(notebookDir(notebook.id))
        scheduleSpotlightReindex(for: notebook)
        scheduleWidgetSnapshot()
        return notebook
    }

    func fetchNotebooks(subjectId: UUID?) -> [Notebook] {
        let descriptor: FetchDescriptor<Notebook>
        if let subjectId {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.subjectId == subjectId && $0.isDeleted == false },
                sortBy: [SortDescriptor(\.isPinned, order: .reverse),
                         SortDescriptor(\.sortOrder)]
            )
        } else {
            // nil subjectId = Uncategorised
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.subjectId == nil && $0.isDeleted == false },
                sortBy: [SortDescriptor(\.isPinned, order: .reverse),
                         SortDescriptor(\.sortOrder)]
            )
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchAllNotebooks() -> [Notebook] {
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchPinnedNotebooks() -> [Notebook] {
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isPinned == true && $0.isDeleted == false },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func updateNotebook(
        _ notebook: Notebook,
        title: String?,
        coverColorHex: String?,
        isPinned: Bool?,
        tags: [String]?
    ) throws {
        if let title {
            guard title.count <= 80 else { throw InkStorageError.fileSizeLimitExceeded }
            notebook.title = title
        }
        if let colorHex = coverColorHex { notebook.coverColorHex = colorHex }
        if let pinned = isPinned { notebook.isPinned = pinned }
        if let tags {
            let validated = tags.prefix(5).map { String($0.prefix(20)) }
            notebook.tags = Array(validated)
        }
        notebook.updatedAt = Date()
        try context.save()
        scheduleSpotlightReindex(for: notebook)
        scheduleWidgetSnapshot()
    }

    func moveNotebook(_ notebook: Notebook, to subjectId: UUID?) throws {
        // Remove from old subject relationship
        if let oldSubjectId = notebook.subjectId {
            let pred = #Predicate<Subject> { $0.id == oldSubjectId }
            if let old = (try? context.fetch(FetchDescriptor(predicate: pred)))?.first {
                old.notebooks.removeAll { $0.id == notebook.id }
            }
        }
        notebook.subjectId = subjectId
        notebook.updatedAt = Date()

        // Add to new subject relationship
        if let subjectId {
            let pred = #Predicate<Subject> { $0.id == subjectId && $0.isDeleted == false }
            if let new = (try? context.fetch(FetchDescriptor(predicate: pred)))?.first {
                new.notebooks.append(notebook)
            }
        }
        try context.save()
    }

    func deleteNotebook(_ notebook: Notebook) throws {
        notebook.isDeleted = true
        notebook.deletedAt = Date()
        notebook.updatedAt = Date()
        try context.save()
        let id = notebook.id
        Task { await SpotlightService.shared.removeNotebook(id: id) }
        scheduleWidgetSnapshot()
    }

    func duplicateNotebook(_ notebook: Notebook) async throws -> Notebook {
        let copy = Notebook(
            title: notebook.title + " Copy",
            subjectId: notebook.subjectId,
            coverColorHex: notebook.coverColorHex,
            coverTexture: notebook.coverTexture,
            pageSize: notebook.pageSize,
            defaultTemplate: notebook.defaultTemplate
        )
        copy.tags = notebook.tags
        copy.isPinned = false
        context.insert(copy)

        if let subjectId = notebook.subjectId {
            let pred = #Predicate<Subject> { $0.id == subjectId && $0.isDeleted == false }
            if let subject = (try? context.fetch(FetchDescriptor(predicate: pred)))?.first {
                subject.notebooks.append(copy)
            }
        }

        let pages = fetchPages(in: notebook)
        for page in pages {
            let newPage = Page(
                notebookId: copy.id,
                pageNumber: page.pageNumber,
                pageSize: page.pageSize,
                backgroundTemplate: page.backgroundTemplate
            )
            newPage.strokeData     = page.strokeData
            newPage.strokeDataSize = page.strokeDataSize
            context.insert(newPage)
            copy.pages.append(newPage)

            for block in page.textBlocks where !block.isDeleted {
                let newBlock = TextBlock(
                    pageId: newPage.id, x: block.x, y: block.y,
                    width: block.width, height: block.height
                )
                newBlock.content      = block.content
                newBlock.richTextData = block.richTextData
                newBlock.rotation     = block.rotation
                newBlock.zIndex       = block.zIndex
                context.insert(newBlock)
                newPage.textBlocks.append(newBlock)
            }

            for attachment in page.mediaAttachments where !attachment.isDeleted {
                let newAtt = MediaAttachment(
                    pageId: newPage.id,
                    notebookId: copy.id,
                    type: attachment.type,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType,
                    fileSizeBytes: attachment.fileSizeBytes,
                    originalWidth: attachment.originalWidth,
                    originalHeight: attachment.originalHeight,
                    x: attachment.x, y: attachment.y,
                    width: attachment.width, height: attachment.height
                )
                newAtt.rotation = attachment.rotation
                newAtt.zIndex   = attachment.zIndex
                newAtt.caption  = attachment.caption
                context.insert(newAtt)
                newPage.mediaAttachments.append(newAtt)

                try await copyFile(from: mediaURL(for: attachment), to: mediaURL(for: newAtt))
                try await copyFile(from: thumbnailURL(for: attachment), to: thumbnailURL(for: newAtt))
            }

            for annotation in page.audioAnnotations where !annotation.isDeleted {
                let newAnn = AudioAnnotation(
                    pageId: newPage.id,
                    notebookId: copy.id,
                    fileName: annotation.fileName,
                    durationSeconds: annotation.durationSeconds,
                    fileSizeBytes: annotation.fileSizeBytes,
                    pageX: annotation.pageX,
                    pageY: annotation.pageY
                )
                newAnn.transcription         = annotation.transcription
                newAnn.transcriptionSegments = annotation.transcriptionSegments
                newAnn.recordedAt            = annotation.recordedAt
                context.insert(newAnn)
                newPage.audioAnnotations.append(newAnn)

                try await copyFile(from: audioURL(for: annotation), to: audioURL(for: newAnn))
            }
        }

        copy.totalPageCount = copy.pages.count
        try context.save()
        try ensureDir(notebookDir(copy.id))
        scheduleSpotlightReindex(for: copy)
        scheduleWidgetSnapshot()
        return copy
    }

    func reorderNotebooks(_ notebooks: [Notebook], in subjectId: UUID?) throws {
        for (index, notebook) in notebooks.enumerated() {
            notebook.sortOrder = index
            notebook.updatedAt = Date()
        }
        try context.save()
    }

    func updateThumbnail(for notebook: Notebook, image: UIImage) throws {
        guard let data = image.jpegData(compressionQuality: 0.80) else { return }
        notebook.thumbnailData = data
        notebook.updatedAt     = Date()
        try context.save()
    }

    // MARK: - Private file copy helper

    private func copyFile(from src: URL, to dst: URL) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
        } catch {
            throw InkStorageError.fileWriteFailed(error)
        }
    }
}

// MARK: - Pages

extension StorageService {

    func createPage(in notebook: Notebook, after pageNumber: Int?) throws -> Page {
        let existingPages = fetchPages(in: notebook)
        let insertAfter   = pageNumber ?? existingPages.map(\.pageNumber).max() ?? 0

        // Shift pages after insertion point
        for page in existingPages where page.pageNumber > insertAfter {
            page.pageNumber += 1
            page.updatedAt  = Date()
        }

        let newPage = Page(
            notebookId: notebook.id,
            pageNumber: insertAfter + 1,
            pageSize: notebook.pageSize,
            backgroundTemplate: notebook.defaultTemplate
        )
        context.insert(newPage)
        notebook.pages.append(newPage)
        notebook.totalPageCount = notebook.pages.filter { !$0.isDeleted }.count
        notebook.updatedAt      = Date()
        try context.save()
        return newPage
    }

    func fetchPages(in notebook: Notebook) -> [Page] {
        let id = notebook.id
        let descriptor = FetchDescriptor<Page>(
            predicate: #Predicate { $0.notebookId == id && $0.isDeleted == false },
            sortBy: [SortDescriptor(\.pageNumber)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func updatePageStrokes(_ page: Page, drawing: PKDrawing) throws {
        let data            = drawing.dataRepresentation()
        page.strokeData     = data
        page.strokeDataSize = data.count
        page.updatedAt      = Date()
        // Bump the parent notebook's updatedAt so the Library + widget reflect activity.
        if let nb = notebookById(page.notebookId) {
            nb.updatedAt = Date()
            scheduleSpotlightReindex(for: nb)
        }
        try context.save()
        scheduleWidgetSnapshot()
    }

    /// Soft-deletes the page and renumbers all subsequent pages in the notebook.
    func deletePage(_ page: Page) throws {
        let notebookId  = page.notebookId
        let deletedNum  = page.pageNumber

        page.isDeleted  = true
        page.deletedAt  = Date()
        page.updatedAt  = Date()

        // Renumber subsequent pages
        let pred        = #Predicate<Page> { $0.notebookId == notebookId && $0.isDeleted == false }
        let remaining   = ((try? context.fetch(FetchDescriptor(predicate: pred, sortBy: [SortDescriptor(\.pageNumber)]))) ?? [])
            .filter { $0.pageNumber > deletedNum }
        for p in remaining {
            p.pageNumber -= 1
            p.updatedAt   = Date()
        }

        // Update notebook count
        if let nb = notebookById(notebookId) {
            nb.totalPageCount = nb.pages.filter { !$0.isDeleted }.count
            nb.updatedAt      = Date()
        }
        try context.save()
    }

    func duplicatePage(_ page: Page) throws -> Page {
        guard let notebook = notebookById(page.notebookId) else {
            throw InkStorageError.notebookNotFound
        }
        let insertAfter  = page.pageNumber
        let existingPages = fetchPages(in: notebook)

        for p in existingPages where p.pageNumber > insertAfter {
            p.pageNumber += 1
            p.updatedAt   = Date()
        }

        let newPage = Page(
            notebookId: notebook.id,
            pageNumber: insertAfter + 1,
            pageSize: page.pageSize,
            backgroundTemplate: page.backgroundTemplate
        )
        newPage.strokeData     = page.strokeData
        newPage.strokeDataSize = page.strokeDataSize
        context.insert(newPage)
        notebook.pages.append(newPage)

        for block in page.textBlocks where !block.isDeleted {
            let nb = TextBlock(
                pageId: newPage.id, x: block.x, y: block.y,
                width: block.width, height: block.height
            )
            nb.content      = block.content
            nb.richTextData = block.richTextData
            nb.rotation     = block.rotation
            nb.zIndex       = block.zIndex
            context.insert(nb)
            newPage.textBlocks.append(nb)
        }

        notebook.totalPageCount = notebook.pages.filter { !$0.isDeleted }.count
        notebook.updatedAt      = Date()
        try context.save()
        return newPage
    }

    func movePage(_ page: Page, to targetPageNumber: Int) throws {
        guard let notebook = notebookById(page.notebookId) else {
            throw InkStorageError.notebookNotFound
        }
        let pages = fetchPages(in: notebook)
        guard targetPageNumber >= 1 && targetPageNumber <= pages.count else {
            throw InkStorageError.pageNumberInvalid
        }

        let currentNumber = page.pageNumber
        let target        = targetPageNumber

        if currentNumber == target { return }

        let movingForward = target > currentNumber
        for p in pages where p.id != page.id {
            if movingForward, p.pageNumber > currentNumber, p.pageNumber <= target {
                p.pageNumber -= 1
                p.updatedAt   = Date()
            } else if !movingForward, p.pageNumber < currentNumber, p.pageNumber >= target {
                p.pageNumber += 1
                p.updatedAt   = Date()
            }
        }
        page.pageNumber = target
        page.updatedAt  = Date()
        try context.save()
    }

    // MARK: Private

    private func notebookById(_ id: UUID) -> Notebook? {
        let pred = #Predicate<Notebook> { $0.id == id && $0.isDeleted == false }
        return (try? context.fetch(FetchDescriptor(predicate: pred)))?.first
    }
}

// MARK: - Text Blocks

extension StorageService {

    func createTextBlock(on page: Page, at normalizedRect: CGRect) throws -> TextBlock {
        let block = TextBlock(
            pageId: page.id,
            x: normalizedRect.origin.x,
            y: normalizedRect.origin.y,
            width: normalizedRect.width,
            height: normalizedRect.height
        )
        let maxZ = (page.textBlocks.map(\.zIndex).max() ?? -1) + 1
        block.zIndex = maxZ
        context.insert(block)
        page.textBlocks.append(block)
        page.updatedAt = Date()
        try context.save()
        return block
    }

    func updateTextBlock(
        _ block: TextBlock,
        richText: NSAttributedString,
        rect: CGRect?
    ) throws {
        block.content      = richText.string
        block.richTextData = try NSKeyedArchiver.archivedData(
            withRootObject: richText,
            requiringSecureCoding: false
        )
        if let rect {
            block.x      = rect.origin.x
            block.y      = rect.origin.y
            block.width  = rect.width
            block.height = rect.height
        }
        block.updatedAt = Date()
        try context.save()
    }

    func deleteTextBlock(_ block: TextBlock) throws {
        block.isDeleted = true
        block.deletedAt = Date()
        block.updatedAt = Date()
        try context.save()
    }
}

// MARK: - Media Attachments

extension StorageService {

    func addImage(
        to page: Page,
        imageData: Data,
        mimeType: String,
        at normalizedRect: CGRect
    ) async throws -> MediaAttachment {
        guard let image = UIImage(data: imageData) else {
            throw InkStorageError.fileWriteFailed(
                NSError(domain: "Ink", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot decode image data"])
            )
        }

        let attachment = MediaAttachment(
            pageId: page.id,
            notebookId: page.notebookId,
            type: .image,
            fileName: "\(UUID().uuidString).jpg",
            mimeType: mimeType,
            fileSizeBytes: Int64(imageData.count),
            originalWidth: Int(image.size.width),
            originalHeight: Int(image.size.height),
            x: normalizedRect.origin.x,
            y: normalizedRect.origin.y,
            width: normalizedRect.width,
            height: normalizedRect.height
        )

        let zMax = (page.mediaAttachments.map(\.zIndex).max() ?? -1) + 1
        attachment.zIndex = zMax

        context.insert(attachment)
        page.mediaAttachments.append(attachment)
        page.updatedAt = Date()

        // Write files on background task
        let mediaDestURL  = mediaURL(for: attachment)
        let thumbDestURL  = thumbnailURL(for: attachment)
        let notebookId    = page.notebookId

        Task.detached(priority: .utility) { [weak self] in
            guard self != nil else { return }
            let fm = FileManager.default
            let dir = StorageService.notebooksDirectoryURL
                .appendingPathComponent(notebookId.uuidString)
                .appendingPathComponent("media")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // Full resolution
            if let jpeg = image.jpegData(compressionQuality: 0.90) {
                try? jpeg.write(to: mediaDestURL, options: .atomic)
            }
            // Thumbnail — max 400×400pt, JPEG 75%
            if let thumb = image.thumbnailFitting(maxDimension: 400),
               let thumbJpeg = thumb.jpegData(compressionQuality: 0.75) {
                try? thumbJpeg.write(to: thumbDestURL, options: .atomic)
            }
        }

        try context.save()
        return attachment
    }

    func updateAttachment(
        _ attachment: MediaAttachment,
        rect: CGRect?,
        rotation: Double?,
        caption: String?,
        opacity: Double? = nil
    ) throws {
        if let rect {
            attachment.x      = rect.origin.x
            attachment.y      = rect.origin.y
            attachment.width  = rect.width
            attachment.height = rect.height
        }
        if let rotation { attachment.rotation = rotation }
        if let caption  { attachment.caption  = caption  }
        if let opacity  { attachment.opacity  = max(0.2, min(1.0, opacity)) }
        attachment.updatedAt = Date()
        try context.save()
    }

    func updateAttachmentZIndex(_ attachment: MediaAttachment, zIndex: Int) throws {
        attachment.zIndex    = zIndex
        attachment.updatedAt = Date()
        try context.save()
    }

    /// Replaces the file data for a cropped image and updates dimensions.
    func replaceAttachmentImage(
        _ attachment: MediaAttachment,
        jpegData: Data,
        originalWidth: Int,
        originalHeight: Int
    ) throws {
        let destURL   = mediaURL(for: attachment)
        let thumbURL  = thumbnailURL(for: attachment)
        let notebookId = attachment.notebookId

        try jpegData.write(to: destURL, options: .atomic)
        attachment.fileSizeBytes  = Int64(jpegData.count)
        attachment.originalWidth  = originalWidth
        attachment.originalHeight = originalHeight
        attachment.updatedAt = Date()
        try context.save()

        // Regenerate thumbnail off-thread
        Task.detached(priority: .utility) {
            guard let image = UIImage(data: jpegData),
                  let thumb = image.thumbnailFitting(maxDimension: 400),
                  let thumbJpeg = thumb.jpegData(compressionQuality: 0.75)
            else { return }
            try? thumbJpeg.write(to: thumbURL, options: .atomic)
        }
        _ = notebookId
    }

    /// Insert a pre-processed image (files already written to disk).
    func addPreprocessedImage(
        to page: Page,
        id: UUID,
        fileName: String,
        fileSizeBytes: Int64,
        originalWidth: Int,
        originalHeight: Int,
        at normalizedRect: CGRect
    ) throws -> MediaAttachment {
        let attachment = MediaAttachment(
            pageId: page.id,
            notebookId: page.notebookId,
            type: .image,
            fileName: fileName,
            mimeType: "image/jpeg",
            fileSizeBytes: fileSizeBytes,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            x: normalizedRect.origin.x,
            y: normalizedRect.origin.y,
            width: normalizedRect.width,
            height: normalizedRect.height
        )
        attachment.id     = id
        attachment.zIndex = (page.mediaAttachments.map(\.zIndex).max() ?? -1) + 1
        context.insert(attachment)
        page.mediaAttachments.append(attachment)
        page.updatedAt = Date()
        try context.save()
        return attachment
    }

    func deleteAttachment(_ attachment: MediaAttachment) throws {
        attachment.isDeleted = true
        attachment.deletedAt = Date()
        attachment.updatedAt = Date()
        try context.save()
        // Physical file removal deferred until "Empty Trash" or 30-day purge.
    }

    func restoreAttachment(_ attachment: MediaAttachment) throws {
        attachment.isDeleted = false
        attachment.deletedAt = nil
        attachment.updatedAt = Date()
        try context.save()
    }

    func mediaURL(for attachment: MediaAttachment) -> URL {
        mediaDir(attachment.notebookId)
            .appendingPathComponent(attachment.id.uuidString + ".jpg")
    }

    func thumbnailURL(for attachment: MediaAttachment) -> URL {
        mediaDir(attachment.notebookId)
            .appendingPathComponent(attachment.id.uuidString + "_thumb.jpg")
    }
}

// MARK: - Audio Annotations

extension StorageService {

    func addAudioAnnotation(
        to page: Page,
        fileName: String,
        duration: Double,
        at point: CGPoint
    ) throws -> AudioAnnotation {
        let annotation = AudioAnnotation(
            pageId: page.id,
            notebookId: page.notebookId,
            fileName: fileName,
            durationSeconds: duration,
            pageX: Double(point.x),
            pageY: Double(point.y)
        )
        context.insert(annotation)
        page.audioAnnotations.append(annotation)
        page.updatedAt = Date()
        try context.save()
        return annotation
    }

    func updateTranscription(
        _ annotation: AudioAnnotation,
        text: String,
        segments: [TranscriptionSegment]
    ) throws {
        annotation.transcription         = text
        annotation.transcriptionSegments = try? JSONEncoder().encode(segments)
        annotation.isTranscribed         = true
        annotation.updatedAt             = Date()
        try context.save()
    }

    func deleteAudioAnnotation(_ annotation: AudioAnnotation) throws {
        annotation.isDeleted = true
        annotation.deletedAt = Date()
        annotation.updatedAt = Date()
        try context.save()
    }

    func audioURL(for annotation: AudioAnnotation) -> URL {
        audioDir(annotation.notebookId)
            .appendingPathComponent(annotation.id.uuidString + ".m4a")
    }

    /// Called by `AudioFilePicker` after the file is already copied to the audio directory.
    func insertAudioFile(
        to page: Page,
        annotationId: UUID,
        fileName: String,
        duration: Double,
        fileSizeBytes: Int64,
        at point: CGPoint
    ) throws -> AudioAnnotation {
        let annotation = AudioAnnotation(
            id:              annotationId,
            pageId:          page.id,
            notebookId:      page.notebookId,
            fileName:        fileName,
            durationSeconds: duration,
            fileSizeBytes:   fileSizeBytes,
            pageX:           Double(point.x),
            pageY:           Double(point.y)
        )
        context.insert(annotation)
        page.audioAnnotations.append(annotation)
        page.updatedAt = Date()
        try context.save()
        return annotation
    }

    /// Writes pre-computed amplitude data (archived [Float]) for static waveform rendering.
    func updateAmplitudeData(_ annotation: AudioAnnotation, amplitudeData: Data?) throws {
        annotation.amplitudeData = amplitudeData
        annotation.updatedAt     = Date()
        try context.save()
    }

    func fetchAudioAnnotation(id: UUID) -> AudioAnnotation? {
        var descriptor = FetchDescriptor<AudioAnnotation>(
            predicate: #Predicate { $0.id == id && $0.isDeleted == false }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Moves a pin to a new normalised position.
    func moveAudioAnnotation(_ annotation: AudioAnnotation, to point: CGPoint) throws {
        annotation.pageX     = Double(point.x)
        annotation.pageY     = Double(point.y)
        annotation.updatedAt = Date()
        try context.save()
    }

}

// MARK: - Audio directory (public for AudioFilePicker)

extension StorageService {
    /// Returns the audio directory URL for a given notebook.
    func audioDirURL(notebookId: UUID) -> URL {
        Self.notebooksDirectoryURL
            .appendingPathComponent(notebookId.uuidString)
            .appendingPathComponent("audio")
    }
}

// MARK: - Search

extension StorageService {

    func search(query: String) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed.lowercased()
        var results: [SearchResult] = []

        // Build pageId → notebookId map
        let allPages = (try? context.fetch(
            FetchDescriptor<Page>(predicate: #Predicate { $0.isDeleted == false })
        )) ?? []
        let pageToNotebook: [UUID: UUID] = Dictionary(
            uniqueKeysWithValues: allPages.map { ($0.id, $0.notebookId) }
        )

        // Notebook titles
        for nb in fetchAllNotebooks() where nb.title.lowercased().contains(q) {
            results.append(SearchResult(
                notebookId: nb.id,
                pageId: nil,
                context: nb.title,
                type: .notebookTitle
            ))
        }

        // Text blocks
        let blocks = (try? context.fetch(
            FetchDescriptor<TextBlock>(predicate: #Predicate { $0.isDeleted == false })
        )) ?? []
        for block in blocks where block.content.lowercased().contains(q) {
            guard let nbId = pageToNotebook[block.pageId] else { continue }
            results.append(SearchResult(
                notebookId: nbId,
                pageId: block.pageId,
                context: String(block.content.prefix(120)),
                type: .textBlock
            ))
        }

        // Audio transcriptions
        let annotations = (try? context.fetch(
            FetchDescriptor<AudioAnnotation>(predicate: #Predicate { $0.isDeleted == false })
        )) ?? []
        for ann in annotations {
            guard let text = ann.transcription, text.lowercased().contains(q),
                  let nbId = pageToNotebook[ann.pageId] else { continue }
            results.append(SearchResult(
                notebookId: nbId,
                pageId: ann.pageId,
                context: String(text.prefix(120)),
                type: .transcription
            ))
        }

        return results
    }
}

// MARK: - Storage Info

extension StorageService {

    func localStorageUsed() async -> StorageInfo {
        let fm = FileManager.default

        let dbURL   = Self.inkDirectoryURL.appendingPathComponent("ink.sqlite")
        let dbBytes = (try? fm.attributesOfItem(atPath: dbURL.path)[.size] as? Int64) ?? 0

        var mediaBytes: Int64 = 0
        var audioBytes: Int64 = 0

        let notebookDirs = (try? fm.contentsOfDirectory(
            at: Self.notebooksDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for dir in notebookDirs {
            mediaBytes += directorySize(at: dir.appendingPathComponent("media"))
            audioBytes += directorySize(at: dir.appendingPathComponent("audio"))
        }

        return StorageInfo(
            totalBytes: dbBytes + mediaBytes + audioBytes,
            audioBytes: audioBytes,
            mediaBytes: mediaBytes,
            dbBytes: dbBytes
        )
    }

    func clearExportedPDFs() async throws {
        let fm   = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: Self.notebooksDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for dir in dirs {
            let exportsDir = dir.appendingPathComponent("exports")
            guard fm.fileExists(atPath: exportsDir.path) else { continue }
            do {
                try fm.removeItem(at: exportsDir)
                try fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)
            } catch {
                throw InkStorageError.fileWriteFailed(error)
            }
        }
    }

    func clearAudioRecordings() async throws {
        let fm   = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: Self.notebooksDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for dir in dirs {
            let aDir = dir.appendingPathComponent("audio")
            guard fm.fileExists(atPath: aDir.path) else { continue }
            do {
                try fm.removeItem(at: aDir)
                try fm.createDirectory(at: aDir, withIntermediateDirectories: true)
            } catch {
                throw InkStorageError.fileWriteFailed(error)
            }
        }
        // Soft-delete all AudioAnnotation records
        let descriptor = FetchDescriptor<AudioAnnotation>(
            predicate: #Predicate { $0.isDeleted == false }
        )
        let annotations = (try? context.fetch(descriptor)) ?? []
        let now = Date()
        for ann in annotations {
            ann.isDeleted = true
            ann.deletedAt = now
            ann.updatedAt = now
        }
        try context.save()
    }

    func exportedPDFsSizeBytes() -> Int64 {
        directorySize(at: ExportService.globalExportsDirectory)
    }

    func audioSizeBytes() -> Int64 {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: Self.notebooksDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        return dirs.reduce(0) { $0 + directorySize(at: $1.appendingPathComponent("audio")) }
    }

    func notebookCount() -> Int {
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.isDeleted == false }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    // MARK: Trash management

    /// Physically deletes all records soft-deleted more than 30 days ago.
    func purgeExpiredDeletedRecords() throws {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)

        // Subjects
        let deletedSubjects = (try? context.fetch(
            FetchDescriptor<Subject>(predicate: #Predicate { $0.isDeleted == true })
        )) ?? []
        for s in deletedSubjects where (s.deletedAt ?? .distantFuture) < cutoff {
            context.delete(s)
        }

        // Notebooks
        let deletedNotebooks = (try? context.fetch(
            FetchDescriptor<Notebook>(predicate: #Predicate { $0.isDeleted == true })
        )) ?? []
        for nb in deletedNotebooks where (nb.deletedAt ?? .distantFuture) < cutoff {
            purgeNotebookFiles(nb)
            context.delete(nb)
        }

        // Pages, blocks, attachments, annotations handled by cascade delete
        try context.save()
    }

    func emptyTrash() throws {
        let allSubjects = (try? context.fetch(
            FetchDescriptor<Subject>(predicate: #Predicate { $0.isDeleted == true })
        )) ?? []
        allSubjects.forEach { context.delete($0) }

        let allNotebooks = (try? context.fetch(
            FetchDescriptor<Notebook>(predicate: #Predicate { $0.isDeleted == true })
        )) ?? []
        for nb in allNotebooks {
            purgeNotebookFiles(nb)
            context.delete(nb)
        }
        try context.save()
    }

    private func purgeNotebookFiles(_ notebook: Notebook) {
        let dir = notebookDir(notebook.id)
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - Spotlight + widget integration (Stage 10)

extension StorageService {

    /// Debounced re-index. Caller should pass the just-saved notebook.
    func scheduleSpotlightReindex(for notebook: Notebook) {
        let id            = notebook.id
        let title         = notebook.title
        let subjectName   = notebook.subjectId.flatMap { sid in
            fetchSubjects().first { $0.id == sid }?.name
        }
        let pageCount     = notebook.totalPageCount
        let thumbnailData = notebook.thumbnailData
        let createdAt     = notebook.createdAt
        let updatedAt     = notebook.updatedAt
        let tags          = notebook.tags

        Task {
            await SpotlightService.shared.scheduleIndex(
                id: id,
                title: title,
                subjectName: subjectName,
                pageCount: pageCount,
                thumbnailData: thumbnailData,
                createdAt: createdAt,
                updatedAt: updatedAt,
                tags: tags
            )
        }
    }

    /// Re-write the App Group widget snapshot from the latest notebook list.
    /// Debounced through `WidgetDataWriter`.
    func scheduleWidgetSnapshot() {
        let summaries: [NotebookSummary] = fetchNotebooks(subjectId: nil)
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(10)
            .map { nb in
                NotebookSummary(
                    id:            nb.id,
                    title:         nb.title,
                    coverColorHex: nb.coverColorHex,
                    coverTexture:  nb.coverTexture.rawValue,
                    pageCount:     nb.totalPageCount,
                    updatedAt:     nb.updatedAt
                )
            }
        Task { await WidgetDataWriter.shared.scheduleWrite(summaries) }
    }
}

// MARK: - UIImage thumbnail helper

private extension UIImage {
    func thumbnailFitting(maxDimension: CGFloat) -> UIImage? {
        let ratio  = min(maxDimension / size.width, maxDimension / size.height)
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
