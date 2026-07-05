import AppKit
import SwiftData
import UniformTypeIdentifiers

@MainActor
enum MacImportService {
    private static let targetWidth: Double = 0.6

    static func importImageURL(
        _ sourceURL: URL,
        pageId: UUID,
        notebookId: UUID,
        context: ModelContext
    ) async -> Bool {
        guard let data = try? Data(contentsOf: sourceURL),
              let image = PlatformImageFactory.from(data: data) else { return false }

        let pageDescriptor = FetchDescriptor<Page>(
            predicate: #Predicate { $0.id == pageId }
        )
        let notebookDescriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.id == notebookId }
        )
        guard let page = (try? context.fetch(pageDescriptor))?.first,
              let notebook = (try? context.fetch(notebookDescriptor))?.first else { return false }

        let contentId = UUID()
        let ext = sourceURL.pathExtension.lowercased()
        let format: MediaStorage.ImageFormat = ext == "png" ? .png : .jpeg(quality: 0.88)
        guard let written = await MediaStorage.writeImageReturningBytes(image, id: contentId, format: format)
        else { return false }

        let aspect = Double(image.size.height) / max(1, Double(image.size.width))
        let normalisedHeight = min(0.85, targetWidth * aspect)
        let normalisedX = max(0, (1 - targetWidth) / 2)
        let normalisedY = max(0, (1 - normalisedHeight) / 2)

        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pid && $0.deletedAt == nil }
        )
        let maxZ = ((try? context.fetch(descriptor)) ?? []).map(\.zIndex).max() ?? 0

        let element = PageElement(
            pageId: page.id,
            notebookId: notebook.id,
            kind: .image,
            normalizedX: normalisedX,
            normalizedY: normalisedY,
            normalizedWidth: targetWidth,
            normalizedHeight: max(0.05, normalisedHeight),
            zIndex: maxZ + 1
        )
        let content = ImageContent(
            id: contentId,
            filename: "\(contentId).\(format.fileExtension)",
            fileFormat: format.fileExtension,
            originalPixelWidth: Int(image.size.width),
            originalPixelHeight: Int(image.size.height),
            imageData: written.data
        )
        element.imageContent = content
        context.insert(element)
        page.updatedAt = Date()
        notebook.updatedAt = Date()
        try? context.save()
        return true
    }

    static func importPDFAsNotebook(
        from sourceURL: URL,
        subjectId: UUID?,
        storage: StorageService
    ) async -> UUID? {
        // Minimal path: create notebook and defer full PDF-as-notebook to a follow-up.
        // For M3, create a notebook with a placeholder title from the filename.
        let title = sourceURL.deletingPathExtension().lastPathComponent
        do {
            let notebook = try storage.createNotebook(
                title: title.isEmpty ? "Imported PDF" : title,
                subjectId: subjectId,
                coverColorHex: "#FAFAF8",
                coverTexture: .none,
                pageSize: .a4,
                template: .blank
            )
            return notebook.id
        } catch {
            return nil
        }
    }
}
