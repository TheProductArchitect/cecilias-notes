import SwiftUI

/// Notebook card — typographic, no thumbnail. The notebook *is* its
/// cover tone: background and text colour come straight off
/// `NotebookCoverTone`, a ghost letter sits behind the title bleeding
/// off the bottom-right edge, and a single blue dot in the top-right
/// marks the most-recently-opened notebook across the whole library.
///
/// Functionality preserved from the previous design: inline rename,
/// pin / unpin, multi-select, drag-to-move, context menu, plus a new
/// "Change Cover" entry that opens the `CoverTonePickerView`.
struct NotebookCardView: View {
    let notebook: Notebook
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.theme) private var theme

    @State private var isHovered            = false
    @State private var isShowingCoverPicker = false
    // Inline title editing was retired — the card title is now
    // display-only. Renaming happens in the customise panel
    // (notebook → customise panel → name field), which is the
    // single edit path and dismisses cleanly via its keyboard
    // toolbar "Done" button. Removing the in-place TextField
    // eliminated the keyboard-dismissal bug that survived two
    // prior fix attempts.

    private static let cornerRadius: CGFloat = 3
    private static let borderColor   = Color(hex: "#ebebeb")

    private var isSelected: Bool { viewModel.selectedNotebookIds.contains(notebook.id) }
    private var isDuplicating: Bool { viewModel.duplicatingIds.contains(notebook.id) }

    /// True only for the single notebook the user opened most recently.
    /// Drives the blue accent dot in the top-right corner.
    private var isMostRecent: Bool {
        viewModel.mostRecentNotebookId == notebook.id
    }

    private var tone: NotebookCoverTone { notebook.coverTone }

    /// Recessive colour paired with the tone. On dark covers the
    /// supporting copy reads against `Color.white`; on light, against
    /// `Color.black`. The opacity rungs land on top of those.
    private func recessive(_ alpha: Double) -> Color {
        tone.isLight
            ? Color.black.opacity(alpha)
            : Color.white.opacity(alpha)
    }

    var body: some View {
        ZStack {
            cardBody
            overlays
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(border)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .scaleEffect(isHovered && !viewModel.isSelecting ? 1.01 : 1.0)
        .onHover { hovered in
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.precise)) { isHovered = hovered }
        }
        .onTapGesture {
            #if DEBUG
            dlog("[Library] card tap id=\(notebook.id) isSelecting=\(viewModel.isSelecting)")
            #endif
            if viewModel.isSelecting {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                    viewModel.toggleSelection(notebook)
                }
            } else {
                viewModel.selectedNotebookId = notebook.id
            }
        }
        .contextMenu { contextMenu }
        .popover(isPresented: $isShowingCoverPicker, arrowEdge: .top) {
            CoverTonePickerView(notebook: notebook) {
                isShowingCoverPicker = false
                viewModel.refresh()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.notebookLabel(
            title: notebook.title,
            subjectName: viewModel.subjects.first { $0.id == notebook.subjectId }?.name,
            pageCount: notebook.totalPageCount,
            modified: notebook.updatedAt
        ))
        .accessibilityHint(A11y.notebookHint)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Card body

    private var cardBody: some View {
        ZStack {
            tone.background

            // Ghost letter behind everything else, bleeds bottom-right.
            GhostLetter(
                character: notebook.title.first ?? "?",
                size: 96,
                onDarkBackground: !tone.isLight
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: 18, y: 18)
            .clipped()
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 0)
                bottomBlock
            }
            .padding(.top, 12)
            .padding(.horizontal, 11)
            .padding(.bottom, 11)
        }
    }

    // MARK: Top row

    private var topRow: some View {
        HStack(spacing: 6) {
            if notebook.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7.5, weight: .regular))
                    .foregroundStyle(recessive(tone.isLight ? 0.4 : 0.5))
                    .accessibilityHidden(true)
            }

            Text(subjectLabel)
                .font(.system(size: 7.5, weight: .regular))
                .tracking(0.08)
                .textCase(.uppercase)
                .foregroundStyle(recessive(tone.isLight ? 0.4 : 0.5))
                .lineLimit(1)

            Spacer(minLength: 0)

            // Active-state dot. Always rendered so layout doesn't
            // shift between cards — just transparent when this isn't
            // the most-recent notebook.
            Circle()
                .fill(theme.accent)
                .frame(width: 5, height: 5)
                .opacity(isMostRecent ? 1 : 0)
        }
    }

    private var subjectLabel: String {
        if let id = notebook.subjectId,
           let s = viewModel.subjects.first(where: { $0.id == id }) {
            return s.name.lowercased()
        }
        return "uncategorised"
    }

    // MARK: Bottom block (title + meta)

    private var bottomBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleView

            // AI summary — present only when Apple Intelligence is on
            // AND a cached summary exists. Graceful absence
            // otherwise (no spinner, no placeholder copy). 2-line
            // cap with a soft right fade for editorial polish.
            if let summary = aiSummary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(recessive(0.55))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.85),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.top, 2)
            }

            Text(pageCountLabel)
                .font(.system(size: 8, weight: .regular))
                .foregroundStyle(recessive(0.5))

            Text(lastOpenedLabel)
                .font(.system(size: 8, weight: .regular).italic())
                .foregroundStyle(recessive(0.4))
                .opacity(lastOpenedLabel.isEmpty ? 0 : 1)

            tagsRow

            // Agent attribution. Rendered only for `.inkbook` files
            // ingested from an external agent (Claude / GPT / etc).
            // Single 4pt dot + lowercase "agent" — matches the spec's
            // "subtle indicator, otherwise visually identical to any
            // user-created notebook" rule.
            if notebook.isAgentWritten {
                HStack(spacing: 3) {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 4, height: 4)
                    Text("agent")
                        .font(.system(size: 7, weight: .regular))
                        .tracking(0.1)
                        .foregroundStyle(recessive(0.4))
                }
                .padding(.top, 2)
                .accessibilityLabel("Written by an agent")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aiSummary: String? {
        guard IntelligenceService.shared.canRun else { return nil }
        return IntelligenceCache.summary(
            for: notebook.id,
            notebookUpdatedAt: notebook.updatedAt
        )
    }

    /// Reserved 20pt slot beneath the metadata so card heights stay
    /// uniform whether a notebook has tags or not. Renders up to 2
    /// tag pills + a "+N more" recessive label; spec says "up to 3"
    /// but 3 pills overflow the card width at the 10pt size, so we
    /// render 2 + overflow which mirrors how Reminders / Notion do
    /// it. Empty tag arrays show an invisible spacer.
    private var tagsRow: some View {
        let allTags    = notebook.tags
        let visible    = Array(allTags.prefix(2))
        let overflow   = max(0, allTags.count - visible.count)
        return HStack(spacing: 4) {
            ForEach(visible, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 7))
                    .lineLimit(1)
                    .foregroundStyle(tagPillForeground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tagPillBackground))
            }
            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(.system(size: 7, weight: .regular).italic())
                    .foregroundStyle(recessive(0.5))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .opacity(allTags.isEmpty ? 0 : 1)
        .accessibilityLabel(allTags.isEmpty
            ? Text("")
            : Text("Tags: \(allTags.joined(separator: ", "))")
        )
    }

    /// Tag pills are typographic only — they invert against the
    /// cover tone so they read on both light and dark covers.
    private var tagPillForeground: Color {
        tone.isLight ? Color.white : Color.black.opacity(0.85)
    }

    private var tagPillBackground: Color {
        tone.isLight ? Color.black.opacity(0.65) : Color.white.opacity(0.85)
    }

    private var pageCountLabel: String {
        notebook.totalPageCount == 1 ? "1 page" : "\(notebook.totalPageCount) pages"
    }

    private var lastOpenedLabel: String {
        // Prefer the "last opened" timestamp — that's the most
        // recently meaningful action for the user. Fall back to the
        // notebook's `createdAt` for rows the user hasn't opened yet
        // (notably MCP-imported notebooks that arrived via iCloud
        // sync), so every card surfaces *some* date instead of
        // showing a blank gap.
        if let opened = RecentNotebooksTracker.lastOpened(notebook.id) {
            return relativeShort(for: opened)
        }
        return "created \(relativeShort(for: notebook.createdAt))"
    }

    // MARK: Title (display-only)

    /// Display-only Text. The card's `.onTapGesture` opens the
    /// notebook; renaming happens exclusively inside the customise
    /// panel via the editor. No TextField, no focus state, no
    /// keyboard surface — eliminates the keyboard-dismissal bug
    /// that survived two prior fix attempts at the field level.
    private var titleView: some View {
        Text(notebook.title)
            .font(.system(size: 19, weight: .heavy))
            .tracking(-0.5)
            .foregroundStyle(tone.textColor)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
    }

    // MARK: Border

    @ViewBuilder
    private var border: some View {
        if tone.requiresBorder {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Self.borderColor, lineWidth: 0.5)
        }
        if isSelected {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(theme.accent, lineWidth: 1.5)
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlays: some View {
        if isDuplicating {
            Color.black.opacity(0.25)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
        }

        if viewModel.isSelecting {
            VStack {
                HStack {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.22))
                            .frame(width: 22, height: 22)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(isSelected ? theme.accent : Color.white)
                    }
                    .padding(8)
                }
                Spacer()
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            viewModel.selectedNotebookId = notebook.id
        } label: {
            Label("Open", systemImage: "arrow.up.right.square")
        }

        Button {
            // Rename / customise is now exclusively inside the
            // editor's customise panel. Marking the notebook for
            // auto-customise then opening it gives the user a
            // one-tap path from the card's context menu to the
            // panel's name field.
            NewNotebookCustomiseTrigger.mark(notebook.id)
            viewModel.selectedNotebookId = notebook.id
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            isShowingCoverPicker = true
        } label: {
            Label("Change Cover", systemImage: "paintpalette")
        }

        Button {
            viewModel.duplicateNotebook(notebook)
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }

        Button {
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                viewModel.togglePin(notebook)
            }
        } label: {
            Label(notebook.isPinned ? "Unpin" : "Pin", systemImage: notebook.isPinned ? "pin.slash" : "pin")
        }

        Button {
            viewModel.enterSelectMode(selecting: notebook)
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }

        Menu("Move to Subject…") {
            ForEach(viewModel.subjects) { subject in
                Button(subject.name) {
                    viewModel.moveNotebook(notebook, to: subject.id)
                }
            }
        }

        if let subjectId = notebook.subjectId {
            let foldersInSubject = viewModel.topLevelFolders(in: subjectId)
            if !foldersInSubject.isEmpty || notebook.folderId != nil {
                Menu("Move to Folder…") {
                    if notebook.folderId != nil {
                        Button("Out of Folder") {
                            viewModel.moveNotebook(notebook, toFolder: nil)
                        }
                        Divider()
                    }
                    ForEach(foldersInSubject) { folder in
                        Button(folder.name) {
                            viewModel.moveNotebook(notebook, toFolder: folder.id)
                        }
                    }
                }
            }
        }

        Button {
            viewModel.requestExport(for: notebook)
        } label: {
            Label("Share as PDF…", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            HapticManager.shared.notebookDeleted()
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                viewModel.deleteNotebook(notebook)
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - Relative date helper

/// Lowercase relative date suited to the recessive bottom-of-card line.
/// "today" / "yesterday" / "n days ago" / "n weeks ago" / "1 mar".
/// `Date.ceciliasNotesRelative` (used elsewhere) returns capitalised forms — this
/// mirror is local so the card's typography stays lowercase throughout.
private func relativeShort(for date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date)     { return "today" }
    if cal.isDateInYesterday(date) { return "yesterday" }

    let interval = Date().timeIntervalSince(date)
    let days     = Int(interval / 86_400)
    if days < 7        { return "\(days) days ago" }
    if days < 28       { return "\(days / 7) weeks ago" }

    let f = DateFormatter()
    f.dateFormat = "d MMM"
    return f.string(from: date).lowercased()
}
