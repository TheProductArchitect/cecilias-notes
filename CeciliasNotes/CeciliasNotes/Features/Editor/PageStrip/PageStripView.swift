import SwiftUI
import UIKit

/// Bottom slide-in strip of page thumbnails.
///   • Each thumbnail: 80×104pt
///   • Current page: accent.primary border ring
///   • Long-press: context menu (Duplicate / Delete / Add Page After)
///   • Trailing + button: add page at end
struct PageStripView: View {
    @ObservedObject var viewModel: EditorViewModel

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
            .fill(Color.inkBackgroundElevated.opacity(0.94))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.inkBorderSubtle)
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
                            isCurrent: index == viewModel.currentPageIndex
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
                        }
                        .id(page.id)
                    }

                    // + add page button
                    Button {
                        viewModel.addPage()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.inkAccentPrimary)
                                .frame(width: thumbWidth, height: thumbHeight)
                                .overlay(
                                    RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                                        .strokeBorder(
                                            Color.inkAccentPrimary,
                                            style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                                        )
                                )
                        }
                    }
                    .buttonStyle(.inkPressable)
                }
                .padding(.horizontal, CeciliasNotes.Spacing.lg)
                .padding(.vertical, CeciliasNotes.Spacing.md)
            }
            .onChange(of: viewModel.currentPageIndex) { _, newIndex in
                guard newIndex < viewModel.pages.count else { return }
                withAnimation(.inkSpring(CeciliasNotesSpring.smooth)) {
                    proxy.scrollTo(viewModel.pages[newIndex].id, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Single thumbnail row

private struct PageStripThumbnail: View {
    let page: Page
    let pageNumber: Int
    let size: CGSize
    let isCurrent: Bool

    let onTap: () -> Void
    let onContextMenuDuplicate: () -> Void
    let onContextMenuDelete: () -> Void
    let onContextMenuAddAfter: () -> Void
    let onContextMenuAddBefore: () -> Void

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
                        isCurrent ? Color.inkAccentPrimary : Color.inkBorderSubtle,
                        lineWidth: isCurrent ? 2 : 0.5
                    )
            )

            Text("\(pageNumber)")
                .font(.inkCaption)
                .foregroundColor(isCurrent ? .inkAccentPrimary : .inkTextTertiary)
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
