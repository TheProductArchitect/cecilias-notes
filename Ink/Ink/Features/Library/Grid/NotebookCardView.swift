import SwiftUI

struct NotebookCardView: View {
    let notebook: Notebook
    @ObservedObject var viewModel: LibraryViewModel

    @State private var isHovered        = false
    @State private var isEditingTitle   = false
    @State private var titleBuffer      = ""
    @FocusState private var titleFocused: Bool

    private var isSelected: Bool { viewModel.selectedNotebookIds.contains(notebook.id) }
    private var isDuplicating: Bool { viewModel.duplicatingIds.contains(notebook.id) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cardBody
            overlays
        }
        .scaleEffect(isHovered && !viewModel.isSelecting ? 1.01 : 1.0)
        .overlay(selectionRing)
        .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.lg, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Ink.Radius.lg, style: .continuous))
        .onHover { hovered in
            withAnimation(.inkSpring(InkSpring.precise)) { isHovered = hovered }
        }
        .onTapGesture {
            // Title-tap consumes its own gesture (Button below); this fires for
            // the rest of the card surface.
            if isEditingTitle { return }
            if viewModel.isSelecting {
                withAnimation(.inkSpring(InkSpring.snappy)) {
                    viewModel.toggleSelection(notebook)
                }
            } else {
                viewModel.selectedNotebookId = notebook.id
            }
        }
        .contextMenu { contextMenu }
        // Prepare the medium generator on touch-down so the haptic fires with
        // zero warm-up latency when the long-press succeeds. Fire when the
        // long-press completes (just before SwiftUI decides whether to show
        // the context menu or start a drag — same haptic moment for both).
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onChanged { _ in HapticManager.shared.prepare(for: .contextMenu) }
                .onEnded   { _ in HapticManager.shared.contextMenuOpened() }
        )
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
        VStack(spacing: 0) {
            coverArea
            infoArea
        }
        .background(Color.inkBackgroundElevated)
        .overlay(
            RoundedRectangle(cornerRadius: Ink.Radius.lg, style: .continuous)
                .strokeBorder(
                    isHovered ? Color.inkBorderDefault : Color.inkBorderSubtle,
                    lineWidth: 0.5
                )
        )
    }

    // MARK: Cover (top 60%)

    private var coverArea: some View {
        ZStack(alignment: .bottomLeading) {
            // Base colour
            Color(UIColor(hex: notebook.coverColorHex))

            // Texture overlay
            CoverTextureCanvas(texture: notebook.coverTexture)

            // Thumbnail (full bleed over colour + texture)
            if let data = notebook.thumbnailData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            }

            // Page count badge
            Text("\(notebook.totalPageCount)p")
                .font(.inkCaption)
                .foregroundColor(.white)
                .padding(.horizontal, Ink.Spacing.xs)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.35))
                .clipShape(Capsule())
                .padding(Ink.Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200 * 0.60)  // 60% of card height
        .clipped()
    }

    // MARK: Inline-editable title

    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            TextField("Untitled", text: $titleBuffer)
                .font(.inkSubhead)
                .foregroundColor(.inkTextPrimary)
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }
                // Subtle highlight matches the spec's "only a subtle highlight when focused".
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.inkAccentSecondary.opacity(0.5))
                )
        } else {
            Button {
                guard !viewModel.isSelecting else { return }
                titleBuffer = notebook.title
                isEditingTitle = true
                // Defer focus to next runloop so the TextField exists first.
                DispatchQueue.main.async { titleFocused = true }
            } label: {
                Text(notebook.title)
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.inkPressable)
        }
    }

    private func commitTitle() {
        let trimmed = titleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != notebook.title {
            viewModel.renameNotebook(notebook, newTitle: trimmed)
        }
        isEditingTitle = false
        titleFocused = false
    }

    // MARK: Info area (bottom 40%)

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.micro) {
            titleView

            // Subject name — only visible in All Notes (no subject filter active)
            if viewModel.selectedSubjectId == nil,
               let subjectId = notebook.subjectId,
               let subject = viewModel.subjects.first(where: { $0.id == subjectId }) {
                Text(subject.name)
                    .font(.inkCaption)
                    .foregroundColor(.inkTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(notebook.updatedAt.inkRelative)
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
        }
        .padding(Ink.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 200 * 0.40)
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlays: some View {
        // Loading spinner during duplicate
        if isDuplicating {
            Color.black.opacity(0.25)
                .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.lg, style: .continuous))
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
        }

        // Pin indicator
        if notebook.isPinned && !viewModel.isSelecting {
            Image(systemName: "pin.fill")
                .font(.system(size: 11))
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.85))
                .padding(Ink.Spacing.xs)
                .background(Color.black.opacity(0.3))
                .clipShape(Circle())
                .padding(Ink.Spacing.xs)
        }

        // Multi-select checkbox — backed by a translucent black disc instead of a shadow,
        // so the checkmark stays legible over any cover colour without breaking the no-shadow rule.
        if viewModel.isSelecting {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: 26, height: 26)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .fontWeight(.medium)
                    .foregroundColor(isSelected ? .inkAccentPrimary : .white)
            }
            .padding(Ink.Spacing.xs)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var selectionRing: some View {
        RoundedRectangle(cornerRadius: Ink.Radius.lg, style: .continuous)
            .strokeBorder(
                isSelected ? Color.inkAccentPrimary : Color.clear,
                lineWidth: 2
            )
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
            titleBuffer = notebook.title
            isEditingTitle = true
            DispatchQueue.main.async { titleFocused = true }
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            viewModel.duplicateNotebook(notebook)
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }

        Button {
            withAnimation(.inkSpring(InkSpring.snappy)) {
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
            Button("Uncategorised") {
                viewModel.moveNotebook(notebook, to: nil)
            }
            ForEach(viewModel.subjects) { subject in
                Button(subject.name) {
                    viewModel.moveNotebook(notebook, to: subject.id)
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
            withAnimation(.inkSpring(InkSpring.smooth)) {
                viewModel.deleteNotebook(notebook)
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - Date formatting

extension Date {
    var inkRelative: String {
        let now      = Date()
        let interval = now.timeIntervalSince(self)
        let calendar = Calendar.current

        if interval < 60            { return "Just now" }
        if interval < 3_600         { return "\(Int(interval / 60)) min ago" }
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }

        let days = Int(interval / 86_400)
        if days < 7                 { return "\(days) days ago" }

        let f        = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: self)
    }
}
