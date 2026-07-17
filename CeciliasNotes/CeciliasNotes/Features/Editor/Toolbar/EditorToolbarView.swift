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
    let onMoreMenuExportMarkdown: () -> Void
    let onMoreMenuFindInNotebook: () -> Void
    let onMoreMenuPrint:     () -> Void
    let onMoreMenuDuplicatePage: () -> Void
    let onMoreMenuDeletePage: () -> Void
    /// Opens the AI "Summarize this page" result sheet. Only invoked
    /// when `AIService.shared.canRun` — the menu item is absent
    /// otherwise (graceful-absence rule for AI surfaces).
    let onMoreMenuSummarizePage: () -> Void
    let onMoreMenuAskAboutPage: () -> Void
    let onMoreMenuCopyPageAsImage: () -> Void
    let onMoreMenuActualSize: () -> Void
    let onMoreMenuPageSettings: () -> Void
    let onMoreMenuFullScreen: () -> Void
    let onMoreMenuNotebookInfo: () -> Void
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

    // Auto-hide pin is a permanent toolbar button — tap to flip
    // the per-notebook `autoHideHeader` setting. The earlier
    // auto-popover that explained the icon on first opens was
    // removed; the icon's filled/slash state plus its
    // accessibility label carry the discovery work.

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
            // Step 10: sync state badge — sits beside the
            // local-save indicator since both communicate
            // "is my data safe" state. Read-only, tap-opens-menu.
            SyncStatusIndicator()
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

        if viewModel.isEditingTitle && DeviceCapabilities.canMutate {
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
        } else if DeviceCapabilities.canMutate {
            // iPad: title is tappable → opens the customise panel
            // where the rename happens.
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
        } else {
            // Read-only devices show the title as a static label —
            // no edit affordance, no tap target, no customise
            // panel entry point.
            Text(viewModel.notebook.title)
                .font(.system(size: titleSize, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(tone.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 320, alignment: .leading)
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
            // Page strip toggle stays available on read-only
            // devices — it's pure navigation, not mutation.
            iconButton("rectangle.bottomthird.inset.filled") { onTogglePageStrip() }

            // Mic gates on `canRecord`, NOT `canMutate`. `canRecord`
            // is true on every device today (iPhone records too), so
            // the gate is currently a no-op — it stays because
            // `RecordingSession.start*` guards on the same flag, and
            // if a read-only device class ever returns, the mic must
            // disappear rather than render dead.
            if DeviceCapabilities.canRecord {
                recordingMicButton
            }
            iconButton("arrow.uturn.backward", enabled: canUndo) { onUndo() }.mutationOnly()
            iconButton("arrow.uturn.forward",  enabled: canRedo) { onRedo() }.mutationOnly()

            // Palette show/hide and focus mode used to live here as
            // standalone buttons, but with mic + undo/redo + pin +
            // share + ellipsis the row was visually noisy and the
            // focus-mode glyph (`rectangle.portrait`) read like a
            // share button — easy to fat-finger. Both actions stay
            // accessible from the More menu below; promoting them
            // to the action cluster wasn't pulling its weight.

            // Auto-hide pin toggle. A single 32×32 icon button —
            // tapping flips the per-notebook `autoHideHeader`. On the
            // first three opens (while still off and untouched) a
            // popover auto-appears next to the button for ~3s
            // explaining what it does, then dismisses itself. After
            // that it stays silent.
            autoHidePinButton.mutationOnly()

            // Share is read-only friendly (export, send PDF) and
            // stays visible everywhere. Bumped to a labelled pill
            // so it's easier to find when the action cluster has a
            // few similar-looking glyphs next to it — the icon-only
            // version was getting fat-fingered with the pin.
            Button {
                #if DEBUG
                dlog("[Share] toolbar share button tapped")
                #endif
                onShare()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .regular))
                    Text("share")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(recessive(0.55))
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share or export")

            // The ellipsis menu surfaces several mutation actions
            // (customise notebook, etc.); on read-only devices
            // most entries are removed inside `moreMenuContent`
            // and only read-friendly items remain. Keep the menu
            // mounted so users can still discover those.
            Menu { moreMenuContent } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(recessive(0.4))
                    .frame(width: 32, height: 32)
            }
        }
    }

    /// Mic button extracted so the actionCluster reads cleanly and
    /// the `.mutationOnly()` modifier can wrap the entire surface
    /// (button + popover + onChange wiring) in one shot.
    @ViewBuilder
    private var recordingMicButton: some View {
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
        // Explicit attachment anchor + arrow edge. Without these,
        // SwiftUI's first attempt at presenting this popover silently
        // no-ops because the Button's frame hasn't been measured by
        // the time `showRecordingPopover` flips true — the canonical
        // iPadOS 17+ "tap two or three times before the menu shows"
        // symptom. `.rect(.bounds)` pins the anchor to the button's
        // actual rendered bounds (resolved synchronously from the
        // layout pass), and `.fixedSize()` on the content gives the
        // popover an unambiguous size on the first present so the
        // adaptation engine doesn't fall back to sheet behaviour
        // and then bounce back to popover.
        .popover(
            isPresented: $showRecordingPopover,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            recordingModePopover
                .fixedSize()
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: showRecordingPopover) { _, nowOpen in
            if nowOpen {
                viewModel.beginInteraction(.recordingPanel)
            } else {
                viewModel.endInteraction(.recordingPanel)
            }
        }
    }

    @ViewBuilder
    private var moreMenuContent: some View {
        // Mutation-only entries — Customise, Cover, Insert Media,
        // Summarize, Duplicate / Delete page, Undo All. Hidden on
        // read-only devices so the menu stays useful: Export PDF,
        // Print, Full Screen still appear below.
        if DeviceCapabilities.canMutate {
            Button {
                viewModel.openCustomisePanel()
            } label: { Label("Customise Notebook…", systemImage: "sparkles") }

            Button { onMoreMenuNotebookInfo() } label: {
                Label("Notebook Info…", systemImage: "info.circle")
            }

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

            // AI capability — absent entirely when AI can't run (no
            // disabled state), per the graceful-absence rule for AI
            // surfaces documented on `IntelligenceService`.
            if AIService.shared.canRun {
                Button { onMoreMenuSummarizePage() }
                    label: { Label("Summarize Page", systemImage: "sparkles") }
                Button { onMoreMenuAskAboutPage() }
                    label: { Label("Ask About Page", systemImage: "bubble.left.and.text.bubble.right") }

                Divider()
            }
        }

        Button { onMoreMenuActualSize() }
            label: { Label("Actual Size", systemImage: "arrow.up.left.and.arrow.down.right") }

        Button { onMoreMenuCopyPageAsImage() }
            label: { Label("Copy Page as Image", systemImage: "doc.on.doc") }

        Button { onMoreMenuExportPDF() }
            label: { Label("Export as PDF…", systemImage: "doc.richtext") }
        Button { onMoreMenuExportMarkdown() }
            label: { Label("Export as Markdown…", systemImage: "doc.plaintext") }
        Button { onMoreMenuFindInNotebook() }
            label: { Label("Find in Notebook…", systemImage: "text.magnifyingglass") }
        Button { onMoreMenuPrint() }
            label: { Label("Print…",         systemImage: "printer") }

        if DeviceCapabilities.canMutate {
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
        }

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

    // MARK: Auto-hide pin button

    /// Permanent toolbar pin button. The icon mirrors the
    /// per-notebook `autoHideHeader`:
    ///   • OFF (toolbar always visible) → filled pin
    ///   • ON  (toolbar slides away while writing) → pin.slash
    /// Tap flips the state — direct, no popover, no nudging.
    private var autoHidePinButton: some View {
        let isAutoHideOn = viewModel.notebook.autoHideHeader
        return Button {
            viewModel.notebook.autoHideHeader = !isAutoHideOn
            viewModel.notifyAutoHidePreferenceChanged()
        } label: {
            Image(systemName: isAutoHideOn ? "pin.slash.fill" : "pin.fill")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(
                    isAutoHideOn ? theme.accent : recessive(0.4)
                )
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isAutoHideOn ? "Unpin (toolbar auto-hides)" : "Pin toolbar"
        )
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
