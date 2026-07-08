import SwiftUI

/// Cover-tone notebook masthead for Mac — identity only: back +
/// subject eyebrow, heavy title, ghost letter, page meta, sync.
/// The action icons (mic / pin / share / more) live one row down in
/// `MacEditorActionCluster`, docked at the right of the format
/// toolbar — the masthead stays quiet brand surface, and the top of
/// the window stops double-parking chrome.
struct MacEditorHeaderView: View {
    @Bindable var notebook: Notebook
    @ObservedObject var state: MacLibraryState
    let pageCount: Int
    @Environment(\.theme) private var theme

    let onBack: () -> Void

    @State private var titleBuffer = ""
    @FocusState private var titleFocused: Bool

    private let toolbarHeight: CGFloat = 56

    private var tone: NotebookCoverTone { notebook.coverTone }

    private var subjectName: String {
        guard let id = notebook.subjectId else { return "uncategorised" }
        return StorageService.shared
            .fetchSubjects()
            .first { $0.id == id }?
            .name
            .lowercased() ?? ""
    }

    private func recessive(_ alpha: Double) -> Color {
        tone.isLight ? Color.black.opacity(alpha) : Color.white.opacity(alpha)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            identityCluster
            Spacer(minLength: CeciliasNotes.Spacing.md)
            metaCluster
            SyncStatusIndicator()
                .padding(.leading, CeciliasNotes.Spacing.sm)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
        .frame(height: toolbarHeight)
        .frame(maxWidth: .infinity)
        .background(alignment: .trailing) {
            GhostLetter(
                character: notebook.title.first ?? "?",
                size: 200,
                onDarkBackground: !tone.isLight
            )
            .offset(x: 60)
            .clipped()
            .accessibilityHidden(true)
        }
        .background(tone.background)
        .onChange(of: state.isEditingNotebookTitle) { _, editing in
            if editing {
                titleBuffer = notebook.title
                titleFocused = true
            }
        }
    }

    // MARK: Identity

    private var identityCluster: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
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
            .macSuppressFocusRing()
            .accessibilityLabel("Back to library")

            Rectangle()
                .fill(recessive(0.15))
                .frame(width: 0.5, height: 16)
                .padding(.horizontal, 12)

            titleView
        }
    }

    @ViewBuilder
    private var titleView: some View {
        let titleSize = WordmarkSizing.notebookHeaderSize(for: notebook.title)
        if state.isEditingNotebookTitle {
            TextField("Untitled", text: $titleBuffer)
                .font(.system(size: titleSize, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(tone.textColor)
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }
                .frame(maxWidth: 280)
        } else {
            Button {
                state.openCustomisePanel()
            } label: {
                Text(notebook.title)
                    .font(.system(size: titleSize, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(tone.textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            .buttonStyle(.plain)
            .macSuppressFocusRing()
            .accessibilityHint("Open the customise panel; double-click to rename")
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                titleBuffer = notebook.title
                state.isEditingNotebookTitle = true
            })
        }
    }

    private func commitTitle() {
        MacNotebookCustomization.rename(notebook, title: titleBuffer, storage: StorageService.shared)
        state.isEditingNotebookTitle = false
        titleFocused = false
    }

    private var metaCluster: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(pageCount == 1 ? "1 page" : "\(pageCount) pages")
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

    private var lastOpenedLabel: String {
        guard let date = RecentNotebooksTracker.lastOpened(notebook.id) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        if days < 7 { return "\(days) days ago" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: date).lowercased()
    }
}

/// Mic / pin / share / more — the editor's utility rail, docked at
/// the right end of the format toolbar row (theme-coloured chrome,
/// not cover-tone: it sits on the toolbar surface, not the masthead).
struct MacEditorActionCluster: View {
    @Bindable var notebook: Notebook
    @ObservedObject var state: MacLibraryState
    @Environment(\.theme) private var theme

    let onShare: () -> Void
    let onExportPDF: () -> Void
    let onExportMarkdown: () -> Void
    let onFindInNotebook: () -> Void
    let onPrint: () -> Void
    let onDuplicatePage: () -> Void
    let onDeletePage: () -> Void
    let onSummarizePage: () -> Void
    let onAskAboutPage: () -> Void
    let onCopyPageAsImage: () -> Void
    let onResetZoom: () -> Void
    let onPageTemplate: () -> Void
    let onToggleFocusMode: () -> Void
    let onInsertImage: () -> Void
    let onInsertSticky: () -> Void
    let onStartVoiceNote: () -> Void
    let onStartTranscription: () -> Void
    let onAddPage: () -> Void
    let onNotebookInfo: () -> Void

    @State private var showRecordingPopover = false
    @ObservedObject private var recordingSession = MacRecordingSession.shared

    var body: some View {
        HStack(spacing: 4) {
            recordingMicButton
            autoHidePinButton
            Button(action: onShare) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .regular))
                    Text("share")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(theme.recessiveSecondary)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .macSuppressFocusRing()
            .accessibilityLabel("Share or export")

            Menu { moreMenu } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(theme.recessiveSecondary)
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
            .macSuppressFocusRing()
        }
    }

    @ViewBuilder
    private var recordingMicButton: some View {
        Button {
            if recordingSession.mode.isActive {
                Task { await recordingSession.stop() }
            } else {
                showRecordingPopover = true
            }
        } label: {
            Image(systemName: recordingSession.mode.isActive ? "mic.fill" : "mic")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(recordingSession.mode.isActive ? theme.accent : theme.recessiveSecondary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .macSuppressFocusRing()
        .popover(isPresented: $showRecordingPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    showRecordingPopover = false
                    onStartTranscription()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Meeting Transcription", systemImage: "text.bubble")
                        Text("Text appears as you speak — summary added on top when you stop")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.recessiveTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .macEditorChromeButton()

                Divider().padding(.horizontal, 10)

                Button {
                    showRecordingPopover = false
                    onStartVoiceNote()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Voice Note", systemImage: "waveform")
                        Text("Audio only — transcribed after you stop")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.recessiveTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .macEditorChromeButton()
            }
            .padding(.vertical, 6)
            .frame(width: 260)
            .macSuppressFocusRing()
        }
        .onChange(of: showRecordingPopover) { _, open in
            if open {
                state.beginHeaderInteraction(.recordingPanel)
            } else {
                state.endHeaderInteraction(.recordingPanel, notebook: notebook)
            }
        }
    }

    private var autoHidePinButton: some View {
        let isAutoHideOn = notebook.autoHideHeader
        return Button {
            notebook.autoHideHeader = !isAutoHideOn
            state.notifyAutoHidePreferenceChanged(notebook: notebook)
        } label: {
            Image(systemName: isAutoHideOn ? "pin.slash.fill" : "pin.fill")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isAutoHideOn ? theme.accent : theme.recessiveSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .macSuppressFocusRing()
        .accessibilityLabel(isAutoHideOn ? "Unpin (toolbar auto-hides)" : "Pin toolbar")
    }

    @ViewBuilder
    private var moreMenu: some View {
        Button {
            state.openCustomisePanel()
        } label: {
            Label("Customise Notebook…", systemImage: "sparkles")
        }

        Button(action: onNotebookInfo) {
            Label("Notebook Info…", systemImage: "info.circle")
        }

        Divider()

        Menu {
            Button(action: onInsertImage) { Label("Image…", systemImage: "photo") }
            Button(action: onInsertSticky) { Label("Sticky Note", systemImage: "note.text") }
        } label: {
            Label("Insert", systemImage: "plus.square.on.square")
        }

        Button(action: onPageTemplate) { Label("Page Template", systemImage: "square.grid.2x2") }
        Button(action: onAddPage) { Label("Add Page", systemImage: "doc.badge.plus") }

        Divider()

        if IntelligenceService.shared.canRun {
            Button(action: onSummarizePage) { Label("Summarize Page", systemImage: "sparkles") }
            Button(action: onAskAboutPage) { Label("Ask About Page", systemImage: "bubble.left.and.text.bubble.right") }
            Divider()
        }

        Button(action: onResetZoom) { Label("Actual Size", systemImage: "arrow.up.left.and.arrow.down.right") }
        Button(action: onCopyPageAsImage) { Label("Copy Page as Image", systemImage: "doc.on.doc") }
        Button(action: onExportPDF) { Label("Export as PDF…", systemImage: "doc.richtext") }
        Button(action: onExportMarkdown) { Label("Export as Markdown…", systemImage: "doc.plaintext") }
        Button(action: onFindInNotebook) { Label("Find in Notebook…", systemImage: "text.magnifyingglass") }
        Button(action: onPrint) { Label("Print…", systemImage: "printer") }

        Divider()

        Button(action: onDuplicatePage) { Label("Duplicate Page", systemImage: "doc.on.doc") }
        Button(role: .destructive, action: onDeletePage) { Label("Delete Page", systemImage: "trash") }

        Divider()

        Button(action: onToggleFocusMode) {
            Label(
                state.isFocusMode ? "Exit Focus Mode" : "Focus Mode",
                systemImage: state.isFocusMode ? "rectangle.portrait.inset.filled" : "rectangle.portrait"
            )
        }
    }

}

/// 44pt-tall tap target above the 3pt return bar when the header is hidden.
struct MacHeaderRevealOverlay: View {
    let tone: NotebookCoverTone
    let onReveal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(tone.background)
                .frame(height: 3)
            Color.clear
                .frame(height: 41)
                .contentShape(Rectangle())
                .onTapGesture(perform: onReveal)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
    }
}
