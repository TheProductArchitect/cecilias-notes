import Foundation
import PencilKit
import Vision

/// On-device OCR over a `PKDrawing`. Routes through Vision's
/// `VNRecognizeTextRequest` — Apple framework, runs locally, **no
/// network**. Read-only over the drawing data; never mutates the
/// `PKDrawing` or any model.
///
/// Two outputs per call:
///   • `lines`     — the raw recognised strings, in roughly top-to-
///     bottom reading order. Used for snippet generation and for
///     `keywords` donations to CoreSpotlight.
///   • `joined`    — `lines` joined by newlines, ready to slice for
///     ±40-char match windows.
///
/// Vision's bounding boxes are emitted in normalised (0…1, y-up)
/// coordinates anchored to the image's bottom-left corner. We flip
/// y to top-left so callers can plot snippets without doing the
/// conversion themselves.
enum HandwritingOCRService {

    struct Line: Sendable {
        let text: String
        /// Origin of the recognised box, normalised 0…1, top-left origin.
        let originNormalised: CGPoint
    }

    struct Output: Sendable {
        let lines: [Line]
        let joined: String
    }

    /// Rasterise `drawing` and run text recognition. Returns an empty
    /// `Output` for empty drawings — Vision wastes work on blank
    /// inputs. Entirely off the main thread: `PKDrawing.image(from:scale:)`
    /// is documented as safe to call from any thread on iOS 14+ — it
    /// rasterises via Core Graphics, not UIKit's main-thread drawing
    /// stack — so the rasterisation pass and the Vision request both
    /// run on the utility queue.
    static func recognise(
        drawing: PKDrawing,
        pageSize: CGSize
    ) async -> Output {
        let bounds = drawing.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            return Output(lines: [], joined: "")
        }

        // Render the drawing at 2× screen scale into the page-sized
        // rect (not the drawing's tight bounds — Vision benefits from
        // the spatial layout being preserved). The rendered image
        // gets thrown away after the request resolves; we don't
        // persist any pixel data.
        let imageRect = CGRect(origin: .zero, size: pageSize)
        let scale: CGFloat = 2.0

        return await withCheckedContinuation { (cont: CheckedContinuation<Output, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let uiImage = drawing.image(from: imageRect, scale: scale)
                guard let cg = PlatformImageFactory.cgImage(from: uiImage) else {
                    cont.resume(returning: Output(lines: [], joined: ""))
                    return
                }
                let request = VNRecognizeTextRequest { request, _ in
                    let observations =
                        (request.results as? [VNRecognizedTextObservation]) ?? []

                    // Top-to-bottom, then left-to-right reading order.
                    // Vision's normalised box has the origin in the
                    // bottom-left; flip y so `y == 0` is the top of
                    // the page.
                    let ordered = observations
                        .compactMap { obs -> Line? in
                            guard let best = obs.topCandidates(1).first else { return nil }
                            let bb   = obs.boundingBox
                            let yTop = 1.0 - (bb.origin.y + bb.height)
                            return Line(
                                text:             best.string,
                                originNormalised: CGPoint(x: bb.origin.x, y: yTop)
                            )
                        }
                        .sorted { lhs, rhs in
                            // Bucket lines into ~3% vertical bands so
                            // we don't flip-flop across word-level
                            // baseline jitter.
                            let band = 0.03
                            let ly   = (lhs.originNormalised.y / band).rounded()
                            let ry   = (rhs.originNormalised.y / band).rounded()
                            if ly != ry { return ly < ry }
                            return lhs.originNormalised.x < rhs.originNormalised.x
                        }

                    let joined = ordered.map(\.text).joined(separator: "\n")
                    cont.resume(returning: Output(lines: ordered, joined: joined))
                }
                request.recognitionLevel       = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    // Recognition failure is non-fatal — index gets
                    // an empty entry, search just skips this page.
                    cont.resume(returning: Output(lines: [], joined: ""))
                }
            }
        }
    }
}
