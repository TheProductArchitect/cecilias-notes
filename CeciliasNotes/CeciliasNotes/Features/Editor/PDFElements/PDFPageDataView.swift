import PDFKit
import SwiftUI
import UIKit

/// Renders one page of a PDF document inside its bounds using a
/// two-stage pipeline:
///   1. Show the cached preview PNG (`content.previewImageURL`)
///      immediately on mount — eliminates the blank-flash that an
///      async PDFKit load would otherwise produce on first paint.
///   2. Kick off an async render of the actual PDF page via
///      PDFKit at a higher resolution; swap in when ready.
///
/// The placeholder (a `doc.text` icon over the surface colour)
/// covers the case where neither the preview nor the source PDF
/// is readable — most commonly while iCloud Drive is restoring
/// the file on a fresh device.
struct PDFPageDataView: View {

    let content: PDFPageContent
    @Environment(\.theme) private var theme

    @State private var renderedImage: UIImage?
    @State private var previewImage: UIImage?
    @State private var failed: Bool = false
    @State private var isDownloadingFromCloud: Bool = false

    var body: some View {
        Group {
            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // Stage 2 — kick off the higher-resolution
                    // PDFKit render the moment the preview lands so
                    // the swap-in happens without an extra tick.
                    .task(id: content.id) { await renderHighRes() }
            } else if isDownloadingFromCloud {
                downloadPlaceholder
            } else if failed {
                placeholder
            } else {
                Rectangle().fill(theme.recessiveQuinary)
                    .task(id: content.id) { await loadPreviewThenRender() }
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(theme.recessiveQuinary)
            Image(systemName: "doc.text")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(theme.recessiveTertiary)
        }
    }

    private var downloadPlaceholder: some View {
        ZStack {
            Rectangle().fill(theme.recessiveQuinary)
            VStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(theme.recessiveTertiary)
                Text("Downloading PDF from iCloud…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.recessiveTertiary)
            }
        }
    }

    // MARK: - Stage 1: preview from disk

    private func loadPreviewThenRender() async {
        let previewURL = content.previewImageURL
        let preview: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let previewURL else { return nil }
            return UIImage(contentsOfFile: previewURL.path)
        }.value

        await MainActor.run { self.previewImage = preview }

        // Whether or not the preview was present, attempt the
        // high-res render. If preview is nil the placeholder is
        // visible; if render fails too, `failed = true` surfaces
        // the icon state.
        await renderHighRes()
    }

    // MARK: - Stage 2: PDFKit render

    private func renderHighRes() async {
        guard renderedImage == nil else { return }
        let url = content.pdfFileURL
        let pageIndex = content.pageIndex

        // Step 10: surface iCloud download state before attempting
        // the render. PDF files are the largest media artefact and
        // most likely to lag behind their SwiftData record on a
        // freshly-restored device.
        switch UbiquitousFileStatus.currentState(at: url) {
        case .local:
            break
        case .downloading:
            await MainActor.run { self.isDownloadingFromCloud = true }
            _ = UbiquitousFileStatus.requestDownload(at: url)
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if case .local = UbiquitousFileStatus.currentState(at: url) { break }
            }
            await MainActor.run { self.isDownloadingFromCloud = false }
        case .notUbiquitous:
            // No file, no stub — fall through; the render will
            // fail and `failed = true` will surface the placeholder.
            break
        }

        let rendered: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url),
                  pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            // 2× scale matches the export pipeline's heuristic for
            // looks-crisp-on-Retina; cheap to render once into a
            // bitmap and reuse for the lifetime of the view.
            let scale: CGFloat = 2.0
            let pixelSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
            let renderer = UIGraphicsImageRenderer(size: pixelSize)
            return renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: pixelSize))
                let cgCtx = ctx.cgContext
                cgCtx.translateBy(x: 0, y: pixelSize.height)
                cgCtx.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: cgCtx)
            }
        }.value

        await MainActor.run {
            if let rendered {
                self.renderedImage = rendered
                self.failed = false
            } else if self.previewImage == nil {
                self.failed = true
            }
        }
    }
}
