import SwiftData
import SwiftUI

/// Mac crop editor for `ImageContent` — mirrors iPad `ImageCropSheet`
/// using normalised crop rects stored on the row.
struct MacImageCropSheet: View {
    @Bindable var content: ImageContent
    let onDone: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @EnvironmentObject private var storageService: StorageService

    @State private var sourceImage: NSImage?
    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var imageFrame: CGRect = .zero

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                theme.background
                if let sourceImage {
                    cropCanvas(image: sourceImage)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(width: 560, height: 480)
        .task { await loadSource() }
    }

    private var header: some View {
        HStack {
            Button("Cancel", action: onCancel)
            Spacer()
            Text("Crop Image").font(.headline)
            Spacer()
            HStack(spacing: 12) {
                Button("Reset") { cropRect = CGRect(x: 0, y: 0, width: 1, height: 1) }
                Button("Done") { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .background(theme.surface)
    }

    @ViewBuilder
    private func cropCanvas(image: NSImage) -> some View {
        GeometryReader { proxy in
            let fitted = aspectFitRect(imageSize: image.size, in: proxy.size)
            Color.clear
                .onAppear { imageFrame = fitted }
                .onChange(of: proxy.size) { _, _ in imageFrame = fitted }
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: fitted.width, height: fitted.height)
                .position(x: fitted.midX, y: fitted.midY)
                .overlay {
                    cropOverlay(frame: fitted)
                }
        }
        .padding()
    }

    private func cropOverlay(frame: CGRect) -> some View {
        let crop = CGRect(
            x: frame.minX + cropRect.minX * frame.width,
            y: frame.minY + cropRect.minY * frame.height,
            width: cropRect.width * frame.width,
            height: cropRect.height * frame.height
        )
        return ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .mask {
                    Rectangle()
                        .overlay(alignment: .topLeading) {
                            Rectangle()
                                .frame(width: crop.width, height: crop.height)
                                .offset(x: crop.minX, y: crop.minY)
                                .blendMode(.destinationOut)
                        }
                }
                .allowsHitTesting(false)
            ForEach(Corner.allCases, id: \.self) { corner in
                handle(at: corner.point(in: crop), frame: frame, corner: corner)
            }
        }
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
            case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    private func handle(at point: CGPoint, frame: CGRect, corner: Corner) -> some View {
        Circle()
            .fill(theme.accent)
            .frame(width: 14, height: 14)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        applyDrag(value, frame: frame, corner: corner)
                    }
            )
    }

    private func applyDrag(_ value: DragGesture.Value, frame: CGRect, corner: Corner) {
        let nx = max(0, min(1, (value.location.x - frame.minX) / max(1, frame.width)))
        let ny = max(0, min(1, (value.location.y - frame.minY) / max(1, frame.height)))
        var r = cropRect
        switch corner {
        case .topLeft:
            r = CGRect(x: min(nx, r.maxX - 0.05), y: min(ny, r.maxY - 0.05),
                       width: r.maxX - min(nx, r.maxX - 0.05), height: r.maxY - min(ny, r.maxY - 0.05))
        case .topRight:
            r = CGRect(x: r.minX, y: min(ny, r.maxY - 0.05),
                       width: max(nx, r.minX + 0.05) - r.minX, height: r.maxY - min(ny, r.maxY - 0.05))
        case .bottomLeft:
            r = CGRect(x: min(nx, r.maxX - 0.05), y: r.minY,
                       width: r.maxX - min(nx, r.maxX - 0.05), height: max(ny, r.minY + 0.05) - r.minY)
        case .bottomRight:
            r = CGRect(x: r.minX, y: r.minY,
                       width: max(nx, r.minX + 0.05) - r.minX, height: max(ny, r.minY + 0.05) - r.minY)
        }
        cropRect = r
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private func loadSource() async {
        if let data = content.imageData, !data.isEmpty, let img = NSImage(data: data) {
            sourceImage = img
        } else if let img = NSImage(contentsOf: content.fileURL) {
            sourceImage = img
        }
        if let x = content.cropOriginX, let y = content.cropOriginY,
           let w = content.cropWidth, let h = content.cropHeight {
            cropRect = CGRect(x: x, y: y, width: w, height: h)
        }
    }

    private func commit() {
        let isFullImage = cropRect.minX <= 0.001 && cropRect.minY <= 0.001
            && cropRect.maxX >= 0.999 && cropRect.maxY >= 0.999
        if isFullImage {
            content.cropOriginX = nil
            content.cropOriginY = nil
            content.cropWidth = nil
            content.cropHeight = nil
        } else {
            content.cropOriginX = Double(cropRect.origin.x)
            content.cropOriginY = Double(cropRect.origin.y)
            content.cropWidth = Double(cropRect.width)
            content.cropHeight = Double(cropRect.height)
        }
        content.updatedAt = Date()
        try? storageService.context.save()
        onDone()
    }
}

enum MacImageCropMath {
    static func applyCrop(to image: NSImage, content: ImageContent) -> NSImage {
        guard let x = content.cropOriginX, let y = content.cropOriginY,
              let w = content.cropWidth, let h = content.cropHeight,
              w > 0.01, h > 0.01, w < 0.999, h < 0.999 else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let pw = CGFloat(cg.width)
        let ph = CGFloat(cg.height)
        let rect = CGRect(x: x * pw, y: y * ph, width: w * pw, height: h * ph).integral
        guard let cropped = cg.cropping(to: rect) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
    }
}
