import SwiftUI
import SwiftData

/// Recessive 118pt-wide sidebar. No header, no logo, no panel tint —
/// it sits beside the masthead and recedes until the user reaches for
/// it. Two sections (subjects, recent), then a bottom bar with
/// "+ new subject" and the iCloud status indicator. Pinned subjects
/// surface at the top of the SUBJECTS list with the pin glyph; there
/// is no separate PINNED section.
///
/// Section labels are 7.5pt tracked uppercase quaternary recessive.
/// Subject rows are 11pt primary recessive (#aaa-equivalent), with the
/// active subject promoted to near-black + leading 1.5pt rule. No
/// coloured dots on subjects per the redesign.
struct SubjectSidebarView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @EnvironmentObject private var cloudSync: CloudSyncManager
    // The sidebar bottom bar now opts out of keyboard avoidance
    // unconditionally via `.ignoresSafeArea(.keyboard)` — see
    // `bottomBar`. The `KeyboardObserver` dependency the earlier
    // floating-only gate required is no longer needed here.

    /// Session-local edit mode. Toggled by the "Edit" button in the
    /// subjects section label row. In edit mode the drag handles
    /// become more prominent and a minus delete button appears on
    /// each row. Not persisted — leaving and re-entering the sidebar
    /// resets to the default browse state.
    @State private var isEditingSubjects: Bool = false
    @Environment(\.theme) private var theme

    private static let horizontalInset: CGFloat = 13

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    subjectsSection
                    sectionDivider
                    recentContextRow
                }
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            // Allow the user to dismiss the floating keyboard by
            // scrolling the sidebar — matches iOS conventions and
            // prevents a stuck keyboard from blocking the bottomBar.
            .scrollDismissesKeyboard(.immediately)

            bottomBar
        }
        // Ignore keyboard avoidance for the entire sidebar layout.
        // Without this, the floating keyboard shifts the whole VStack
        // (including the bottomBar's "+ new notebook" / "+ new subject"
        // buttons) upward, even though `bottomBar` itself already
        // declares `.ignoresSafeArea(.keyboard)` — SwiftUI applies
        // keyboard inset to the closest enclosing scrollable container,
        // which is this outer VStack. See Bug 3.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(theme.surface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.recessiveQuinary)
                .frame(width: 0.5)
                .ignoresSafeArea()
        }
    }

    // MARK: Subjects

    private var subjectsSection: some View {
        // Subjects arrive from the VM already pinned-first via
        // `fetchSubjects()` (sorted by `isPinned` descending). Splitting
        // here lets us slip a hairline between the two groups without
        // re-sorting client-side.
        let pinned   = viewModel.subjects.filter { $0.isPinned }
        let unpinned = viewModel.subjects.filter { !$0.isPinned }
        return VStack(alignment: .leading, spacing: 0) {
            subjectsSectionHeader
            // "All Notes" — kept as the first row so the cross-subject
            // view stays reachable. Italicised so it reads as a meta
            // entry rather than a real subject.
            allNotesRow
            ForEach(pinned) { subject in
                subjectRow(for: subject)
            }
            // Hairline separator between pinned and unpinned groups.
            // Only rendered when at least one subject is pinned —
            // an empty-pinned sidebar shows no extra rule.
            if !pinned.isEmpty && !unpinned.isEmpty {
                Rectangle()
                    .fill(theme.recessiveQuinary)
                    .frame(height: 0.5)
                    .padding(.horizontal, Self.horizontalInset)
                    .padding(.vertical, 6)
            }
            ForEach(unpinned) { subject in
                subjectRow(for: subject)
            }
        }
    }

    /// "subjects" label paired with an Edit / Done text button on the
    /// right. The button is hidden when there are no subjects yet —
    /// reordering and deleting both require existing rows.
    private var subjectsSectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("subjects")
                .font(.system(size: 7.5, weight: .regular))
                .tracking(0.08)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveQuaternary)
            Spacer(minLength: 0)
            if !viewModel.subjects.isEmpty {
                Button {
                    withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                        isEditingSubjects.toggle()
                    }
                } label: {
                    Text(isEditingSubjects ? "done" : "edit")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(theme.recessiveTertiary)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.bottom, 8)
    }

    private var allNotesRow: some View {
        AllNotesListRow(
            viewModel: viewModel,
            countColor: theme.foregroundSubtle
        )
    }

    private func subjectRow(for subject: Subject) -> some View {
        SubjectListRow(
            subject: subject,
            viewModel: viewModel,
            countColor: theme.foregroundSubtle,
            isEditing: isEditingSubjects
        )
    }

    // MARK: Recent (context switcher)

    /// Single row at the bottom of the sidebar's scroll content that
    /// switches the grid into `.recent` context — the spec's default
    /// home view. Replaces the older "RECENT" section that listed
    /// individual recent notebooks; the grid is the canonical surface
    /// for that list now.
    private var recentContextRow: some View {
        let isSelected = viewModel.selectedContext == .recent
        return SidebarRow(
            isSelected: isSelected,
            onTap: { viewModel.selectedContext = .recent }
        ) {
            HStack(spacing: 0) {
                Text("recent")
                    .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? theme.foreground : theme.recessivePrimary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        bottomBarContent
            // The sidebar is a fixed-position panel — it should
            // never reflow for any keyboard, floating or docked.
            // Unconditional `.ignoresSafeArea(.keyboard)` keeps
            // "+ new notebook" / "+ new subject" anchored at the
            // bottom of the sidebar regardless of keyboard state.
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var bottomBarContent: some View {
        VStack(spacing: 0) {
            sidebarDivider

            // "+ new notebook" — only visible when a specific subject
            // is selected. From `.recent` or `.allNotes` it would be
            // ambiguous which subject the new notebook would land in,
            // so the affordance is hidden until the user picks a
            // subject from the list above. "+ new subject" stays
            // visible always — subject creation is context-free.
            if case .subject = viewModel.selectedContext {
                Button {
                    createNewNotebook()
                } label: {
                    Text("+ new notebook")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Self.horizontalInset)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                sidebarDivider
            }

            Button {
                viewModel.createSubject()
            } label: {
                Text("+ new subject")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.horizontalInset)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            sidebarDivider

            HStack(spacing: 6) {
                iCloudStatusView(syncStatus: cloudSync.syncStatus)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.horizontalInset)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(theme.recessiveQuinary)
            .frame(height: 0.5)
            .opacity(0.4)
            .padding(.horizontal, Self.horizontalInset)
    }

    /// Bridge for the "+ new notebook" button. The VM's
    /// `createNotebookWithFallback` handles the "no subject selected"
    /// case by promoting the inferred subject; from `.subject(...)`
    /// it just routes to the existing creation flow.
    private func createNewNotebook() {
        viewModel.createNotebookWithFallback()
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7.5, weight: .regular))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
            .padding(.horizontal, Self.horizontalInset)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(theme.recessiveQuinary)
            .frame(height: 0.5)
            .opacity(0.4)
            .padding(.horizontal, Self.horizontalInset)
            .padding(.vertical, 12)
    }

}

// MARK: - Generic recessive row

/// A subject / All-Notes row with optional active-state treatment:
/// leading 1.5pt black rule + near-black promoted text, applied by the
/// parent via the `isSelected` flag. The row provides the tap target,
/// hover styling (none — this is recessive), and content-shape so taps
/// near the right edge still register.
private struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let onTap: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        content()
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(theme.foreground)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

// MARK: - All Notes row

/// "all notes" entry at the top of the sidebar. Mirrors
/// `SubjectListRow` — owns its own SwiftData `@Query` for the count
/// badge so it stays live across creates / deletes / cross-session
/// writes without depending on `LibraryViewModel.refresh()`.
private struct AllNotesListRow: View {
    @ObservedObject var viewModel: LibraryViewModel
    let countColor: Color
    @Environment(\.theme) private var theme

    @Query(filter: #Predicate<Notebook> { $0.isDeleted == false })
    private var notebooks: [Notebook]

    private var isSelected: Bool { viewModel.selectedContext == .allNotes }

    var body: some View {
        SidebarRow(
            isSelected: isSelected,
            onTap: { viewModel.selectedContext = .allNotes }
        ) {
            HStack(spacing: 0) {
                Text("all notes")
                    .font(.system(size: 11, weight: isSelected ? .bold : .regular).italic())
                    .foregroundStyle(isSelected ? theme.foreground : theme.recessivePrimary)
                Spacer(minLength: 0)
                Text("\(notebooks.count)")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(countColor)
            }
        }
        .dropDestination(for: Data.self) { items, _ in
            var landed = false
            for data in items {
                if let decoded = try? JSONDecoder().decode(NotebookTransferID.self, from: data) {
                    viewModel.moveNotebook(id: decoded.id, to: nil)
                    landed = true
                }
            }
            if landed { HapticManager.shared.dragReorderDropped() }
            return true
        }
    }
}

// MARK: - Subject list row

/// Single sidebar row for one subject. Owns its own SwiftData
/// `@Query` so the count badge stays live with store changes — the
/// older approach (computing the count inside `SubjectSidebarView`'s
/// row body via a manual `storage.fetchNotebooks(...).count`) was
/// only re-evaluated when the parent view's `@Published subjects`
/// array changed, which produced a visible lag on app launch and
/// after cross-context creates.
private struct SubjectListRow: View {
    let subject: Subject
    @ObservedObject var viewModel: LibraryViewModel
    let countColor: Color
    let isEditing: Bool

    @Query private var notebooks: [Notebook]
    @Environment(\.theme) private var theme

    init(
        subject: Subject,
        viewModel: LibraryViewModel,
        countColor: Color,
        isEditing: Bool
    ) {
        self.subject     = subject
        self.viewModel   = viewModel
        self.countColor  = countColor
        self.isEditing   = isEditing

        let subjectId = subject.id
        _notebooks = Query(
            filter: #Predicate<Notebook> { notebook in
                notebook.subjectId == subjectId && notebook.isDeleted == false
            }
        )
    }

    private var isSelected: Bool {
        viewModel.selectedContext == .subject(subject.id)
    }

    /// Drag payload for subject reorder. Distinct from
    /// `NotebookTransferID` so a single Data-typed drop destination
    /// on this row can route notebook-moves vs subject-reorders by
    /// trying each decode in turn.
    private var subjectDragData: Data {
        (try? JSONEncoder().encode(SubjectTransferID(subjectId: subject.id))) ?? Data()
    }

    var body: some View {
        SidebarRow(
            isSelected: isSelected,
            onTap: {
                #if DEBUG
                print("[Sidebar] subject tap id=\(subject.id) name=\(subject.name)")
                #endif
                viewModel.selectedContext = .subject(subject.id)
            }
        ) {
            HStack(spacing: 4) {
                // Edit-mode delete affordance — a standard iOS red
                // minus circle that soft-deletes the subject and
                // returns the user to All Notes if the deleted one
                // was active.
                if isEditing {
                    Button {
                        HapticManager.shared.destructiveConfirmed()
                        viewModel.deleteSubject(subject)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(theme.danger)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(subject.name)")
                    .transition(.scale.combined(with: .opacity))
                }

                // Pinned indicator — small filled pin in the brand
                // accent. The icon is the *only* visual distinction
                // for pinned rows; no separate "Pinned" section label.
                if subject.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(theme.accent)
                }
                // Inline rename when `viewModel.renamingSubjectId` matches.
                // Driven by the context-menu "Rename" action and the
                // auto-rename hand-off after a fresh `createSubject()`.
                // Without this branch the rename flag was set but nothing
                // surfaced the editor — the user saw no prompt and several
                // subjects ended up named "New Subject". See Reg 4.
                if viewModel.renamingSubjectId == subject.id {
                    SubjectInlineRename(
                        initialName: subject.name,
                        onCommit: { newName in
                            viewModel.renameSubject(subject, name: newName)
                            viewModel.renamingSubjectId = nil
                        },
                        onCancel: {
                            viewModel.renamingSubjectId = nil
                        }
                    )
                } else {
                    Text(subject.name.lowercased())
                        .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? theme.foreground : theme.recessivePrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(notebooks.count)")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(countColor)

                // Drag handle — always present, brighter + larger
                // in edit mode. The `.draggable` lives on the handle
                // so a long-press anywhere else on the row falls
                // through to the existing context menu and tap
                // gesture stays clean.
                subjectDragHandle
            }
        }
        // Single Data-typed drop destination dispatches by payload
        // kind: notebook ID → move into this subject (existing); a
        // subject ID → reorder (new). The decoders are mutually
        // exclusive on JSON keys so the first successful decode
        // wins.
        .dropDestination(for: Data.self) { items, _ in
            var landed = false
            for data in items {
                if let decoded = try? JSONDecoder().decode(NotebookTransferID.self, from: data) {
                    viewModel.moveNotebook(id: decoded.id, to: subject.id)
                    landed = true
                } else if let decoded = try? JSONDecoder().decode(SubjectTransferID.self, from: data) {
                    viewModel.reorderSubject(movedId: decoded.subjectId, before: subject.id)
                    landed = true
                }
            }
            if landed { HapticManager.shared.dragReorderDropped() }
            return landed
        }
        .contextMenu {
            Button {
                viewModel.togglePinSubject(subject)
            } label: {
                Label(
                    subject.isPinned ? "Unpin" : "Pin",
                    systemImage: subject.isPinned ? "pin.slash" : "pin"
                )
            }
            Button {
                viewModel.renamingSubjectId = subject.id
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                HapticManager.shared.destructiveConfirmed()
                viewModel.deleteSubject(subject)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// 6-dot grip. Default rendering is recessive-quinary; edit mode
    /// bumps to recessive-secondary with a slightly larger dot to
    /// make the affordance "grabbable" without changing the row
    /// height. The handle is itself the drag origin.
    private var subjectDragHandle: some View {
        let dotSize: CGFloat = isEditing ? 2.5 : 2.0
        let dotColor: Color  = isEditing
            ? theme.recessiveSecondary
            : theme.recessiveQuinary
        return VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2) {
                    Circle().frame(width: dotSize, height: dotSize)
                    Circle().frame(width: dotSize, height: dotSize)
                }
            }
        }
        .foregroundStyle(dotColor)
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
        .accessibilityLabel("Drag to reorder")
        .draggable(subjectDragData) {
            // Drag preview — minimal pill showing the subject name.
            Text(subject.name.lowercased())
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.surfaceElevated)
                        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
                )
                .onAppear { HapticManager.shared.dragReorderStarted() }
        }
    }
}

// MARK: - iCloud status indicator

struct iCloudStatusView: View {
    let syncStatus: CloudSyncManager.SyncStatus
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 11))
            .fontWeight(.regular)
            .foregroundStyle(symbolColor)
            .symbolEffect(.pulse, isActive: isPulsing)
            .ceciliasNotesAnimation(CeciliasNotesSpring.smooth, value: symbolName)
    }

    /// SF Symbol per the spec — green check for synced, blue pulsing
    /// arrow for syncing, grey slash for offline / waiting, orange
    /// warning for error.
    private var symbolName: String {
        switch syncStatus {
        case .disabled:          return "cloud"
        case .checking:          return "arrow.clockwise.icloud"
        case .upToDate:          return "checkmark.icloud"
        case .syncing:           return "arrow.clockwise.icloud"
        case .waitingForNetwork: return "cloud.slash"
        case .error:             return "exclamationmark.icloud"
        }
    }

    private var symbolColor: Color {
        switch syncStatus {
        case .disabled, .waitingForNetwork:
            return theme.recessiveTertiary
        case .checking, .syncing:
            return theme.accent
        case .upToDate:
            return Color(light: Color(hex: "#34c759"),
                         dark:  Color(hex: "#30d158"))
        case .error:
            return Color(light: Color(hex: "#ff9500"),
                         dark:  Color(hex: "#ff9f0a"))
        }
    }

    private var isPulsing: Bool {
        if case .syncing = syncStatus { return true }
        if case .checking = syncStatus { return true }
        return false
    }
}


// MARK: - SubjectInlineRename

/// Inline text-field editor used by both flows that surface
/// `viewModel.renamingSubjectId`:
///   • Long-press → context-menu → "Rename"
///   • Fresh subject created via "+ New Subject" (auto-focused so
///     the user types the name without an extra tap).
///
/// Matches the inline-edit styling pattern used elsewhere in the
/// editor (small SF Pro, near-black foreground, hairline underline).
/// Commit on Return; cancel on Escape or focus loss with no edits.
private struct SubjectInlineRename: View {

    let initialName: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @Environment(\.theme) private var theme

    @State private var draft: String
    @FocusState private var focused: Bool

    init(
        initialName: String,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialName = initialName
        self.onCommit = onCommit
        self.onCancel = onCancel
        _draft = State(initialValue: initialName.lowercased())
    }

    var body: some View {
        TextField("subject name", text: $draft)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(theme.foreground)
            .focused($focused)
            .submitLabel(.done)
            .onSubmit {
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { onCancel() } else { onCommit(trimmed) }
            }
            .onAppear { focused = true }
            .onChange(of: focused) { _, isFocused in
                // Focus-loss commits if there is content; cancels otherwise.
                guard !isFocused else { return }
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed == initialName {
                    onCancel()
                } else {
                    onCommit(trimmed)
                }
            }
    }
}
