import SwiftUI
import UIKit

/// Top toolbar — 52pt tall, blur background, auto-hides after 3.5s of inactivity.
///
/// **Note:** the blur here is the only `UIVisualEffectView` use in the entire app.
struct EditorToolbarView: View {
    @ObservedObject var viewModel: EditorViewModel

    let onBack: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let canUndo: Bool
    let canRedo: Bool
    let onShare: () -> Void
    let onTogglePageStrip: () -> Void
    let onMoreMenuExportPDF: () -> Void
    let onMoreMenuPrint:     () -> Void
    let onMoreMenuDuplicatePage: () -> Void
    let onMoreMenuDeletePage: () -> Void
    let onMoreMenuPageSettings: () -> Void
    let onMoreMenuFullScreen: () -> Void
    let onMoreMenuInsertMedia: () -> Void
    let onToggleRecordingPanel: () -> Void

    @State private var titleBuffer: String = ""
    @State private var showUndoStackInfo = false
    @FocusState private var titleFocused: Bool

    private let toolbarHeight: CGFloat = 52

    var body: some View {
        HStack(spacing: Ink.Spacing.md) {
            leftCluster
            Spacer(minLength: Ink.Spacing.md)
            centreCluster
            Spacer(minLength: Ink.Spacing.md)
            rightCluster
        }
        .padding(.horizontal, Ink.Spacing.md)
        .frame(height: toolbarHeight)
        .background(toolbarBackground)
        .opacity(viewModel.isToolbarVisible ? 1 : 0)
        .allowsHitTesting(viewModel.isToolbarVisible)
        .inkAnimation(InkSpring.fade, value: viewModel.isToolbarVisible)
        .onChange(of: viewModel.isEditingTitle) { _, editing in
            if editing {
                titleBuffer  = viewModel.notebook.title
                titleFocused = true
            }
        }
    }

    // MARK: Background — only blur use in the app

    private var toolbarBackground: some View {
        ZStack {
            Color.inkBackgroundElevated.opacity(0.94)
            BlurMaterialView(material: .systemUltraThinMaterial)
                .opacity(0.6)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.inkBorderSubtle)
                .frame(height: 0.5)
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Left — back + title

    private var leftCluster: some View {
        HStack(spacing: Ink.Spacing.sm) {
            // Back
            Button {
                viewModel.prepareForDismissal()
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.inkTextPrimary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.inkPressable)
            .inkTapTarget()

            // Title — tap to rename
            if viewModel.isEditingTitle {
                TextField("Untitled", text: $titleBuffer)
                    .font(.inkHeadline)
                    .foregroundColor(.inkTextPrimary)
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { commitTitle() }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitTitle() }
                    }
                    .frame(maxWidth: 280)
            } else {
                Button {
                    viewModel.isEditingTitle = true
                } label: {
                    Text(viewModel.notebook.title)
                        .font(.inkHeadline)
                        .foregroundColor(.inkTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 280, alignment: .leading)
                }
                .buttonStyle(.inkPressable)
            }
        }
    }

    private func commitTitle() {
        viewModel.renameNotebook(titleBuffer)
        viewModel.isEditingTitle = false
        titleFocused = false
    }

    // MARK: Centre — page navigation

    private var centreCluster: some View {
        HStack(spacing: Ink.Spacing.sm) {
            Button {
                viewModel.goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(viewModel.currentPageIndex > 0 ? .inkTextSecondary : .inkTextTertiary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.inkPressable)
            .inkTapTarget()
            .disabled(viewModel.currentPageIndex == 0)

            Text("\(viewModel.currentPageIndex + 1) / \(viewModel.pages.count)")
                .font(.inkSubhead)
                .foregroundColor(.inkTextPrimary)
                .monospacedDigit()
                .frame(minWidth: 60)

            // → button states (per Stage 10 / Gap F):
            //   • Not on last page                  → chevron.right, active
            //   • Last page + autoAdd ON            → plus.circle, active (tap appends a page)
            //   • Last page + autoAdd OFF           → chevron.right, dimmed + disabled
            Button {
                viewModel.goToNextPage()
            } label: {
                Image(systemName: nextPageIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(nextPageColor)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.inkPressable)
            .inkTapTarget()
            .disabled(viewModel.isOnLastPage && !viewModel.autoAddEnabled)
            .opacity(viewModel.isOnLastPage && !viewModel.autoAddEnabled ? 0.3 : 1.0)
        }
    }

    private var nextPageIcon: String {
        if viewModel.isOnLastPage && viewModel.autoAddEnabled { return "plus.circle" }
        return "chevron.right"
    }

    private var nextPageColor: Color {
        if viewModel.isOnLastPage && viewModel.autoAddEnabled { return .inkAccentPrimary }
        if viewModel.isOnLastPage { return .inkTextTertiary }
        return .inkTextSecondary
    }

    // MARK: Right — strip / undo / redo / share / save / more

    private var rightCluster: some View {
        HStack(spacing: Ink.Spacing.xs) {
            iconButton("rectangle.bottomthird.inset.filled") { onTogglePageStrip() }

            // Mic button — accent tint when recording panel is open
            Button { onToggleRecordingPanel() } label: {
                Image(systemName: viewModel.isRecordingPanelVisible ? "mic.fill" : "mic")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(viewModel.isRecordingPanelVisible ? .inkAccentPrimary : .inkTextSecondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.inkPressable)
            .inkTapTarget()

            iconButton("arrow.uturn.backward", enabled: canUndo) { onUndo() }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in showUndoStackInfo = true }
                )
                .popover(isPresented: $showUndoStackInfo) {
                    UndoStackPopover(viewModel: viewModel)
                }

            iconButton("arrow.uturn.forward", enabled: canRedo) { onRedo() }

            iconButton("square.and.arrow.up") { onShare() }

            Menu {
                // Media insertion sub-menu
                Menu {
                    Button { viewModel.mediaInsertCoordinator.insertPhotos() }
                        label: { Label("Photo Library…",    systemImage: "photo.on.rectangle") }
                    Button { viewModel.mediaInsertCoordinator.insertFromFiles() }
                        label: { Label("Files…",             systemImage: "folder") }
                    Button { viewModel.mediaInsertCoordinator.insertFromCamera() }
                        label: { Label("Camera…",            systemImage: "camera") }
                    Button { viewModel.mediaInsertCoordinator.insertScan() }
                        label: { Label("Scan Document…",     systemImage: "doc.viewfinder") }
                } label: { Label("Insert Media", systemImage: "photo.badge.plus") }

                Divider()

                Button {
                    onMoreMenuExportPDF()
                } label: { Label("Export as PDF…", systemImage: "doc.richtext") }

                Button {
                    onMoreMenuPrint()
                } label: { Label("Print…", systemImage: "printer") }

                Button {
                    onMoreMenuDuplicatePage()
                } label: { Label("Duplicate Page", systemImage: "doc.on.doc") }

                Button(role: .destructive) {
                    onMoreMenuDeletePage()
                } label: { Label("Delete Page", systemImage: "trash") }

                Divider()

                // TODO: implement when per-page template picker ships (Issue 6 in feature backlog).
                // The `onMoreMenuPageSettings` callback is wired through the toolbar
                // initialiser but produces no useful behaviour, so the menu item is
                // hidden rather than shown as a stub.

                Button {
                    onMoreMenuFullScreen()
                } label: {
                    Label(
                        viewModel.isFullScreen ? "Exit Full Screen" : "Full Screen",
                        systemImage: viewModel.isFullScreen
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.inkTextSecondary)
                    .frame(width: 36, height: 36)
            }
            .inkTapTarget()

            // Save status — far right
            SaveStatusIndicator(status: viewModel.saveStatus)
                .padding(.leading, Ink.Spacing.sm)
        }
    }

    private func iconButton(
        _ systemName: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(enabled ? .inkTextSecondary : .inkTextTertiary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.inkPressable)
        .inkTapTarget()
        .disabled(!enabled)
    }
}

// MARK: - Undo stack popover

private struct UndoStackPopover: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        VStack(spacing: Ink.Spacing.sm) {
            Text("Undo Stack")
                .font(.inkHeadline)
                .foregroundColor(.inkTextPrimary)

            if let mgr = viewModel.canvasView?.undoManager {
                Text("\(mgr.canUndo ? "Has actions" : "Empty")")
                    .font(.inkFootnote)
                    .foregroundColor(.inkTextSecondary)
            }

            InkButton("Undo All", style: .destructive) {
                while viewModel.canvasView?.undoManager?.canUndo == true {
                    viewModel.canvasView?.undoManager?.undo()
                }
            }
        }
        .padding(Ink.Spacing.lg)
        .frame(width: 220)
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - UIVisualEffectView bridge

private struct BlurMaterialView: UIViewRepresentable {
    let material: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: material))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: material)
    }
}
