import SwiftUI

struct NotebookGridView: View {
    @ObservedObject var viewModel: LibraryViewModel

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            GridToolbarView(viewModel: viewModel)
            InkDivider()

            if viewModel.isSearchActive {
                searchArea
            } else {
                // Breadcrumb only shows when the user is *inside* a folder.
                // At the subject root the toolbar's title already says
                // "Maths" / "All Notes" — duplicating that as a breadcrumb
                // would be visual noise.
                if !viewModel.folderPath.isEmpty {
                    BreadcrumbBar(viewModel: viewModel)
                    InkDivider()
                }
                gridArea
            }
        }
        .background(Color.inkBackgroundPrimary)
        .animation(.inkSpring(InkSpring.smooth), value: viewModel.isSearchActive)
        .animation(.inkSpring(InkSpring.smooth), value: viewModel.isSelecting)
        .animation(.inkSpring(InkSpring.snappy), value: viewModel.folderPath.map(\.id))
    }

    // MARK: Grid

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
                VStack(alignment: .leading, spacing: 0) {
                    // Pinned strip — only at the subject root, not inside a
                    // folder (the folder is its own scope).
                    if viewModel.currentFolder == nil && !viewModel.pinnedNotebooks.isEmpty {
                        PinnedNotebooksStrip(viewModel: viewModel)
                    }

                    // Main grid: folders first, then notebooks.
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(levelFolders) { folder in
                            FolderCardView(folder: folder, viewModel: viewModel)
                                .frame(width: 168, height: 200)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }

                        ForEach(levelNotebooks) { notebook in
                            NotebookCardView(notebook: notebook, viewModel: viewModel)
                                .frame(width: 168, height: 200)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                                // Drag to reorder (manual sort only) or to drop
                                // onto a folder card.
                                .draggable(
                                    (try? JSONEncoder().encode(NotebookTransferID(id: notebook.id)))
                                        ?? Data()
                                ) {
                                    NotebookCardView(notebook: notebook, viewModel: viewModel)
                                        .frame(width: 168, height: 200)
                                        .opacity(0.6)
                                        .onAppear { HapticManager.shared.dragReorderStarted() }
                                }
                        }
                    }
                    .padding(24)
                    .animation(.inkSpring(InkSpring.smooth), value: levelFolders.map(\.id))
                    .animation(.inkSpring(InkSpring.smooth), value: levelNotebooks.map(\.id))
                }
            }
        }
    }

    // MARK: Search

    @ViewBuilder
    private var searchArea: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: Ink.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .fontWeight(.medium)
                    .foregroundColor(.inkTextTertiary)
                TextField("Search notes…", text: $viewModel.searchText)
                    .font(.inkBody)
                    .foregroundColor(.inkTextPrimary)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.inkTextTertiary)
                    }
                    .buttonStyle(.inkPressable)
                }
            }
            .padding(.horizontal, Ink.Spacing.md)
            .frame(height: 44)
            .background(Color.inkBackgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.md, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .transition(.move(edge: .top).combined(with: .opacity))

            InkDivider()

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

    @ViewBuilder
    private var emptyState: some View {
        if let folder = viewModel.currentFolder {
            // Inside an empty folder — different from "subject is empty".
            VStack(spacing: Ink.Spacing.md) {
                InkEmptyState(
                    icon: "folder",
                    title: "\"\(folder.name)\" is empty",
                    subtitle: "Add a notebook or a subfolder."
                )
                HStack(spacing: Ink.Spacing.sm) {
                    InkButton("New Notebook", style: .primary) {
                        viewModel.createUntitledNotebookAndOpen()
                    }
                    InkButton("New Folder", style: .secondary) {
                        viewModel.createFolderAtCurrentLevel()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let subjectId = viewModel.selectedSubjectId,
                  let subject = viewModel.subjects.first(where: { $0.id == subjectId }) {
            // Subject-specific empty
            VStack(spacing: Ink.Spacing.md) {
                InkEmptyState(
                    icon: "tray",
                    title: "Nothing in \(subject.name)",
                    subtitle: "Create a notebook, a folder, or move one here."
                )
                HStack(spacing: Ink.Spacing.sm) {
                    InkButton("New Notebook", style: .primary) {
                        viewModel.createUntitledNotebookAndOpen()
                    }
                    InkButton("New Folder", style: .secondary) {
                        viewModel.createFolderAtCurrentLevel()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // "All Notes" empty state — no creation CTA. Notebooks
            // belong to a subject; this is the cross-subject view.
            InkEmptyState(
                icon: "book.closed",
                title: "No notebooks yet",
                subtitle: "Pick a subject in the sidebar to create one."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchEmptyState: some View {
        VStack(spacing: Ink.Spacing.md) {
            InkEmptyState(
                icon: "magnifyingglass",
                title: "No results",
                subtitle: "Try a different search term."
            )
            InkButton("Clear Search", style: .ghost) {
                viewModel.deactivateSearch()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Grid toolbar

private struct GridToolbarView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var showMoveSheet = false
    @AppStorage(PersonalIdentity.nameKey) private var userName: String = ""

    /// Top-left title. When the user is at the subject root and has set
    /// a name, surface the personalised greeting (`"alex's notes"`).
    /// Inside a folder we keep showing the leaf folder name so the
    /// breadcrumb path remains legible.
    private var titleText: String {
        if viewModel.currentFolder != nil {
            return viewModel.currentFolder?.name ?? viewModel.selectedSubjectName
        }
        if !userName.isEmpty {
            return libraryGreeting(forName: userName)
        }
        // Spec: "If userName is empty, the slot is empty." Returning ""
        // collapses the Text to zero width; the grid below carries the
        // screen's purpose.
        return ""
    }

    var body: some View {
        HStack(spacing: Ink.Spacing.md) {
            if viewModel.isSelecting {
                selectingToolbar
            } else {
                normalToolbar
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
        .sheet(isPresented: $showMoveSheet) {
            MoveNotebooksSheet(viewModel: viewModel)
        }
    }

    // Normal mode
    private var normalToolbar: some View {
        Group {
            // Inside a folder, the breadcrumb bar carries the path; show
            // just the leaf name here so the title doesn't compete. At
            // the subject root, the personalised greeting takes over.
            Text(titleText)
                .font(.inkHeadline)
                .foregroundColor(.inkTextPrimary)
                .lineLimit(1)

            Spacer()

            // Search
            Button {
                withAnimation(.inkSpring(InkSpring.smooth)) {
                    viewModel.isSearchActive.toggle()
                    if !viewModel.isSearchActive { viewModel.deactivateSearch() }
                }
            } label: {
                Image(systemName: viewModel.isSearchActive ? "xmark" : "magnifyingglass")
                    .fontWeight(.medium)
                    .foregroundColor(.inkTextSecondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.inkPressable)
            .keyboardShortcut("f", modifiers: .command)

            // Sort
            Menu {
                ForEach(NotebookSortOrder.allCases) { order in
                    Button {
                        viewModel.sortOrder = order
                    } label: {
                        Label(order.rawValue, systemImage: order.symbolName)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .fontWeight(.medium)
                    .foregroundColor(
                        viewModel.sortOrder == .manual ? .inkAccentPrimary : .inkTextSecondary
                    )
                    .frame(width: 44, height: 44)
            }

            // Select
            Button("Select") {
                withAnimation(.inkSpring(InkSpring.snappy)) {
                    viewModel.isSelecting = true
                }
            }
            .font(.inkBody)
            .foregroundColor(.inkAccentPrimary)

            // "All Notes" is *view-only* — every notebook must live under
            // a subject (or a folder inside one). Hide creation
            // affordances when no subject is selected; the user picks a
            // subject from the sidebar to create.
            if viewModel.selectedSubjectId != nil {
                // Hidden ⌘N → New Notebook. The visible "+" is a menu
                // (below) because we have two creation paths;
                // keyboardShortcut on a Menu would only open the menu,
                // so we keep the shortcut on a zero-size button.
                Button {
                    viewModel.createUntitledNotebookAndOpen()
                } label: { EmptyView() }
                .keyboardShortcut("n", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

                Menu {
                    Button {
                        viewModel.createUntitledNotebookAndOpen()
                    } label: {
                        Label("New Notebook", systemImage: "book.closed")
                    }
                    Button {
                        viewModel.createFolderAtCurrentLevel()
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.inkHeadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, Ink.Spacing.md)
                        .frame(height: 36)
                        .background(Color.inkAccentPrimary)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // Multi-select mode
    private var selectingToolbar: some View {
        Group {
            Text("\(viewModel.selectedNotebookIds.count) selected")
                .font(.inkHeadline)
                .foregroundColor(.inkTextPrimary)

            Spacer()

            Button("Move to…") { showMoveSheet = true }
                .font(.inkBody)
                .foregroundColor(.inkAccentPrimary)
                .disabled(viewModel.selectedNotebookIds.isEmpty)

            Button("Delete") {
                withAnimation(.inkSpring(InkSpring.smooth)) {
                    viewModel.deleteSelectedNotebooks()
                }
            }
            .font(.inkBody)
            .foregroundColor(.inkDestructive)
            .disabled(viewModel.selectedNotebookIds.isEmpty)

            Button("Done") {
                withAnimation(.inkSpring(InkSpring.snappy)) {
                    viewModel.isSelecting = false
                    viewModel.selectedNotebookIds = []
                }
            }
            .font(.inkHeadline)
            .foregroundColor(.inkAccentPrimary)
        }
    }
}

// MARK: - Breadcrumb bar

/// Files-style path bar shown above the grid when the user is inside a
/// folder. Tap a segment to pop the path back to that level. The leading
/// "back" chevron pops one level — quicker than aiming for the parent
/// segment when the path is deep.
private struct BreadcrumbBar: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        HStack(spacing: Ink.Spacing.xs) {
            Button {
                withAnimation(.inkSpring(InkSpring.snappy)) {
                    viewModel.navigateUp()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.inkHeadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.inkAccentPrimary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.inkPressable)
            .accessibilityLabel("Back")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // Subject root crumb
                    Button {
                        withAnimation(.inkSpring(InkSpring.snappy)) {
                            viewModel.navigateToSubjectRoot()
                        }
                    } label: {
                        Text(viewModel.selectedSubjectName)
                            .font(.inkSubhead)
                            .foregroundColor(.inkAccentPrimary)
                    }
                    .buttonStyle(.inkPressable)

                    // Folder segments
                    ForEach(Array(viewModel.folderPath.enumerated()), id: \.element.id) { idx, folder in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.inkTextTertiary)

                        if idx == viewModel.folderPath.count - 1 {
                            // Leaf — non-tappable, primary text
                            Text(folder.name)
                                .font(.inkSubhead)
                                .fontWeight(.semibold)
                                .foregroundColor(.inkTextPrimary)
                        } else {
                            Button {
                                withAnimation(.inkSpring(InkSpring.snappy)) {
                                    viewModel.navigateToBreadcrumb(index: idx)
                                }
                            } label: {
                                Text(folder.name)
                                    .font(.inkSubhead)
                                    .foregroundColor(.inkAccentPrimary)
                            }
                            .buttonStyle(.inkPressable)
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

// MARK: - Pinned notebooks strip

private struct PinnedNotebooksStrip: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            Text("Pinned")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
                .padding(.leading, 24)
                .padding(.top, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.pinnedNotebooks) { notebook in
                        NotebookCardView(notebook: notebook, viewModel: viewModel)
                            .frame(width: 140, height: 168)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            InkDivider()
                .padding(.horizontal, 24)
        }
    }
}

// MARK: - Move notebooks sheet (multi-select)

private struct MoveNotebooksSheet: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button("Uncategorised") {
                    viewModel.moveNotebooks(ids: viewModel.selectedNotebookIds, to: nil)
                    dismiss()
                }
                .foregroundColor(.inkTextPrimary)

                ForEach(viewModel.subjects) { subject in
                    Button {
                        viewModel.moveNotebooks(ids: viewModel.selectedNotebookIds, to: subject.id)
                        dismiss()
                    } label: {
                        Label {
                            Text(subject.name).foregroundColor(.inkTextPrimary)
                        } icon: {
                            Circle()
                                .fill(Color(UIColor(hex: subject.colorHex)))
                                .frame(width: 12, height: 12)
                        }
                    }
                }
            }
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
