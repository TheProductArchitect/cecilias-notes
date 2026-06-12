import UIKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers

// MARK: - ProcessedImage

struct ProcessedImage {
    let id: UUID
    let fileName: String           // "{id}.jpg"
    let thumbnailFileName: String  // "{id}_thumb.jpg"
    let fileSizeBytes: Int64
    let originalSize: CGSize       // points (pixels / screenScale used for normalisation)
    let fileURL: URL
    let thumbnailURL: URL
    /// Encoded JPEG bytes that were just written to `fileURL`.
    /// Carried alongside the file path so the caller can stash them
    /// in `ImageContent.imageData` (the sync-friendly column) in
    /// the same step — no re-read of the file we just wrote.
    let fullData: Data
}

// MARK: - ImageInput

enum ImageInput {
    case uiImage(UIImage)
    case fileURL(URL)              // local file (PDF page, document camera)
    case data(Data, uti: String)   // raw bytes + type identifier
}

// MARK: - ImageProcessingService

actor ImageProcessingService {

    static let shared = ImageProcessingService()

    private let maxLongestEdge: CGFloat = 4096
    private let fullQuality: CGFloat    = 0.88
    private let thumbQuality: CGFloat   = 0.75
    private let thumbMaxDimension: CGFloat = 400

    // MARK: - Public

    /// Full processing pipeline. Returns ProcessedImage with both files written to disk.
    func processImage(_ input: ImageInput, mediaDir: URL) async throws -> ProcessedImage {
        let id  = UUID()
        let raw = try decode(input)
        let oriented = applyExifOrientation(raw)
        let scaled   = downscaleIfNeeded(oriented)

        let fileURL  = mediaDir.appendingPathComponent(id.uuidString + ".jpg")
        let thumbURL = mediaDir.appendingPathComponent(id.uuidString + "_thumb.jpg")

        guard let fullJpeg = scaled.jpegData(compressionQuality: fullQuality) else {
            throw ImageProcessingError.compressionFailed
        }
        try fullJpeg.write(to: fileURL, options: .atomic)

        let thumb = thumbnail(from: scaled)
        if let thumbJpeg = thumb.jpegData(compressionQuality: thumbQuality) {
            try thumbJpeg.write(to: thumbURL, options: .atomic)
        }

        return ProcessedImage(
            id:               id,
            fileName:         id.uuidString + ".jpg",
            thumbnailFileName: id.uuidString + "_thumb.jpg",
            fileSizeBytes:    Int64(fullJpeg.count),
            originalSize:     scaled.size,
            fileURL:          fileURL,
            thumbnailURL:     thumbURL,
            fullData:         fullJpeg
        )
    }

    /// Rasterise a single PDF page to UIImage at 150dpi.
    func rasterisePDFPage(_ page: CGPDFPage) async throws -> UIImage {
        let mediaBox = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 150.0 / 72.0   // 150dpi from 72pt PDF points
        let size = CGSize(width: mediaBox.width * scale, height: mediaBox.height * scale)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.setFillColor(UIColor.white.cgColor)
            cgCtx.fill(CGRect(origin: .zero, size: size))
            cgCtx.translateBy(x: 0, y: size.height)
            cgCtx.scaleBy(x: scale, y: -scale)
            cgCtx.drawPDFPage(page)
        }
    }

    // MARK: - Decode

    private func decode(_ input: ImageInput) throws -> UIImage {
        switch input {
        case .uiImage(let img):
            return img

        case .fileURL(let url):
            guard let data = try? Data(contentsOf: url) else {
                throw ImageProcessingError.cannotReadFile
            }
            return try decode(.data(data, uti: url.pathExtension.lowercased()))

        case .data(let data, let uti):
            // GIF: extract first frame via ImageIO
            if uti == "gif" || uti == "com.compuserve.gif" {
                if let src = CGImageSourceCreateWithData(data as CFData, nil),
                   let cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    return UIImage(cgImage: cgImg)
                }
            }
            // WebP and HEIC are handled natively by UIImage on iOS 14+
            if let img = UIImage(data: data) { return img }
            // Fallback: try ImageIO
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return UIImage(cgImage: cgImg)
            }
            throw ImageProcessingError.unsupportedFormat
        }
    }

    // MARK: - Orient

    private func applyExifOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    }

    // MARK: - Scale

    private func downscaleIfNeeded(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxLongestEdge else { return image }
        let scale  = maxLongestEdge / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    // MARK: - Thumbnail

    private func thumbnail(from image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > thumbMaxDimension else { return image }
        let scale   = thumbMaxDimension / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

// MARK: - Errors

enum ImageProcessingError: LocalizedError {
    case unsupportedFormat
    case cannotReadFile
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:  return "This file format isn't supported."
        case .cannotReadFile:     return "Couldn't read the file."
        case .compressionFailed:  return "Image compression failed."
        }
    }
}
