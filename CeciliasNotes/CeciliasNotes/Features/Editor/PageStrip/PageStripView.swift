import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Payload for page-strip drag-and-drop. Carries the source page's
/// stable id so the drop handler can look it up in
/// `viewModel.pages` without trusting an index that may have
/// shifted under a concurrent edit.
struct PageDragItem: Transferable, Codable {
    let pageId: UUID
    let fromPageNumber: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

/// Bottom slide-in strip of page thumbnails.
///   • Each thumbnail: 80×104pt
///   • Current page: accent.primary border ring
///   • Long-press: context menu (Duplicate / Delete / Add Page After)
///   • Trailing + button: add page at end
struct PageStripView: View {
    @ObservedObject var viewModel: EditorViewModel
    @Environment(\.theme) private var theme

    /// Popover anchor for the template picker that opens off the
    /// trailing "+" button on long-press. Plain tap just adds a
    /// page with the notebook's current default template.
    @State private var showAddPageTemplatePicker: Bool = false

    private var isCompact: Bool { DeviceCapabilities.isPhoneIdiom }
    /// 80×104pt thumbs on iPad; 56×72pt on iPhone so the strip
    /// occupies a third of the screen instead of half. Page strip
    /// is opt-in on iPhone — by default the user navigates by
    /// tapping the page-number affordance in the toolbar — so when
    /// shown it gets the smaller footprint.
    private var thumbWidth:  CGFloat { isCompact ? 56 : 80 }
    private var thumbHeight: CGFloat { isCompact ? 72 : 104 }
    private var stripHeight: CGFloat { isCompact ? 96 : 140 }

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
                        // Drag-and-drop reorder. The user grabs a
                        // thumbnail and drops it on any other
                        // thumbnail; the source page slides into
                        // the destination's position (multi-step
                        // move, not just left/right by one). The
                        // existing context-menu Move Left / Move
                        // Right entries are kept for keyboard /
                        // accessibility paths but are no longer
                        // the only way to reorder.
                        .draggable(
                            PageDragItem(
                                pageId: page.id,
                                fromPageNumber: page.pageNumber
                            )
                        )
                        .dropDestination(for: PageDragItem.self) { items, _ in
                            guard let item = items.first,
                                  item.pageId != page.id,
                                  let source = viewModel.pages.first(where: { $0.id == item.pageId })
                            else { return false }
                            viewModel.movePage(source, to: page.pageNumber)
                            HapticManager.shared.toolSwitched()
                            return true
                        }
                    }

                    // + add page button — hidden on read-only
                    // devices. Page navigation still works via the
                    // thumbnails above, so the strip remains
                    // useful as a "jump to page N" affordance.
                    if DeviceCapabilities.canMutate {
                        Button {
                            // Tap +: insert a page using the notebook's
                            // current default template — no popover.
                            // Picker only appears when the user
                            // explicitly long-presses to choose a
                            // different template (or to change the
                            // default). Matches the "set once, stay
                            // out of the way" behaviour the page-strip
                            // is meant to have.
                            viewModel.addPage()
                            HapticManager.shared.pageAdded()
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
                        // Long-press opens the template picker for a
                        // one-off override. Picking a template always
                        // inserts a new page using it; the "also set
                        // as default" toggle on the picker pins the
                        // choice to `notebook.defaultTemplate` so
                        // subsequent taps on "+" pick it up.
                        //
                        // `highPriorityGesture` instead of
                        // `simultaneousGesture` so the long-press
                        // wins gesture arbitration against the
                        // Button's internal tap — under
                        // `simultaneousGesture` the tap also fired on
                        // release, accidentally appending an extra
                        // page every time the user long-pressed.
                        .highPriorityGesture(
                            LongPressGesture(minimumDuration: 0.45)
                                .onEnded { _ in
                                    showAddPageTemplatePicker = true
                                    HapticManager.shared.toolSwitched()
                                }
                        )
                        .popover(isPresented: $showAddPageTemplatePicker,
                                 attachmentAnchor: .point(.top),
                                 arrowEdge: .bottom) {
                            AddPageTemplatePicker(
                                currentDefault: viewModel.notebook.defaultTemplate,
                                onPick: { template, makeDefault in
                                    if makeDefault {
                                        viewModel.applyCustomTemplate(template)
                                    }
                                    viewModel.addPage(template: template)
                                    showAddPageTemplatePicker = false
                                },
                                onCancel: {
                                    showAddPageTemplatePicker = false
                                }
                            )
                            .presentationCompactAdaptation(.popover)
                        }
                    }
                }
                .padding(.horizontal, CeciliasNotes.Spacing.lg)
                .padding(.vertical, CeciliasNotes.Spacing.md)
            }
            .onChange(of: viewModel.currentPageIndex) { _, newIndex in
                guard newIndex >= 0, newIndex < viewModel.pages.count else { return }
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

// MARK: - AddPageTemplatePicker

/// Compact popover surfaced off the page-strip's trailing "+" button
/// via long-press. Picking a template always inserts a new page using
/// that template; the "also set as default" toggle pre-loaded from
/// whether the picked template already matches the notebook default
/// pins the choice to `notebook.defaultTemplate` as a side-effect.
///
/// The toggle is visible regardless of how the picker was opened —
/// users wanted explicit control over whether each long-press also
/// commits the choice to the default, not a hidden behaviour based
/// on which gesture opened the panel.
private struct AddPageTemplatePicker: View {
    let currentDefault: PageTemplate
    let onPick: (_ template: PageTemplate, _ makeDefault: Bool) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var makeDefaultToggle: Bool = false

    // Bumped from 56×74 → 64×84 so the template glyph isn't
    // visually crushed inside the popover.
    private let thumbSize = CGSize(width: 64, height: 84)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("pick a template for the new page")
                .font(.system(size: 11, weight: .regular).italic())
                .foregroundStyle(theme.recessiveQuaternary)

            ForEach(TemplateCategory.allCases, id: \.self) { category in
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.displayName)
                        .font(.system(size: 9, weight: .regular).italic())
                        .foregroundStyle(theme.recessiveQuaternary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(PageTemplate.allCases.filter { $0.category == category },
                                    id: \.self) { template in
                                Button {
                                    onPick(template, makeDefaultToggle)
                                } label: {
                                    VStack(spacing: 4) {
                                        TemplateThumbView(
                                            template: template,
                                            size: thumbSize
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(
                                                    template == currentDefault ? theme.accent : .clear,
                                                    lineWidth: template == currentDefault ? 1.5 : 0
                                                )
                                        )
                                        Text(template.displayName.lowercased())
                                            .font(.system(size: 9, weight: .regular))
                                            .foregroundStyle(theme.foregroundMuted)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Toggle(isOn: $makeDefaultToggle) {
                Text("also set as default for future pages in this notebook")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(theme.accent)
            .padding(.top, 6)
        }
        .padding(18)
        .frame(width: 440)
    }
}
