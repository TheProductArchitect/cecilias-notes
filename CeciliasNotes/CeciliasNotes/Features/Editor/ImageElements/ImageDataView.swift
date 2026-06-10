import SwiftUI
import UIKit

/// Disk-backed loader for an `ImageContent`. Decodes off the main
/// actor and caches the resulting `UIImage` in `@State` so the
/// parent body can re-render (drag/resize) without re-decoding.
///
/// Step 10: distinguishes "iCloud Drive is downloading this file"
/// from "file is missing." When the underlying URL is a ubiquity
/// stub (the metadata-only `.<filename>.icloud` placeholder), the
/// view triggers `startDownloadingUbiquitousItem`, shows a
/// progress placeholder, and polls until the bytes land.
struct ImageDataView: View {

    let content: ImageContent
    @Environment(\.theme) private var theme

    @State private var image: UIImage?
    @State private var loadFailed: Bool = false
    @State private var isDownloadingFromCloud: Bool = false

    /// Identity key used to re-run the loader whenever any of the
    /// fields that affect the displayed pixels change — including
    /// the crop rect. Mutating an existing image's crop in-place
    /// (without changing `id` or `filename`) wouldn't otherwise
    /// invalidate the cached `image` and the user would still see
    /// the old, uncropped bitmap.
    private var loadKey: String {
        "\(content.id.uuidString)|\(content.filename)|"
            + "\(content.cropOriginX ?? -1)|\(content.cropOriginY ?? -1)|"
            + "\(content.cropWidth ?? -1)|\(content.cropHeight ?? -1)"
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if isDownloadingFromCloud {
                downloadPlaceholder
            } else if loadFailed {
                placeholder(icon: "photo.badge.exclamationmark")
            } else {
                Rectangle().fill(theme.recessiveQuinary)
            }
        }
        .task(id: loadKey) { await loadIfNeeded() }
    }

    // MARK: - Placeholders

    private func placeholder(icon: String) -> some View {
        ZStack {
            Rectangle().fill(theme.recessiveQuinary)
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(theme.recessiveTertiary)
        }
    }

    private var downloadPlaceholder: some View {
        ZStack {
            Rectangle().fill(theme.recessiveQuinary)
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(theme.recessiveTertiary)
                Text("Downloading from iCloud…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.recessiveTertiary)
            }
        }
    }

    // MARK: - Load

    private func loadIfNeeded() async {
        let url = content.fileURL
        switch UbiquitousFileStatus.currentState(at: url) {
        case .local:
            await load(url: url)
        case .downloading:
            await MainActor.run {
                self.isDownloadingFromCloud = true
                self.loadFailed = false
            }
            _ = UbiquitousFileStatus.requestDownload(at: url)
            await pollUntilDownloaded(url: url)
            await load(url: url)
        case .notUbiquitous:
            await MainActor.run {
                self.image = nil
                self.loadFailed = true
                self.isDownloadingFromCloud = false
            }
        }
    }

    private func load(url: URL) async {
        let path = url.path
        // Capture the crop rect on the actor so the detached task
        // sees a stable snapshot even if the row mutates mid-load.
        let cropX = content.cropOriginX
        let cropY = content.cropOriginY
        let cropW = content.cropWidth
        let cropH = content.cropHeight
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let raw = UIImage(contentsOfFile: path) else { return nil }
            return Self.applyCrop(to: raw, x: cropX, y: cropY, w: cropW, h: cropH)
        }.value
        await MainActor.run {
            self.isDownloadingFromCloud = false
            if let loaded {
                self.image = loaded
                self.loadFailed = false
            } else {
                self.image = nil
                self.loadFailed = true
            }
        }
    }

    /// Apply a normalised crop rect to `raw`, returning a new
    /// `UIImage` showing only the sub-region. Returns `raw` when
    /// the rect is missing, degenerate, or fully covers the image
    /// (no-op crop) — keeping the renderer behaviour identical to
    /// pre-crop for uncropped rows.
    static func applyCrop(
        to raw: UIImage,
        x: Double?, y: Double?, w: Double?, h: Double?
    ) -> UIImage {
        guard let x, let y, let w, let h,
              w > 0, h > 0,
              !(x <= 0 && y <= 0 && x + w >= 1 && y + h >= 1)
        else { return raw }
        guard let cg = raw.cgImage else { return raw }
        // Clamp the rect into the image's pixel space.
        let pw = CGFloat(cg.width)
        let ph = CGFloat(cg.height)
        let rect = CGRect(
            x: max(0, min(pw - 1, CGFloat(x) * pw)),
            y: max(0, min(ph - 1, CGFloat(y) * ph)),
            width:  max(1, min(pw, CGFloat(w) * pw)),
            height: max(1, min(ph, CGFloat(h) * ph))
        ).integral
        guard let cropped = cg.cropping(to: rect) else { return raw }
        return UIImage(cgImage: cropped, scale: raw.scale, orientation: raw.imageOrientation)
    }

    /// Re-check the file state every second until the system
    /// reports it as locally available, or 60 seconds elapse
    /// (caller falls through to a load attempt either way).
    private func pollUntilDownloaded(url: URL) async {
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            if case .local = UbiquitousFileStatus.currentState(at: url) { return }
        }
    }
}
