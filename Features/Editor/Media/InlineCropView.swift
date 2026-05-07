import SwiftUI
import UIKit

// MARK: - InlineCropView

/// Full-screen crop sheet. Implemented with custom UIView and CALayer masking.
/// Done creates a new JPEG of the cropped region and calls onDone.
struct InlineCropView: View {

    let attachment: MediaAttachment
    let onDone: (Data, Int, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var aspectLock: AspectRatioLock = .free
    @StateObject private var cropViewModel = CropViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                CropCanvasView(
                    attachment: attachment,
                    aspectLock: aspectLock,
                    viewModel: cropViewModel
                )
                .ignoresSafeArea()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .principal) {
                    Text("Crop")
                        .font(.inkHeadline)
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { applyCrop() }
                        .foregroundColor(.inkAccentPrimary)
                        .fontWeight(.semibold)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { bottomControls }
        }
    }

    // MARK: Bottom controls

    private var bottomControls: some View {
        VStack(spacing: Ink.Spacing.md) {
            // Aspect ratio picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Ink.Spacing.sm) {
                    ForEach(AspectRatioLock.allCases, id: \.self) { lock in
                        Button(lock.rawValue) {
                            aspectLock = lock
                            cropViewModel.applyAspectLock(lock)
                        }
                        .font(.inkCaption)
                        .foregroundColor(aspectLock == lock ? .inkAccentPrimary : .white.opacity(0.7))
                        .padding(.horizontal, Ink.Spacing.sm)
                        .padding(.vertical, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                                .strokeBorder(
                                    aspectLock == lock ? Color.inkAccentPrimary : Color.white.opacity(0.3),
                                    lineWidth: 0.5
                                )
                        )
                    }
                }
                .padding(.horizontal, Ink.Spacing.md)
            }

            // Rotation buttons
            HStack(spacing: Ink.Spacing.xl) {
                Button {
                    cropViewModel.rotate90(clockwise: false)
                } label: {
                    Image(systemName: "rotate.left")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Button {
                    cropViewModel.rotate90(clockwise: true)
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, Ink.Spacing.lg)
        }
        .padding(.top, Ink.Spacing.sm)
        .background(Color.black)
    }

    // MARK: Apply crop

    private func applyCrop() {
        guard let result = cropViewModel.renderCroppedImage() else { dismiss(); return }
        let size = result.size
        if let jpeg = result.jpegData(compressionQuality: 0.88) {
            onDone(jpeg, Int(size.width), Int(size.height))
        }
        dismiss()
    }
}

// MARK: - CropViewModel

final class CropViewModel: ObservableObject {
    @Published var cropRect: CGRect = .zero         // in image view coordinates
    @Published var imageViewFrame: CGRect = .zero
    var rotation: CGFloat = 0            // accumulated 90° steps in radians
    var image: UIImage?

    func applyAspectLock(_ lock: AspectRatioLock) {
        guard let ratio = lock.ratio, cropRect.width > 0 else { return }
        let newH = cropRect.width * ratio
        cropRect.size.height = min(newH, imageViewFrame.height)
    }

    func rotate90(clockwise: Bool) {
        rotation += clockwise ? .pi / 2 : -.pi / 2
        // Swap crop rect width/height
        let w = cropRect.width
        cropRect.size.width  = cropRect.height
        cropRect.size.height = w
    }

    func renderCroppedImage() -> UIImage? {
        guard let image else { return nil }
        // Apply accumulated rotation
        let rotated = applyRotation(to: image)
        // Scale cropRect from imageViewFrame to image pixel coordinates
        guard imageViewFrame.width > 0, imageViewFrame.height > 0 else { return rotated }
        let scaleX = rotated.size.width  / imageViewFrame.width
        let scaleY = rotated.size.height / imageViewFrame.height
        let pixelRect = CGRect(
            x:      cropRect.origin.x * scaleX,
            y:      cropRect.origin.y * scaleY,
            width:  cropRect.width    * scaleX,
            height: cropRect.height   * scaleY
        ).intersection(CGRect(origin: .zero, size: rotated.size))

        guard let cgImage = rotated.cgImage?.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func applyRotation(to image: UIImage) -> UIImage {
        let steps = Int(round(rotation / (.pi / 2))) % 4
        guard steps != 0 else { return image }
        var current = image
        for _ in 0..<abs(steps) {
            current = steps > 0 ? rotateCW(current) : rotateCCW(current)
        }
        return current
    }

    private func rotateCW(_ image: UIImage) -> UIImage {
        let size = CGSize(width: image.size.height, height: image.size.width)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: size.width, y: 0)
            ctx.cgContext.rotate(by: .pi / 2)
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func rotateCCW(_ image: UIImage) -> UIImage {
        let size = CGSize(width: image.size.height, height: image.size.width)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.rotate(by: -.pi / 2)
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

// MARK: - CropCanvasView (UIViewRepresentable)

struct CropCanvasView: UIViewRepresentable {

    let attachment: MediaAttachment
    let aspectLock: AspectRatioLock
    @ObservedObject var viewModel: CropViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeUIView(context: Context) -> CropCanvasUIView {
        let view = CropCanvasUIView()
        view.coordinator = context.coordinator

        // Load image
        let url = StorageService.shared.mediaURL(for: attachment)
        if let image = UIImage(contentsOfFile: url.path) {
            view.setImage(image)
            viewModel.image = image
        }

        context.coordinator.canvasView = view
        return view
    }

    func updateUIView(_ uiView: CropCanvasUIView, context: Context) {
        if let ratio = aspectLock.ratio {
            uiView.lockAspectRatio(ratio)
        } else {
            uiView.unlockAspectRatio()
        }
    }

    final class Coordinator {
        var viewModel: CropViewModel
        weak var canvasView: CropCanvasUIView?

        init(viewModel: CropViewModel) { self.viewModel = viewModel }

        func cropDidChange(_ rect: CGRect, imageViewFrame: CGRect) {
            viewModel.cropRect      = rect
            viewModel.imageViewFrame = imageViewFrame
        }
    }
}

// MARK: - CropCanvasUIView

/// Custom UIView implementing interactive crop with CALayer masking.
final class CropCanvasUIView: UIView {

    weak var coordinator: CropCanvasView.Coordinator?

    private let imageView    = UIImageView()
    private let overlayLayer = CAShapeLayer()   // darkened region outside crop rect
    private let cropLayer    = CALayer()         // crop border
    private var handleViews: [UIView] = []

    private var cropRect: CGRect = .zero  // in self.bounds coordinates
    private var lockedAspect: CGFloat?

    // Active handle drag tracking
    private var draggingHandle: Int?     // index in handleViews
    private var dragStartRect: CGRect = .zero
    private var dragStartPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setup() {
        backgroundColor = .black

        // Image view
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 60),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -60),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Overlay (dimmed region outside crop)
        overlayLayer.fillColor   = UIColor.black.withAlphaComponent(0.55).cgColor
        overlayLayer.fillRule    = .evenOdd
        layer.addSublayer(overlayLayer)

        // Crop border
        cropLayer.borderColor = UIColor.white.cgColor
        cropLayer.borderWidth = 1.5
        layer.addSublayer(cropLayer)

        // 8 + corner handles
        for i in 0..<8 {
            let h = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
            h.backgroundColor = .white
            h.layer.cornerRadius = 10
            h.tag = i
            addSubview(h)
            handleViews.append(h)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            h.addGestureRecognizer(pan)
        }
    }

    func setImage(_ image: UIImage) {
        imageView.image = image
        setNeedsLayout()
    }

    func lockAspectRatio(_ ratio: CGFloat) {
        lockedAspect = ratio
        if cropRect != .zero { enforceLock() }
    }

    func unlockAspectRatio() { lockedAspect = nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        if cropRect == .zero {
            // Default crop rect: 80% of image view rect
            let imgFrame = imageViewDisplayRect()
            let inset = CGPoint(x: imgFrame.width * 0.10, y: imgFrame.height * 0.10)
            cropRect = imgFrame.insetBy(dx: inset.x, dy: inset.y)
        }
        updateLayers()
        reportCropChange()
    }

    private func imageViewDisplayRect() -> CGRect {
        guard let img = imageView.image else { return bounds }
        let imgSize  = img.size
        let viewSize = imageView.frame.size
        guard imgSize.width > 0, imgSize.height > 0 else { return imageView.frame }

        let scaleW = viewSize.width  / imgSize.width
        let scaleH = viewSize.height / imgSize.height
        let scale  = min(scaleW, scaleH)
        let w = imgSize.width  * scale
        let h = imgSize.height * scale
        let originInView = CGPoint(
            x: imageView.frame.origin.x + (viewSize.width  - w) / 2,
            y: imageView.frame.origin.y + (viewSize.height - h) / 2
        )
        return CGRect(origin: originInView, size: CGSize(width: w, height: h))
    }

    private func updateLayers() {
        // Overlay: full bounds minus crop rect (evenOdd fill rule creates hole)
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(rect: cropRect))
        overlayLayer.path   = path.cgPath
        overlayLayer.frame  = bounds

        // Crop border
        cropLayer.frame = cropRect

        // Handle positions (8 anchors same as ResizeHandle)
        let anchors: [(CGFloat, CGFloat)] = [
            (0, 0), (0.5, 0), (1, 0),
            (0, 0.5),          (1, 0.5),
            (0, 1), (0.5, 1), (1, 1),
        ]
        for (i, (ax, ay)) in anchors.enumerated() {
            guard i < handleViews.count else { break }
            let hv = handleViews[i]
            let hx = cropRect.origin.x + ax * cropRect.width  - 10
            let hy = cropRect.origin.y + ay * cropRect.height - 10
            hv.frame.origin = CGPoint(x: hx, y: hy)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let hv = gesture.view else { return }
        let idx = handleViews.firstIndex(of: hv) ?? 0

        switch gesture.state {
        case .began:
            draggingHandle = idx
            dragStartRect  = cropRect
            dragStartPoint = gesture.location(in: self)
        case .changed:
            guard let _ = draggingHandle else { return }
            let current = gesture.location(in: self)
            let dx = current.x - dragStartPoint.x
            let dy = current.y - dragStartPoint.y
            applyHandleDelta(handle: idx, dx: dx, dy: dy)
            if let ratio = lockedAspect { enforceLock(ratio: ratio) }
            updateLayers()
            reportCropChange()
        case .ended, .cancelled:
            draggingHandle = nil
        default: break
        }
    }

    private func applyHandleDelta(handle: Int, dx: CGFloat, dy: CGFloat) {
        let imgFrame = imageViewDisplayRect()
        var r = dragStartRect
        let min: CGFloat = 48

        // Handle order: TL TC TR ML MR BL BC BR
        switch handle {
        case 0: r.origin.x += dx; r.size.width  -= dx; r.origin.y += dy; r.size.height -= dy
        case 1: r.origin.y += dy; r.size.height -= dy
        case 2: r.size.width  += dx; r.origin.y += dy; r.size.height -= dy
        case 3: r.origin.x += dx; r.size.width  -= dx
        case 4: r.size.width  += dx
        case 5: r.origin.x += dx; r.size.width  -= dx; r.size.height += dy
        case 6: r.size.height += dy
        case 7: r.size.width  += dx; r.size.height += dy
        default: break
        }

        // Clamp to image bounds and minimum size
        r.size.width  = max(min, r.size.width)
        r.size.height = max(min, r.size.height)
        r.origin.x    = max(imgFrame.minX, min(r.origin.x, imgFrame.maxX - r.size.width))
        r.origin.y    = max(imgFrame.minY, min(r.origin.y, imgFrame.maxY - r.size.height))
        r.size.width  = min(r.size.width,  imgFrame.maxX - r.origin.x)
        r.size.height = min(r.size.height, imgFrame.maxY - r.origin.y)

        cropRect = r
    }

    private func enforceLock(ratio: CGFloat? = nil) {
        let r = ratio ?? lockedAspect
        guard let r else { return }
        cropRect.size.height = cropRect.size.width * r
        let imgFrame = imageViewDisplayRect()
        if cropRect.maxY > imgFrame.maxY {
            cropRect.size.height = imgFrame.maxY - cropRect.origin.y
            cropRect.size.width  = cropRect.size.height / r
        }
    }

    private func reportCropChange() {
        let imgFrame = imageViewDisplayRect()
        // Convert cropRect from self.bounds → imageView display rect
        let relative = CGRect(
            x:      cropRect.origin.x - imgFrame.origin.x,
            y:      cropRect.origin.y - imgFrame.origin.y,
            width:  cropRect.width,
            height: cropRect.height
        )
        coordinator?.cropDidChange(relative, imageViewFrame: CGRect(origin: .zero, size: imgFrame.size))
    }
}
