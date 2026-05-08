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
                gridArea
            }
        }
        .background(Color.inkBackgroundPrimary)
        .animation(.inkSpring(InkSpring.smooth), value: viewModel.isSearchActive)
        .animation(.inkSpring(InkSpring.smooth), value: viewModel.isSelecting)
    }

    // MARK: Grid

    @ViewBuilder
    private var gridArea: some View {
        if viewModel.notebooks.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Pinned strip
                    if !viewModel.pinnedNotebooks.isEmpty {
                        PinnedNotebooksStrip(viewModel: viewModel)
                    }

                    // Main grid
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.notebooks) { notebook in
                            NotebookCardView(notebook: notebook, viewModel: viewModel)
                                .frame(width: 168, height: 200)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                                // Drag to reorder (manual sort only)
                                .draggable(
                                    (try? JSONEncoder().encode(NotebookTransferID(id: notebook.id)))
                                        ?? Data()
                                ) {
                                    // Preview closure runs when the drag actually
                                    // starts — fire the start haptic here.
                                    NotebookCardView(notebook: notebook, viewModel: viewModel)
                                        .frame(width: 168, height: 200)
                                        .opacity(0.6)
                                        .onAppear { HapticManager.shared.dragReorderStarted() }
                                }
                        }
                    }
                    .padding(24)
                    .animation(.inkSpring(InkSpring.smooth), value: viewModel.notebooks.map(\.id))
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
        if let subjectId = viewModel.selectedSubjectId,
           let subject = viewModel.subjects.first(where: { $0.id == subjectId }) {
            // Subject-specific empty
            VStack(spacing: Ink.Spacing.md) {
                InkEmptyState(
                    icon: "tray",
                    title: "Nothing in \(subject.name)",
                    subtitle: "Create a notebook or move one here."
                )
                HStack(spacing: Ink.Spacing.sm) {
                    InkButton("New Notebook", style: .primary) {
                        viewModel.createUntitledNotebookAndOpen()
                    }
                    InkButton("Move Notebooks", style: .secondary) {
                        viewModel.selectedSubjectId = nil
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Global empty
            InkEmptyState(
                icon: "book.closed",
                title: "No notebooks yet",
                subtitle: "Start writing.",
                action: (label: "New Notebook", handler: { viewModel.createUntitledNotebookAndOpen() })
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
            Text(viewModel.selectedSubjectName)
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

            // New Notebook
            Button {
                viewModel.createUntitledNotebookAndOpen()
            } label: {
                Label("New Notebook", systemImage: "plus")
                    .font(.inkHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, Ink.Spacing.md)
                    .frame(height: 36)
                    .background(Color.inkAccentPrimary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.inkPressable)
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
