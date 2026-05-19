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
        .task(id: content.id)       { await loadIfNeeded() }
        .task(id: content.filename) { await loadIfNeeded() }
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
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: path)
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
