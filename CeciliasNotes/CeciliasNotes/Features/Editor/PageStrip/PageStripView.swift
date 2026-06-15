import SwiftUI
import UIKit

/// Bottom slide-in strip of page thumbnails.
///   • Each thumbnail: 80×104pt
///   • Current page: accent.primary border ring
///   • Long-press: context menu (Duplicate / Delete / Add Page After)
///   • Trailing + button: add page at end
struct PageStripView: View {
    @ObservedObject var viewModel: EditorViewModel
    @Environment(\.theme) private var theme

    private let thumbWidth:  CGFloat = 80
    private let thumbHeight: CGFloat = 104
    private let stripHeight: CGFloat = 140

    var body: some View {
        ZStack {
            background
            content
        }
        .frame(height: stripHeight)
        .frame(maxWidth: .infinity)
    }

    private var background: some View {
        Rectangle()
            .fill(theme.surfaceElevated.opacity(0.94))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(theme.borderSubtle)
                    .frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom)
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CeciliasNotes.Spacing.sm) {
                    ForEach(Array(viewModel.pages.enumerated()), id: \.element.id) { index, page in
                        PageStripThumbnail(
                            page: page,
                            pageNumber: index + 1,
                            size: CGSize(width: thumbWidth, height: thumbHeight),
                            isCurrent: index == viewModel.currentPageIndex,
                            canMoveLeft:  index > 0,
                            canMoveRight: index < viewModel.pages.count - 1
                        ) {
                            viewModel.goToPage(index: index)
                        } onContextMenuDuplicate: {
                            viewModel.duplicatePage(page)
                        } onContextMenuDelete: {
                            viewModel.deletePage(page)
                        } onContextMenuAddAfter: {
                            viewModel.addPage(after: page.pageNumber)
                        } onContextMenuAddBefore: {
                            viewModel.addPage(before: page.pageNumber)
                        } onContextMenuMoveLeft: {
                            viewModel.movePage(page, to: page.pageNumber - 1)
                        } onContextMenuMoveRight: {
                            viewModel.movePage(page, to: page.pageNumber + 1)
                        }
                        .id(page.id)
                    }

                    // + add page button — hidden on read-only
                    // devices. Page navigation still works via the
                    // thumbnails above, so the strip remains
                    // useful as a "jump to page N" affordance.
                    if DeviceCapabilities.canMutate {
                        Button {
                            viewModel.addPage()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(theme.accent)
                                    .frame(width: thumbWidth, height: thumbHeight)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                                            .strokeBorder(
                                                theme.accent,
                                                style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                                            )
                                    )
                            }
                        }
                        .buttonStyle(.ceciliasNotesPressable)
                    }
                }
                .padding(.horizontal, CeciliasNotes.Spacing.lg)
                .padding(.vertical, CeciliasNotes.Spacing.md)
            }
            .onChange(of: viewModel.currentPageIndex) { _, newIndex in
                guard newIndex < viewModel.pages.count else { return }
                // Snap-scroll without animation. The canvas's
                // continuous-scroll mode flips `currentPageIndex`
                // many times per second; the previous
                // `withAnimation` wrapper queued a spring animation
                // on every flip, which compounded into a visible
                // strobe across the thumbnail row. Instant scroll
                // keeps the active thumbnail centred without that
                // pile-up.
                proxy.scrollTo(viewModel.pages[newIndex].id, anchor: .center)
            }
        }
    }
}

// MARK: - Single thumbnail row

private struct PageStripThumbnail: View {
    @Environment(\.theme) private var theme
    let page: Page
    let pageNumber: Int
    let size: CGSize
    let isCurrent: Bool
    let canMoveLeft: Bool
    let canMoveRight: Bool

    let onTap: () -> Void
    let onContextMenuDuplicate: () -> Void
    let onContextMenuDelete: () -> Void
    let onContextMenuAddAfter: () -> Void
    let onContextMenuAddBefore: () -> Void
    let onContextMenuMoveLeft: () -> Void
    let onContextMenuMoveRight: () -> Void

    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Paper background
                RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                    .fill(Color(UIColor(hex: "#FAFAF8")))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.medium)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                    .strokeBorder(
                        isCurrent ? theme.accent : theme.borderSubtle,
                        lineWidth: isCurrent ? 2 : 0.5
                    )
            )

            Text("\(pageNumber)")
                .font(.ceciliasNotesCaption)
                .foregroundColor(isCurrent ? theme.accent : theme.foregroundSubtle)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button { onContextMenuAddBefore() } label: {
                Label("Insert Page Before", systemImage: "rectangle.badge.plus")
            }
            Button { onContextMenuAddAfter() } label: {
                Label("Insert Page After", systemImage: "plus.rectangle")
            }
            Button { onContextMenuDuplicate() } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            Divider()
            // Reorder — swap this page with its left or right
            // neighbour. Hidden at the ends so the menu doesn't
            // surface no-op actions.
            if canMoveLeft {
                Button { onContextMenuMoveLeft() } label: {
                    Label("Move Left", systemImage: "arrow.left")
                }
            }
            if canMoveRight {
                Button { onContextMenuMoveRight() } label: {
                    Label("Move Right", systemImage: "arrow.right")
                }
            }
            if canMoveLeft || canMoveRight { Divider() }
            Button(role: .destructive) { onContextMenuDelete() } label: {
                Label("Delete Page", systemImage: "trash")
            }
        }
        .onAppear { loadThumbnail() }
        .onChange(of: page.updatedAt) { _, _ in
            // Phase 4E: composite key carries a fingerprint of
            // `strokeData`, so a new sketch produces a new entry
            // automatically — no manual invalidate needed. The
            // previous image stays visible until the new one is
            // ready (never flash to blank during regen).
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        let key = PageThumbnailCache.shared.composeKey(for: page)
        if let cached = PageThumbnailCache.shared.thumbnail(for: key) {
            image = cached
            return
        }
        Task {
            let result = await PageThumbnailCache.shared.generate(
                for: page,
                targetSize: size
            )
            // Don't blank the row if the render returned nil — the
            // previous image is a better fallback than empty paper.
            if let result {
                await MainActor.run { image = result }
            }
        }
    }
}
