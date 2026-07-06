import SwiftData
import SwiftUI
import UIKit

/// Full-screen crop editor for an `ImageContent`. Loads the
/// uncropped source bitmap, lets the user drag four corner handles
/// to define a sub-rect, and writes a normalised crop rect back to
/// the row on confirm. The renderer (`ImageDataView`) re-decodes
/// against the new rect via its `loadKey` invalidation.
///
/// Design choices kept deliberately small:
///   • Corner handles only (four targets) — the user can drag any
///     corner; opposite corners move independently for non-uniform
///     trims.
///   • No aspect-ratio lock — most note-taking crops trim
///     whitespace; locking the ratio gets in the way.
///   • "reset" button clears the crop rect (returns to full image).
///   • All math is in normalised image-space (0..1) so the result
///     is resolution-independent and round-trips through CloudKit.
struct ImageCropSheet: View {
    let content: ImageContent
    let onDone: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme

    /// Full, uncropped source bitmap. Loaded once on appear.
    @State private var sourceImage: UIImage?
    /// Working crop rect in normalised image-space ([0,1]).
    @State private var cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Frame the image was laid out into. Used to convert handle
    /// drag offsets (point-space) back into normalised image-space.
    @State private var imageFrame: CGRect = .zero

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                theme.background.ignoresSafeArea()
                if let sourceImage {
                    cropCanvas(image: sourceImage)
                } else {
                    ProgressView().tint(theme.foreground)
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .task { await loadSource() }
    }

    private var header: some View {
        HStack {
            Button("cancel") { onCancel() }
                .foregroundStyle(theme.foreground)
            Spacer()
            Text("crop image")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Spacer()
            HStack(spacing: 16) {
                Button("reset") { cropRect = CGRect(x: 0, y: 0, width: 1, height: 1) }
                    .foregroundStyle(theme.foregroundMuted)
                Button("done") { commitAndDismiss() }
                    .foregroundStyle(theme.accent)
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }

    // MARK: - Crop canvas

    @ViewBuilder
    private func cropCanvas(image: UIImage) -> some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let imageSize = image.size
            // Fit the image inside the container preserving aspect.
            let fittedSize = aspectFitSize(image: imageSize, into: containerSize)
            let frame = CGRect(
                x: (containerSize.width  - fittedSize.width)  / 2,
                y: (containerSize.height - fittedSize.height) / 2,
                width:  fittedSize.width,
                height: fittedSize.height
            )

            ZStack(alignment: .topLeading) {
                // The image itself.
                Image(uiImage: image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .opacity(0.45)

                // Brighter window over the crop rect.
                let pixelRect = CGRect(
                    x: frame.minX + cropRect.minX * frame.width,
                    y: frame.minY + cropRect.minY * frame.height,
                    width:  cropRect.width  * frame.width,
                    height: cropRect.height * frame.height
                )
                Image(uiImage: image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .mask {
                        Rectangle()
                            .frame(width: pixelRect.width, height: pixelRect.height)
                            .position(x: pixelRect.midX, y: pixelRect.midY)
                    }

                // Selection border.
                Rectangle()
                    .strokeBorder(theme.accent, lineWidth: 1.5)
                    .frame(width: pixelRect.width, height: pixelRect.height)
                    .position(x: pixelRect.midX, y: pixelRect.midY)
                    .allowsHitTesting(false)

                // Four corner handles.
                handle(at: CGPoint(x: pixelRect.minX, y: pixelRect.minY), frame: frame, corner: .topLeft)
                handle(at: CGPoint(x: pixelRect.maxX, y: pixelRect.minY), frame: frame, corner: .topRight)
                handle(at: CGPoint(x: pixelRect.minX, y: pixelRect.maxY), frame: frame, corner: .bottomLeft)
                handle(at: CGPoint(x: pixelRect.maxX, y: pixelRect.maxY), frame: frame, corner: .bottomRight)
            }
            .onAppear { imageFrame = frame }
            .onChange(of: containerSize) { _, _ in imageFrame = frame }
        }
        .padding(20)
    }

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private func handle(at point: CGPoint, frame: CGRect, corner: Corner) -> some View {
        Circle()
            .fill(theme.accent)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .contentShape(Rectangle().inset(by: -16))
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        applyDrag(value, frame: frame, corner: corner)
                    }
            )
    }

    private func applyDrag(_ value: DragGesture.Value, frame: CGRect, corner: Corner) {
        // Convert the absolute touch location to normalised
        // image-space and re-derive the crop rect such that the
        // dragged corner follows the finger; the opposite corner
        // stays fixed.
        let touch = value.location
        let nx = max(0, min(1, (touch.x - frame.minX) / max(1, frame.width)))
        let ny = max(0, min(1, (touch.y - frame.minY) / max(1, frame.height)))
        // Anchor = the corner opposite the dragged one.
        let minNX: CGFloat
        let maxNX: CGFloat
        let minNY: CGFloat
        let maxNY: CGFloat
        switch corner {
        case .topLeft:
            minNX = min(nx, cropRect.maxX - 0.05)
            maxNX = cropRect.maxX
            minNY = min(ny, cropRect.maxY - 0.05)
            maxNY = cropRect.maxY
        case .topRight:
            minNX = cropRect.minX
            maxNX = max(nx, cropRect.minX + 0.05)
            minNY = min(ny, cropRect.maxY - 0.05)
            maxNY = cropRect.maxY
        case .bottomLeft:
            minNX = min(nx, cropRect.maxX - 0.05)
            maxNX = cropRect.maxX
            minNY = cropRect.minY
            maxNY = max(ny, cropRect.minY + 0.05)
        case .bottomRight:
            minNX = cropRect.minX
            maxNX = max(nx, cropRect.minX + 0.05)
            minNY = cropRect.minY
            maxNY = max(ny, cropRect.minY + 0.05)
        }
        cropRect = CGRect(
            x: minNX,
            y: minNY,
            width:  maxNX - minNX,
            height: maxNY - minNY
        )
    }

    private func aspectFitSize(image: CGSize, into container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0,
              container.width > 0, container.height > 0
        else { return container }
        let imageAspect = image.width / image.height
        let containerAspect = container.width / container.height
        if imageAspect > containerAspect {
            // Image is wider — width-bound.
            return CGSize(width: container.width, height: container.width / imageAspect)
        }
        return CGSize(width: container.height * imageAspect, height: container.height)
    }

    // MARK: - Load / commit

    private func loadSource() async {
        if let inline = content.imageData, !inline.isEmpty {
            let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
                UIImage(data: inline)
            }.value
            await MainActor.run {
                self.sourceImage = loaded
                seedCropRectIfNeeded()
            }
            return
        }

        let url = content.fileURL
        switch UbiquitousFileStatus.currentState(at: url) {
        case .local:
            await loadFromFile(url)
        case .downloading:
            _ = UbiquitousFileStatus.requestDownload(at: url)
            await pollUntilDownloaded(url: url)
            await loadFromFile(url)
        case .notUbiquitous:
            await loadFromFile(url)
        }
    }

    private func loadFromFile(_ url: URL) async {
        let path = url.path
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: path)
        }.value
        await MainActor.run {
            self.sourceImage = loaded
            seedCropRectIfNeeded()
        }
    }

    private func seedCropRectIfNeeded() {
        if let x = content.cropOriginX,
           let y = content.cropOriginY,
           let w = content.cropWidth,
           let h = content.cropHeight,
           w > 0, h > 0 {
            cropRect = CGRect(x: x, y: y, width: w, height: h)
        }
    }

    private func pollUntilDownloaded(url: URL) async {
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            if case .local = UbiquitousFileStatus.currentState(at: url) { return }
        }
    }

    private func commitAndDismiss() {
        // Treat a full-image rect as "no crop" — clear the fields
        // so the renderer reverts to the no-crop fast path and
        // search/OCR can still read the entire image.
        let isFullImage = cropRect.minX <= 0.001 && cropRect.minY <= 0.001
            && cropRect.maxX >= 0.999 && cropRect.maxY >= 0.999
        if isFullImage {
            content.cropOriginX = nil
            content.cropOriginY = nil
            content.cropWidth   = nil
            content.cropHeight  = nil
        } else {
            content.cropOriginX = Double(cropRect.minX)
            content.cropOriginY = Double(cropRect.minY)
            content.cropWidth   = Double(cropRect.width)
            content.cropHeight  = Double(cropRect.height)
        }
        content.updatedAt = Date()
        try? StorageService.shared.context.save()
        HapticManager.shared.toolSwitched()
        onDone()
    }
}
