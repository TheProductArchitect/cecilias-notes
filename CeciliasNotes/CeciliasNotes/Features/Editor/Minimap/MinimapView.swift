import SwiftUI
import UIKit

/// Floating viewport indicator. Shown only when zoom > 1.5×.
/// Listens to `ceciliasNotesCanvasViewportDidChange` notifications throttled to ~15fps.
struct MinimapView: View {
    @ObservedObject var viewModel: EditorViewModel

    @State private var thumbnail: UIImage?
    @State private var viewport: CGRect = .zero      // viewport rect in *thumbnail* coords
    @State private var contentSize: CGSize = .zero
    @State private var contentOffset: CGPoint = .zero
    @State private var visibleSize: CGSize = .zero
    @State private var lastUpdate: Date = .distantPast

    @State private var dragStartOffset: CGPoint?

    private let mapWidth:  CGFloat = 80
    private let mapHeight: CGFloat = 104

    /// Throttle viewport updates to ~15fps (66ms) — never on the drawing thread.
    private let updateInterval: TimeInterval = 1.0 / 15.0

    var body: some View {
        ZStack {
            // Page paper background
            RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                .fill(Color.inkBackgroundElevated)

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .interpolation(.medium)
            }

            // Viewport rectangle
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.inkAccentPrimary.opacity(0.18))
                    .overlay(
                        Rectangle()
                            .strokeBorder(Color.inkAccentPrimary, lineWidth: 1)
                    )
                    .frame(width: viewport.width, height: viewport.height)
                    .offset(x: viewport.origin.x, y: viewport.origin.y)
                    .gesture(dragGesture(in: proxy.size))
                    .onTapGesture {
                        // Re-centre on tap (no-op here — drag covers it)
                    }
            }
        }
        .frame(width: mapWidth, height: mapHeight)
        .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
        )
        .onAppear { loadThumbnail() }
        .onChange(of: viewModel.currentPage.id) { _, _ in loadThumbnail() }
        .onReceive(
            NotificationCenter.default.publisher(for: .ceciliasNotesCanvasViewportDidChange)
        ) { note in
            handleViewportNotification(note)
        }
    }

    // MARK: Drag gesture

    private func dragGesture(in mapSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartOffset == nil { dragStartOffset = contentOffset }
                guard let start = dragStartOffset else { return }
                let pageSize = viewModel.currentPage.pageSize.pointSize
                let zoom     = viewModel.zoomScale
                // Translation in mini-map coords → translation in canvas coords
                let scaleX = (pageSize.width  * zoom) / mapWidth
                let scaleY = (pageSize.height * zoom) / mapHeight
                let dx = value.translation.width  * scaleX
                let dy = value.translation.height * scaleY
                let newOffset = CGPoint(x: start.x + dx, y: start.y + dy)
                NotificationCenter.default.post(
                    name: .ceciliasNotesCanvasShouldPanTo,
                    object: nil,
                    userInfo: ["offset": newOffset]
                )
            }
            .onEnded { _ in dragStartOffset = nil }
    }

    // MARK: Viewport sync

    private func handleViewportNotification(_ note: Notification) {
        // Throttle: ignore if last update was less than `updateInterval` ago.
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= updateInterval else { return }
        lastUpdate = now

        guard let userInfo = note.userInfo,
              let offset = userInfo["offset"] as? CGPoint,
              let size   = userInfo["size"]   as? CGSize else { return }

        contentOffset = offset
        visibleSize   = size

        let pageSize = viewModel.currentPage.pageSize.pointSize
        let zoom     = viewModel.zoomScale
        guard zoom > 0 else { return }

        let totalContentSize = CGSize(
            width:  pageSize.width  * zoom,
            height: pageSize.height * zoom
        )
        contentSize = totalContentSize

        let mapToContentX = mapWidth  / max(1, totalContentSize.width)
        let mapToContentY = mapHeight / max(1, totalContentSize.height)

        viewport = CGRect(
            x: max(0, offset.x) * mapToContentX,
            y: max(0, offset.y) * mapToContentY,
            width:  min(size.width,  totalContentSize.width)  * mapToContentX,
            height: min(size.height, totalContentSize.height) * mapToContentY
        )
    }

    // MARK: Thumbnail

    private func loadThumbnail() {
        let page = viewModel.currentPage
        let key  = PageThumbnailCache.shared.composeKey(for: page)
        if let cached = PageThumbnailCache.shared.thumbnail(for: key) {
            thumbnail = cached
            return
        }
        Task {
            let result = await PageThumbnailCache.shared.generate(
                for: page,
                targetSize: CGSize(width: mapWidth, height: mapHeight)
            )
            // Keep the previous thumbnail visible if the render
            // returned nil — never flash to blank during regen.
            if let result {
                await MainActor.run { thumbnail = result }
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let ceciliasNotesCanvasShouldPanTo       = Notification.Name("ink.canvas.shouldPanTo")
    /// Posted by the canvas on every scroll/zoom change so the minimap
    /// (and anyone else who cares) can track the viewport. UserInfo:
    /// `offset: CGPoint`, `zoom: CGFloat`.
    static let ceciliasNotesCanvasViewportDidChange = Notification.Name("ink.canvas.viewportDidChange")
}
