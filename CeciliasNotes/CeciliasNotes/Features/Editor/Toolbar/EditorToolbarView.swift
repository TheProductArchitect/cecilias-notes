import SwiftUI
import UIKit

/// Notebook header — the cover tone made visible at the top of the
/// editor. Carries identity (back chevron + subject + title), meta
/// (page count + last-opened) and the editor action chrome (page-strip
/// toggle, mic, undo/redo, share, more menu, save status). A ghost
/// letter sits behind everything bleeding off the right edge.
///
/// Auto-hides as soon as the user begins writing, leaving a 3pt
/// cover-tone bar at the top of the canvas as the return affordance.
/// State is owned by `EditorViewModel.headerVisibility` (see
/// `HeaderVisibility`).
struct EditorToolbarView: View {
    @ObservedObject var viewModel: EditorViewModel
    @Environment(\.theme) private var theme

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
    /// Step 6 — two-mode recording entry points. Both route into
    /// `RecordingSession.shared` from `EditorView`. Replaces the
    /// V5 "Quick note" / "Lecture" menu items.
    let onStartVoiceNote: () -> Void
    let onStartDictation: () -> Void
    /// Opens the cover-tone picker as a popover anchored to the more menu.
    var onOpenCoverPicker: (() -> Void)?

    @State private var titleBuffer: String = ""
    @FocusState private var titleFocused: Bool
    /// Step 6: drives the two-mode recording popover anchored to
    /// the mic button. Auto-closes on selection (popover dismisses,
    /// chosen mode starts immediately — no confirmation prompt).
    @State private var showRecordingPopover: Bool = false
    /// Drives the live mic-button glyph from the singleton state.
    @ObservedObject private var recordingSession = RecordingSession.shared

    private let toolbarHeight: CGFloat = 56

    private var tone: NotebookCoverTone { viewModel.notebook.coverTone }

    private var subjectName: String {
        // The editor doesn't carry a LibraryViewModel reference, so we
        // resolve the subject through the StorageService singleton.
        // The look-up is one fetch on every body re-evaluation, but
        // the subject list is small (handful of rows in practice) and
        // the toolbar only re-evaluates on viewModel change anyway.
        guard let id = viewModel.notebook.subjectId else { return "uncategorised" }
        return StorageService.shared
            .fetchSubjects()
            .first { $0.id == id }?
            .name
            .lowercased() ?? ""
    }

    /// Recessive opacity rung paired with the tone. Mirrors the helper
    /// on `NotebookCardView`.
    private func recessive(_ alpha: Double) -> Color {
        tone.isLight
            ? Color.black.opacity(alpha)
            : Color.white.opacity(alpha)
    }

    var body: some View {
        // Two-layer composition: the cover-tone background and ghost
        // letter live behind a row of interactive content. The
        // background bleeds upward through `.ignoresSafeArea(.top)` so
        // the status bar text (time, battery) sits over cover tone;
        // the interactive row stays inside the safe area.
        HStack(alignment: .center, spacing: 0) {
            identityCluster
            Spacer(minLength: CeciliasNotes.Spacing.md)
            actionCluster
            metaCluster
            SaveStatusIndicator(status: viewModel.saveStatus)
                .padding(.leading, CeciliasNotes.Spacing.sm)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
        .frame(height: toolbarHeight)
        .frame(maxWidth: .infinity)
        .background(alignment: .trailing) {
            // Ghost letter sits behind the row, anchored to the
            // trailing edge and bleeding off the right of the screen.
            GhostLetter(
                character: viewModel.notebook.title.first ?? "?",
                size: 200,
                onDarkBackground: !tone.isLight
            )
            .offset(x: 60)
            .clipped()
            .accessibilityHidden(true)
        }
        .background(
            // The cover-tone fill — extends up into the top safe area
            // so the system status bar reads against the cover tone,
            // not against an empty band of system background.
            tone.background.ignoresSafeArea(edges: .top)
        )
        .onChange(of: viewModel.isEditingTitle) { _, editing in
            if editing {
                titleBuffer  = viewModel.notebook.title
                titleFocused = true
            }
        }
    }

    // MARK: Identity (left)

    private var identityCluster: some View {
        HStack(spacing: 0) {
            backAndSubject
            verticalDivider
            titleView
        }
    }

    /// Tap target combining back chevron and subject eyebrow. Behaves
    /// as one button so a finger landing anywhere on the cluster
    /// returns to the library.
    private var backAndSubject: some View {
        Button {
            viewModel.prepareForDismissal()
            onBack()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(recessive(0.4))
                if !subjectName.isEmpty {
                    Text(subjectName)
                        .font(.system(size: 9.5, weight: .regular))
                        .tracking(0.08)
                        .textCase(.uppercase)
                        .foregroundStyle(recessive(0.5))
                        .lineLimit(1)
                }
            }
            .frame(height: toolbarHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to library")
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(recessive(0.15))
            .frame(width: 0.5, height: 16)
            .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var titleView: some View {
        let titleSize = WordmarkSizing.notebookHeaderSize(for: viewModel.notebook.title)

        if viewModel.isEditingTitle {
            TextField("Untitled", text: $titleBuffer)
                .font(.system(size: titleSize, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(tone.textColor)
                .focused($titleFocused)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }
                .frame(maxWidth: 280)
        } else {
            Button {
                viewModel.openCustomisePanel()
            } label: {
                Text(viewModel.notebook.title)
                    .font(.system(size: titleSize, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(tone.textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open the customise panel")
        }
    }

    private func commitTitle() {
        viewModel.renameNotebook(titleBuffer)
        viewModel.isEditingTitle = false
        titleFocused = false
    }

    // MARK: Action chrome (right of centre)

    private var actionCluster: some View {
        HStack(spacing: 4) {
            iconButton("rectangle.bottomthird.inset.filled") { onTogglePageStrip() }

            // Step 6: two-mode recording entry. Tap the mic to open
            // a popover offering Voice note + Dictation; pick one
            // and the recording starts immediately (no confirmation
            // — the popover IS the choice point). The mic glyph
            // switches to `.fill` while either mode is active so
            // the user can see at a glance that something's
            // recording.
            Button {
                if recordingSession.state.isRecording {
                    Task { await recordingSession.stop() }
                } else {
                    showRecordingPopover = true
                }
            } label: {
                Image(systemName: recordingSession.state.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(
                        recordingSession.state.isRecording
                            ? theme.accent
                            : recessive(0.4)
                    )
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showRecordingPopover) {
                recordingModePopover
                    .presentationCompactAdaptation(.popover)
            }

            iconButton("arrow.uturn.backward", enabled: canUndo) { onUndo() }
            iconButton("arrow.uturn.forward",  enabled: canRedo) { onRedo() }
            iconButton("square.and.arrow.up") { onShare() }

            Menu { moreMenuContent } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(recessive(0.4))
                    .frame(width: 32, height: 32)
            }
        }
    }

    @ViewBuilder
    private var moreMenuContent: some View {
        Button {
            viewModel.openCustomisePanel()
        } label: { Label("Customise Notebook…", systemImage: "sparkles") }

        if let onOpenCoverPicker {
            Button {
                onOpenCoverPicker()
            } label: { Label("Cover", systemImage: "paintpalette") }
        }

        Divider()

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

        Button { onMoreMenuExportPDF() }
            label: { Label("Export as PDF…", systemImage: "doc.richtext") }
        Button { onMoreMenuPrint() }
            label: { Label("Print…",         systemImage: "printer") }
        Button { onMoreMenuDuplicatePage() }
            label: { Label("Duplicate Page", systemImage: "doc.on.doc") }
        Button(role: .destructive) { onMoreMenuDeletePage() }
            label: { Label("Delete Page", systemImage: "trash") }

        Button(role: .destructive) {
            while viewModel.canvasView?.undoManager?.canUndo == true {
                viewModel.canvasView?.undoManager?.undo()
            }
        } label: { Label("Undo All Strokes", systemImage: "arrow.uturn.backward.circle") }
        .disabled(!canUndo)

        Divider()

        Button { onMoreMenuFullScreen() } label: {
            Label(
                viewModel.isFullScreen ? "Exit Full Screen" : "Full Screen",
                systemImage: viewModel.isFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            )
        }

        Button { viewModel.toggleFocusMode() } label: {
            Label(
                viewModel.isFocusMode ? "Exit Focus Mode" : "Focus Mode",
                systemImage: viewModel.isFocusMode
                    ? "rectangle.portrait.inset.filled"
                    : "rectangle.portrait"
            )
        }
    }

    // MARK: Meta (page count + last opened, top-right)

    private var metaCluster: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(pageCountLabel)
                .font(.system(size: 8, weight: .regular))
                .foregroundStyle(recessive(0.22))
            if !lastOpenedLabel.isEmpty {
                Text(lastOpenedLabel)
                    .font(.system(size: 8, weight: .regular).italic())
                    .foregroundStyle(recessive(0.15))
            }
        }
        .padding(.leading, CeciliasNotes.Spacing.md)
    }

    private var pageCountLabel: String {
        viewModel.pages.count == 1 ? "1 page" : "\(viewModel.pages.count) pages"
    }

    private var lastOpenedLabel: String {
        guard let date = RecentNotebooksTracker.lastOpened(viewModel.notebook.id)
        else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        if days < 7  { return "\(days) days ago" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: date).lowercased()
    }

    // MARK: Helpers

    private func iconButton(
        _ systemName: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(enabled ? recessive(0.4) : recessive(0.2))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Recording mode popover (Step 6)

    /// Two-row recording-mode picker. Subtitle text under each
    /// option communicates the consequence so users know what
    /// they're committing to before they tap (architecture §9: no
    /// confirmation prompts — popover IS the choice point).
    @ViewBuilder
    private var recordingModePopover: some View {
        VStack(spacing: 0) {
            recordingModeRow(
                title: "Voice note",
                subtitle: "Quick voice memo. Inline pill on this page.",
                icon: "mic"
            ) {
                showRecordingPopover = false
                onStartVoiceNote()
            }
            CeciliasNotesDivider()
            recordingModeRow(
                title: "Dictation",
                subtitle: "Long-form with live transcript. New page.",
                icon: "text.bubble"
            ) {
                showRecordingPopover = false
                onStartDictation()
            }
        }
        .frame(width: 280)
    }

    private func recordingModeRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 24, height: 24, alignment: .center)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(theme.foregroundSubtle)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
