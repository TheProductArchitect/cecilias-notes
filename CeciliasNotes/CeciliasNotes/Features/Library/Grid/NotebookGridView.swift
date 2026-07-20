import SwiftUI

struct NotebookGridView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.theme) private var theme

    private var columns: [GridItem] {
        DeviceCapabilities.prefersTabletLayout
            ? [GridItem(.adaptive(minimum: 168), spacing: 16)]
            : [GridItem(.flexible(), spacing: 12)]
    }
    private var cardWidth: CGFloat? {
        DeviceCapabilities.prefersTabletLayout ? 168 : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isSearchActive {
                searchArea
            } else {
                // Breadcrumb only shows when the user is *inside* a folder.
                if !viewModel.folderPath.isEmpty {
                    BreadcrumbBar(viewModel: viewModel)
                    CeciliasNotesDivider()
                }
                gridArea
            }
        }
        .background(theme.background)
        // Hidden ⌘N — the toolbar strip lives in the masthead now,
        // but keeping the keystroke bound here means the shortcut
        // works whenever focus is in the grid pane.
        .background(
            Button {
                viewModel.createNotebookWithFallback()
            } label: { EmptyView() }
                .keyboardShortcut("n", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: viewModel.isSearchActive)
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: viewModel.isSelecting)
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy), value: viewModel.folderPath.map(\.id))
#if os(macOS)
        .sheet(isPresented: $viewModel.isMacQuickLookPresented) {
            if let id = viewModel.macGridFocusedNotebookId,
               let notebook = viewModel.notebook(id: id) {
                MacNotebookQuickLookView(notebook: notebook) {
                    viewModel.selectedNotebookId = notebook.id
                }
            }
        }
#endif
        .background {
            if DeviceCapabilities.supportsGridKeyboardNavigation {
                gridKeyboardShortcuts
            }
        }
    }

    @ViewBuilder
    private var gridKeyboardShortcuts: some View {
        ZStack {
#if os(macOS)
            Button {
                guard viewModel.macGridFocusedNotebookId != nil else { return }
                viewModel.isMacQuickLookPresented = true
            } label: { EmptyView() }
            .keyboardShortcut(.space, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
#else
            Button {
                guard let id = viewModel.macGridFocusedNotebookId else { return }
                viewModel.selectedNotebookId = id
            } label: { EmptyView() }
            .keyboardShortcut(.space, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
#endif

            Button {
                guard let id = viewModel.macGridFocusedNotebookId else { return }
                viewModel.selectedNotebookId = id
            } label: { EmptyView() }
            .keyboardShortcut(.return, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)

            Button { navigateFocusedNotebook(-1) } label: { EmptyView() }
            .keyboardShortcut(.upArrow, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)

            Button { navigateFocusedNotebook(1) } label: { EmptyView() }
            .keyboardShortcut(.downArrow, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    private func navigateFocusedNotebook(_ delta: Int) {
        let notebooks = levelNotebooks
        guard !notebooks.isEmpty else { return }
        let currentIndex = notebooks.firstIndex { $0.id == viewModel.macGridFocusedNotebookId } ?? 0
        let nextIndex = min(max(0, currentIndex + delta), notebooks.count - 1)
        viewModel.macGridFocusedNotebookId = notebooks[nextIndex].id
    }

    // MARK: Grid (continued)

    /// Items at the current browser level. Folders render first, then notebooks
    /// — the same convention Files uses, and what users expect when "drill
    /// into folder" is a primary action.
    private var levelFolders:   [Folder]   { viewModel.foldersAtCurrentLevel }
    private var levelNotebooks: [Notebook] { viewModel.notebooksAtCurrentLevel }

    @ViewBuilder
    private var gridArea: some View {
        if levelFolders.isEmpty && levelNotebooks.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(levelFolders) { folder in
                        FolderCardView(folder: folder, viewModel: viewModel)
                            .frame(maxWidth: .infinity)
                            .frame(width: cardWidth, height: 200)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }

                    ForEach(levelNotebooks) { notebook in
                        notebookCard(notebook)
                    }
                }
                // 24pt of breathing room between the masthead's bottom
                // rule and the first row of cards.
                .padding(.top, 24)
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: levelFolders.map(\.id))
                .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: levelNotebooks.map(\.id))
            }
            // Scrolling the grid dismisses any open inline-rename
            // keyboard immediately. Works for floating + docked
            // keyboards uniformly — `.scrollDismissesKeyboard` is
            // the SwiftUI-native path that doesn't conflict with
            // PencilKit or other gesture recognisers downstream.
            .scrollDismissesKeyboard(.immediately)
            .onAppear { seedGridKeyboardFocusIfNeeded() }
            .onChange(of: levelNotebooks.map(\.id)) { _, _ in seedGridKeyboardFocusIfNeeded() }
        }
    }

    private func seedGridKeyboardFocusIfNeeded() {
        guard DeviceCapabilities.supportsGridKeyboardNavigation else { return }
        let notebooks = levelNotebooks
        guard !notebooks.isEmpty else {
            viewModel.macGridFocusedNotebookId = nil
            return
        }
        if let focused = viewModel.macGridFocusedNotebookId,
           notebooks.contains(where: { $0.id == focused }) {
            return
        }
        viewModel.macGridFocusedNotebookId = notebooks[0].id
    }

    /// One notebook tile. Carries the cross-subject move drag
    /// (unchanged from before) and, in manual sort mode only, adds a
    /// 6-dot drag handle overlay + a drop destination that reorders
    /// the dragged card immediately before this one via
    /// `LibraryViewModel.reorderNotebook(movedId:before:)`.
    @ViewBuilder
    private func notebookCard(_ notebook: Notebook) -> some View {
        let isManual   = viewModel.sortOrder == .manual
        let dragData   = (try? JSONEncoder().encode(NotebookTransferID(id: notebook.id))) ?? Data()
        NotebookCardView(notebook: notebook, viewModel: viewModel)
            .frame(maxWidth: .infinity)
            .frame(width: cardWidth, height: 224)
            .overlay(alignment: .topTrailing) {
                if isManual { reorderDragHandle }
            }
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .draggable(dragData) {
                NotebookCardView(notebook: notebook, viewModel: viewModel)
                    .frame(width: cardWidth ?? 168, height: 224)
                    .scaleEffect(1.03)
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
                    .opacity(0.85)
                    .onAppear { HapticManager.shared.dragReorderStarted() }
            }
            // Reorder-on-drop only in manual mode. Non-manual modes
            // fall through to the existing sidebar drop targets (move
            // to subject / folder). A drop on the source itself is a
            // no-op handled inside the VM.
            .dropDestination(for: Data.self) { items, _ in
                guard isManual else { return false }
                var landed = false
                for data in items {
                    if let decoded = try? JSONDecoder().decode(NotebookTransferID.self, from: data) {
                        viewModel.reorderNotebook(movedId: decoded.id, before: notebook.id)
                        landed = true
                    }
                }
                if landed { HapticManager.shared.dragReorderDropped() }
                return landed
            }
    }

    /// Small 6-dot grip rendered top-right of each card when manual
    /// sort is active. Purely a visual affordance — the underlying
    /// `.draggable` lives on the whole card so the user can pick up
    /// from anywhere, but the grip signals "this is reorderable" to
    /// match the spec.
    private var reorderDragHandle: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2) {
                    Circle().frame(width: 2, height: 2)
                    Circle().frame(width: 2, height: 2)
                }
            }
        }
        .foregroundStyle(theme.recessiveTertiary)
        .frame(width: 20, height: 20)
        .padding(6)
        .accessibilityLabel("Drag to reorder")
    }

    // MARK: Search

    @ViewBuilder
    private var searchArea: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: CeciliasNotes.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .fontWeight(.medium)
                    .foregroundColor(theme.foregroundSubtle)
                TextField("Search notes…", text: $viewModel.searchText)
                    .font(.ceciliasNotesBody)
                    .foregroundColor(theme.foreground)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(theme.foregroundSubtle)
                    }
                    .buttonStyle(.ceciliasNotesPressable)
                }
            }
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .frame(height: 44)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.md, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .transition(.move(edge: .top).combined(with: .opacity))

            CeciliasNotesDivider()

            if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Spacer()
            } else if let results = viewModel.searchResults, !results.isEmpty {
                SearchResultsView(results: results, query: viewModel.searchText, viewModel: viewModel)
            } else if viewModel.searchResults != nil {
                searchEmptyState
            } else {
                Spacer()
            }
        }
    }

    // MARK: Empty states

    /// Centred call-to-action empty state. Two variants, picked from
    /// the VM's current shape:
    ///   • No subjects yet → "create your first subject" → focuses the
    ///     inline rename on a fresh subject (same flow as the sidebar's
    ///     "+ new subject" tap).
    ///   • Subjects exist but the current context has no notebooks →
    ///     "create your first notebook" → routes through
    ///     `createNotebookWithFallback`, which lands the notebook in the
    ///     selected subject (or the inferred subject for `.recent` /
    ///     `.allNotes`) and opens the customise panel.
    @ViewBuilder
    private var emptyState: some View {
        if viewModel.subjects.isEmpty {
            CreateFirstCTA(
                title: "create your first subject",
                buttonLabel: "+ new subject",
                action: { viewModel.createSubject() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CreateFirstCTA(
                title: "create your first notebook",
                buttonLabel: "+ new notebook",
                action: { viewModel.createNotebookWithFallback() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchEmptyState: some View {
        EditorialEmptyState(
            primary: "nothing matches.",
            secondary: "try fewer words."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Centred create-CTA

/// Center-screen empty-state affordance for first-run / empty-subject
/// flows. Visually matches the editorial empty state's restraint —
/// generous whitespace, near-black SF Pro Display title — but adds a
/// single primary button to give a new user a clear next step.
private struct CreateFirstCTA: View {
    let title: String
    let buttonLabel: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .default))
                .foregroundStyle(theme.foreground)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(buttonLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(theme.accent)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Editorial empty state

/// Minimal empty state used across the Library main area. A 28pt
/// hairline rule, then a dim italic primary line, then a quieter
/// secondary line. No icon, no CTA — the redesign treats empty as
/// part of the editorial composition rather than a problem to solve.
private struct EditorialEmptyState: View {
    let primary: String
    let secondary: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Rectangle()
                .fill(theme.recessiveQuinary)
                .frame(width: 28, height: 1)

            Text(primary)
                .font(.system(size: 11.5, weight: .regular).italic())
                .foregroundStyle(theme.recessiveTertiary)

            Text(secondary)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(theme.recessiveQuinary)
        }
        .multilineTextAlignment(.center)
    }
}

// `GridToolbarView` migrated into `LibraryHeaderView` — search,
// filter, +, select, and the multi-select strip all live in the
// masthead now, leaving the grid below the rule with content only.

// MARK: - Breadcrumb bar

/// Files-style path bar shown above the grid when the user is inside a
/// folder. Tap a segment to pop the path back to that level. The leading
/// "back" chevron pops one level — quicker than aiming for the parent
/// segment when the path is deep.
private struct BreadcrumbBar: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: CeciliasNotes.Spacing.xs) {
            Button {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                    viewModel.navigateUp()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.ceciliasNotesHeadline)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.accent)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.ceciliasNotesPressable)
            .accessibilityLabel("Back")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // Subject root crumb
                    Button {
                        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                            viewModel.navigateToSubjectRoot()
                        }
                    } label: {
                        Text(viewModel.selectedSubjectName)
                            .font(.ceciliasNotesSubhead)
                            .foregroundColor(theme.accent)
                    }
                    .buttonStyle(.ceciliasNotesPressable)

                    // Folder segments
                    ForEach(Array(viewModel.folderPath.enumerated()), id: \.element.id) { idx, folder in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.foregroundSubtle)

                        if idx == viewModel.folderPath.count - 1 {
                            // Leaf — non-tappable, primary text
                            Text(folder.name)
                                .font(.ceciliasNotesSubhead)
                                .fontWeight(.semibold)
                                .foregroundColor(theme.foreground)
                        } else {
                            Button {
                                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                                    viewModel.navigateToBreadcrumb(index: idx)
                                }
                            } label: {
                                Text(folder.name)
                                    .font(.ceciliasNotesSubhead)
                                    .foregroundColor(theme.accent)
                            }
                            .buttonStyle(.ceciliasNotesPressable)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }
}

// `PinnedNotebooksStrip` was removed when the grid moved to
// single-context rendering. Pinned notebooks live in the sidebar's
// PINNED section now.

// MARK: - Move notebooks sheet (multi-select)

struct MoveNotebooksSheet: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.subjects) { subject in
                    Button {
                        viewModel.moveNotebooks(ids: viewModel.selectedNotebookIds, to: subject.id)
                        dismiss()
                    } label: {
                        Label {
                            Text(subject.name).foregroundColor(theme.foreground)
                        } icon: {
                            Circle()
                                .fill(Color(hex: subject.colorHex))
                                .frame(width: 12, height: 12)
                        }
                    }
                }
            }
            .navigationTitle("Move to")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }
}
