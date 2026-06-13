import Foundation
import SwiftData
import UIKit

/// Library-context entry: ingest a single image dropped by the
/// share extension into either a new notebook (with the user's
/// chosen subject) or as a new page appended to an existing
/// notebook. Mirrors `PDFReferenceImporter.importPagesFromLibrary`
/// in shape so the share-inbox flow reads consistently across
/// PDFs and images.
@MainActor
enum ShareImageImporter {

    enum Destination {
        /// Create a new notebook in the picked subject. A single
        /// blank page is created (via `StorageService.createPage`),
        /// and the image lands centred on it at ~60% page width.
        case newNotebook(subjectId: UUID?)
        /// Append a fresh blank page to an existing notebook and
        /// drop the image on it.
        case existingNotebook(notebookId: UUID)
    }

    /// Default normalised width for inserted images. ~60% of the
    /// page keeps the image visible without dominating the entire
    /// canvas; the user can resize after import.
    private static let targetWidth: Double = 0.6

    @discardableResult
    static func importImage(
        from sourceURL: URL,
        destination: Destination
    ) async -> UUID? {
        guard let data = try? Data(contentsOf: sourceURL),
              let image = UIImage(data: data) else { return nil }

        let context = StorageService.shared.context

        // 1. Resolve target notebook.
        let targetNotebook: Notebook
        switch destination {
        case .newNotebook(let subjectId):
            do {
                targetNotebook = try StorageService.shared.createNotebook(
                    title: defaultNotebookTitle(from: sourceURL),
                    subjectId: subjectId,
                    coverColorHex: "#FAFAF8",
                    coverTexture: .none,
                    pageSize: .a4,
                    template: .blank
                )
            } catch {
                #if DEBUG
                print("[ShareImage] createNotebook failed: \(error)")
                #endif
                return nil
            }
        case .existingNotebook(let id):
            let descriptor = FetchDescriptor<Notebook>(
                predicate: #Predicate<Notebook> { $0.id == id }
            )
            guard let existing = (try? context.fetch(descriptor))?.first else {
                #if DEBUG
                print("[ShareImage] existingNotebook(\(id)) not found")
                #endif
                return nil
            }
            targetNotebook = existing
        }

        // 2. Append a fresh page to the target.
        let existingPages = (targetNotebook.pages ?? [])
            .filter { !$0.isDeleted }
            .map(\.pageNumber)
        let anchor = existingPages.max() ?? 0
        guard let newPage = try? StorageService.shared.createPage(
            in: targetNotebook,
            after: anchor,
            pageSize: targetNotebook.pageSize,
            backgroundTemplate: targetNotebook.defaultTemplate
        ) else { return nil }

        // 3. Write the image bytes through MediaStorage and build
        // the matching `ImageContent` + `PageElement` rows.
        let contentId = UUID()
        let format: MediaStorage.ImageFormat = imageFormat(for: sourceURL)
        guard let written = await MediaStorage.writeImageReturningBytes(
            image, id: contentId, format: format
        ) else { return nil }

        let aspect = Double(image.size.height) / max(1, Double(image.size.width))
        let normalisedHeight = min(0.85, targetWidth * aspect)
        let normalisedX = max(0, (1 - targetWidth) / 2)
        let normalisedY = max(0, (1 - normalisedHeight) / 2)

        let element = PageElement(
            id: UUID(),
            pageId: newPage.id,
            notebookId: targetNotebook.id,
            kind: .image,
            normalizedX: normalisedX,
            normalizedY: normalisedY,
            normalizedWidth: targetWidth,
            normalizedHeight: max(0.05, normalisedHeight),
            zIndex: 0
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

        do { try context.save() } catch {
            #if DEBUG
            print("[ShareImage] save failed: \(error)")
            #endif
            return nil
        }
        return targetNotebook.id
    }

    private static func defaultNotebookTitle(from url: URL) -> String {
        let trimmed = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Imported Image" : trimmed
    }

    /// Map the file extension to a `MediaStorage.ImageFormat` so
    /// we round-trip the source format where possible. PNG round-
    /// trips losslessly; everything else re-encodes to JPEG at 0.85.
    private static func imageFormat(for url: URL) -> MediaStorage.ImageFormat {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        default:    return .jpeg(quality: 0.85)
        }
    }
}
