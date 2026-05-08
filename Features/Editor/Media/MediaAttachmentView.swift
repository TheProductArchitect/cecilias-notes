import SwiftUI
import UIKit

// MARK: - MediaAttachmentView

/// UIViewRepresentable that renders a single MediaAttachment image.
/// Uses thumbnail for renders < 800px wide; loads full-resolution async otherwise.
struct MediaAttachmentView: UIViewRepresentable {

    let attachment: MediaAttachment
    let frameWidth: CGFloat           // current display width in points
    let opacity: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode        = .scaleAspectFill
        imageView.clipsToBounds      = true
        imageView.backgroundColor    = UIColor.inkBackgroundSecondary
        imageView.isUserInteractionEnabled = false
        context.coordinator.imageView = imageView
        loadImage(into: imageView)
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        imageView.alpha = opacity
        // Reload if attachment identity changed
        if context.coordinator.loadedAttachmentId != attachment.id {
            context.coordinator.loadedAttachmentId = nil
            loadImage(into: imageView)
        }
    }

    // MARK: Image loading

    private func loadImage(into imageView: UIImageView) {
        // Read-only path resolution. Not a layering violation — neither URL
        // mutates state. Adding a `viewModel` parameter here would force every
        // call-site (overlay rendering inside ForEach) to thread it through
        // and gain nothing.
        let thumbURL = StorageService.shared.thumbnailURL(for: attachment)
        let fullURL  = StorageService.shared.mediaURL(for: attachment)
        let useThumb = frameWidth < 800

        // Thumbnail placeholder via the shared decoded-image cache.
        Task {
            let thumb = await MediaImageCache.shared.image(at: thumbURL)
            await MainActor.run { imageView.image = thumb }
        }

        if !useThumb {
            // Full-resolution upgrade via the shared cache.
            Task { [weak imageView] in
                let full = await MediaImageCache.shared.image(at: fullURL)
                await MainActor.run {
                    guard let imageView, let full else { return }
                    UIView.transition(with: imageView, duration: 0.15,
                                      options: .transitionCrossDissolve) {
                        imageView.image = full
                    }
                }
            }
        }
    }

    final class Coordinator {
        weak var imageView: UIImageView?
        var loadedAttachmentId: UUID?
    }
}
