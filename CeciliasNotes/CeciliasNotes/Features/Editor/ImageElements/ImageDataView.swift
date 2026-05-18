import SwiftUI
import UIKit

/// Disk-backed loader for an `ImageContent`. Decodes off the main
/// actor and caches the resulting `UIImage` in `@State` so the
/// parent body can re-render (drag/resize) without re-decoding.
///
/// Shows a `photo.badge.exclamationmark` placeholder when the file
/// is missing — most commonly while iCloud Drive is downloading a
/// freshly-restored device's media tree. Re-attempts on
/// `.inputCapabilityChanged`-style refresh ticks is unnecessary:
/// once the file lands, the next view-tree invalidation triggers
/// `.task(id:)` again.
struct ImageDataView: View {

    let content: ImageContent
    @Environment(\.theme) private var theme

    @State private var image: UIImage?
    @State private var loadFailed: Bool = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if loadFailed {
                placeholder(icon: "photo.badge.exclamationmark")
            } else {
                Rectangle().fill(theme.recessiveQuinary)
            }
        }
        // Re-decode whenever the content row's id changes (i.e. a
        // different element is mounted in the same slot during a
        // diff). `filename` changes are rare but covered.
        .task(id: content.id) { await loadIfNeeded() }
        .task(id: content.filename) { await loadIfNeeded() }
    }

    private func placeholder(icon: String) -> some View {
        ZStack {
            Rectangle().fill(theme.recessiveQuinary)
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(theme.recessiveTertiary)
        }
    }

    private func loadIfNeeded() async {
        let url = content.fileURL
        let path = url.path
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: path)
        }.value
        await MainActor.run {
            if let loaded {
                self.image = loaded
                self.loadFailed = false
            } else {
                self.image = nil
                self.loadFailed = true
            }
        }
    }
}
