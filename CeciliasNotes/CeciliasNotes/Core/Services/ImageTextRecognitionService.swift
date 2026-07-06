import Foundation
import Vision

/// On-device text recognition for raster images — Vision
/// `VNRecognizeTextRequest`, no network. Shared by Mac image OCR
/// and future search indexing.
enum ImageTextRecognitionService {

    static func recognise(cgImage: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            let lines = observations
                .sorted { a, b in
                    let ay = 1 - (a.boundingBox.origin.y + a.boundingBox.height)
                    let by = 1 - (b.boundingBox.origin.y + b.boundingBox.height)
                    if abs(ay - by) > 0.02 { return ay < by }
                    return a.boundingBox.origin.x < b.boundingBox.origin.x
                }
                .compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }

    static func recognise(data: Data) async -> String? {
        guard let image = PlatformImageFactory.from(data: data),
              let cg = PlatformImageFactory.cgImage(from: image) else { return nil }
        let text = await recognise(cgImage: cg)
        return text.isEmpty ? nil : text
    }
}
