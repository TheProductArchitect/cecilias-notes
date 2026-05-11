import SwiftUI

struct NotebookGridView: View {
    @ObservedObject var viewModel: LibraryViewModel

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isSearchActive {
                searchArea
            } else {
                // Breadcrumb only shows when the user is *inside* a folder.
                if !viewModel.folderPath.isEmpty {
                    BreadcrumbBar(viewModel: viewModel)
                    InkDivider()
                }
                gridArea
            }
        }
        .background(Color(.systemBackground))
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
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(levelFolders) { folder in
                        FolderCardView(folder: folder, viewModel: viewModel)
                            .frame(width: 168, height: 200)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }

                    ForEach(levelNotebooks) { notebook in
                        NotebookCardView(notebook: notebook, viewModel: viewModel)
                            .frame(width: 168, height: 224)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                            .draggable(
                                (try? JSONEncoder().encode(NotebookTransferID(id: notebook.id)))
                                    ?? Data()
                            ) {
                                NotebookCardView(notebook: notebook, viewModel: viewModel)
                                    .frame(width: 168, height: 224)
                                    .opacity(0.6)
                                    .onAppear { HapticManager.shared.dragReorderStarted() }
                            }
                    }
                }
                // 24pt of breathing room between the masthead's bottom
                // rule and the first row of cards.
                .padding(.top, 24)
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .animation(.inkSpring(InkSpring.smooth), value: levelFolders.map(\.id))
                .animation(.inkSpring(InkSpring.smooth), value: levelNotebooks.map(\.id))
            }
            // Scrolling the grid dismisses any open inline-rename
            // keyboard immediately. Works for floating + docked
            // keyboards uniformly — `.scrollDismissesKeyboard` is
            // the SwiftUI-native path that doesn't conflict with
            // PencilKit or other gesture recognisers downstream.
            .scrollDismissesKeyboard(.immediately)
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

    /// Three-element minimal empty state per the redesign — a 28pt
    /// hairline rule, "nothing here yet.", "pick a subject, start
    /// something.". No icon, no illustration, no CTA. Used everywhere
    /// the grid would otherwise show an empty state (subject root,
    /// inside an empty folder, all notes).
    @ViewBuilder
    private var emptyState: some View {
        EditorialEmptyState(
            primary: "nothing here yet.",
            secondary: "pick a subject, start something."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchEmptyState: some View {
        EditorialEmptyState(
            primary: "nothing matches.",
            secondary: "try fewer words."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        VStack(spacing: 10) {
            Rectangle()
                .fill(Color.inkRecessiveQuinary)
                .frame(width: 28, height: 1)

            Text(primary)
                .font(.system(size: 11.5, weight: .regular).italic())
                .foregroundStyle(Color.inkRecessiveTertiary)

            Text(secondary)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.inkRecessiveQuinary)
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

// `PinnedNotebooksStrip` was removed when the grid moved to
// single-context rendering. Pinned notebooks live in the sidebar's
// PINNED section now.

// MARK: - Move notebooks sheet (multi-select)

struct MoveNotebooksSheet: View {
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
