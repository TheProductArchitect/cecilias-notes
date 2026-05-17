import SwiftUI
import UniformTypeIdentifiers

/// Editorial masthead for the Library home screen.
///
/// Three-zone composition inside a 180pt-tall band capped by a
/// full-width 1.5pt black rule:
///
///   • Left  — DateEyebrow + BrandWordmark, bottom-anchored to the rule
///   • Top right — greeting (top-anchored, hidden when name > 8 chars
///     or no name set)
///   • Bottom right — toolbar strip (search / filter / + / select)
///     OR selecting-mode toolbar (count / move / delete / done)
///
/// The toolbar strip lives in the masthead now (not above the grid) —
/// the rule becomes the strict boundary between "identity + tools"
/// and "content."
struct LibraryHeaderView: View {

    @ObservedObject var viewModel: LibraryViewModel
    @AppStorage(PersonalIdentity.nameKey) private var userName: String = ""

    @State private var greeting: String = ""
    @State private var showMoveSheet = false
    @State private var isShowingPDFImporter = false
    @State private var isShowingTagFilter = false
    @State private var isShowingAskSheet = false
    @StateObject private var intelligence = IntelligenceService.shared

    /// Greeting only renders when the user has set a name AND that name
    /// is short enough not to need the right zone for breathing room.
    private var shouldShowGreeting: Bool {
        let normal = NameFormatter.normalised(userName)
        return !normal.isEmpty && normal.count <= 8
    }

    private var ghostCharacter: Character {
        let normal = NameFormatter.normalised(userName)
        return (normal.isEmpty ? "cecilia" : normal).first ?? "c"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Ghost letter behind both zones — bleeds bottom-right.
            GhostLetter(
                character: ghostCharacter,
                size: 160,
                onDarkBackground: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: 24, y: 24)
            .clipped()
            .accessibilityHidden(true)

            HStack(alignment: .bottom, spacing: 0) {
                leftZone
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 16)

                rightColumn
                    .frame(maxWidth: 320, maxHeight: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.inkTextPrimary)
                .frame(height: 1.5)
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showMoveSheet) {
            MoveNotebooksSheet(viewModel: viewModel)
        }
        .fileImporter(
            isPresented: $isShowingPDFImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { await viewModel.importPDFs(at: urls) }
        }
        .sheet(isPresented: $isShowingTagFilter) {
            TagFilterSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingAskSheet) {
            AskMyNotesView(libraryViewModel: viewModel)
        }
        .animation(.inkSpring(InkSpring.smooth), value: viewModel.isSelecting)
        .onAppear { greeting = GreetingPicker.pick() }
    }

    // MARK: Left zone

    private var leftZone: some View {
        VStack(alignment: .leading, spacing: 4) {
            DateEyebrow()
            BrandWordmark(userName: userName)
        }
    }

    // MARK: Right column — greeting (top) + toolbar strip (bottom)

    private var rightColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if shouldShowGreeting {
                greetingCard
            }
            Spacer(minLength: 0)
            toolbarStrip
        }
    }

    private var greetingCard: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Rectangle()
                .fill(Color.inkRecessiveQuinary)
                .frame(height: 0.5)
                .frame(maxWidth: 80)

            Text(greeting)
                .font(.system(size: 10, weight: .regular).italic())
                .foregroundStyle(Color.inkRecessiveSecondary)
                .multilineTextAlignment(.trailing)
                // Up to 4 lines (~56pt at 14pt line height) so longer
                // greetings wrap into the empty vertical space below
                // the eyebrow rather than being tail-truncated. Past
                // 4 lines the fix is to edit the greeting, not raise
                // the limit further.
                .lineLimit(4)
                .truncationMode(.tail)
                // Force the text to its intrinsic vertical height so a
                // wrapped greeting isn't clipped by the parent's frame.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(greeting.isEmpty ? 0 : 1)
        }
        .frame(maxWidth: 100, alignment: .trailing)
    }

    // MARK: Toolbar strip

    @ViewBuilder
    private var toolbarStrip: some View {
        if viewModel.isSelecting {
            selectingStrip
        } else {
            normalStrip
        }
    }

    private var normalStrip: some View {
        HStack(spacing: 4) {
            // Search
            Button {
                withAnimation(.inkSpring(InkSpring.smooth)) {
                    viewModel.isSearchActive.toggle()
                    if !viewModel.isSearchActive { viewModel.deactivateSearch() }
                }
            } label: {
                Image(systemName: viewModel.isSearchActive ? "xmark" : "magnifyingglass")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.inkRecessiveQuaternary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.inkPressable)
            .keyboardShortcut("f", modifiers: .command)

            // Sort (existing)
            Menu {
                ForEach(NotebookSortOrder.allCases) { order in
                    Button {
                        viewModel.sortOrder = order
                    } label: {
                        Label(order.rawValue, systemImage: order.symbolName)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(
                        viewModel.sortOrder == .manual
                            ? Color.brandAccent
                            : Color.inkRecessiveQuaternary
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Sort")

            // Ask My Notes — conversational on-device search.
            // Surfaces only when Apple Intelligence is available
            // AND the user hasn't disabled it in Settings. Graceful
            // absence — no disabled state, no upgrade prompt.
            if intelligence.canRun {
                Button {
                    isShowingAskSheet = true
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.inkRecessiveQuaternary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.inkPressable)
                .accessibilityLabel("Ask your notes")
            }

            // Tag filter — opens a half-sheet of every unique tag
            // in the current context. The icon turns brand-blue when
            // a filter is active so the chrome surfaces the
            // currently-applied filter without an extra label.
            Button {
                isShowingTagFilter = true
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(
                        viewModel.isTagFilterActive
                            ? Color.brandAccent
                            : Color.inkRecessiveQuaternary
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.inkPressable)
            .accessibilityLabel("Filter by tag")

            // "+" — single tap goes straight to notebook creation in
            // the active subject (or the inferred subject for
            // `.allNotes` / `.recent`). Folder + subject creation moved
            // to a long-press context menu so the primary action stays
            // one-tap; the customise panel still opens for the new
            // notebook so the user can rename / pick a template before
            // committing to the editor.
            Button {
                #if DEBUG
                print("[Library] toolbar + tapped, opening notebook creation flow")
                #endif
                viewModel.createNotebookWithFallback()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.inkRecessiveQuaternary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.inkPressable)
            .accessibilityLabel("New notebook")
            .disabled(!viewModel.canCreateNotebook)
            .contextMenu {
                Button {
                    viewModel.createNotebookWithFallback()
                } label: {
                    Label("New Notebook", systemImage: "doc")
                }
                .disabled(!viewModel.canCreateNotebook)

                Button {
                    viewModel.createFolderAtCurrentLevel()
                } label: {
                    Label("New Folder", systemImage: "folder")
                }
                .disabled(!viewModel.canCreateFolder)

                Divider()

                Button {
                    viewModel.createSubject()
                } label: {
                    Label("New Subject", systemImage: "square.stack")
                }
            }

            // Open PDF — multi-select supported. Each picked PDF
            // becomes its own notebook in the current subject; the
            // editor renders each PDF page as a page background that
            // the user can draw on, and export preserves strokes as
            // annotations on the original PDF.
            Button {
                isShowingPDFImporter = true
            } label: {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.inkRecessiveQuaternary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.inkPressable)
            .accessibilityLabel("Open PDF")

            // Select — icon-only to fit the toolbar strip without
            // wrapping (the text form was overflowing into a second
            // line after the filter / image / PDF icons landed
            // alongside). `checkmark.circle.fill` + brand accent
            // signals "active" when the grid is in select mode;
            // recessive ring otherwise. Matches the icon-only
            // pattern of every other button in this strip.
            Button {
                withAnimation(.inkSpring(InkSpring.snappy)) {
                    viewModel.isSelecting.toggle()
                }
            } label: {
                Image(systemName: viewModel.isSelecting
                      ? "checkmark.circle.fill"
                      : "checkmark.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(viewModel.isSelecting
                                     ? Color.brandAccent
                                     : Color.inkRecessiveQuaternary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.inkPressable)
            .accessibilityLabel(viewModel.isSelecting ? "Exit select" : "Select")
        }
    }

    private var selectingStrip: some View {
        // Drives the select-all / deselect-all toggle. "All visible" means
        // every notebook in `viewModel.notebooks` — that array is already
        // filtered by the active sidebar context (subject / all-notes /
        // recent) and tag filter, so this naturally respects whatever
        // narrowing the user has applied.
        let visibleIds = Set(viewModel.notebooks.map(\.id))
        let allVisibleSelected = !visibleIds.isEmpty
            && visibleIds.isSubset(of: viewModel.selectedNotebookIds)
        return HStack(spacing: 8) {
            Text("\(viewModel.selectedNotebookIds.count) selected")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.inkRecessivePrimary)

            Button(allVisibleSelected ? "deselect all" : "select all") {
                if allVisibleSelected {
                    viewModel.selectedNotebookIds.subtract(visibleIds)
                } else {
                    viewModel.selectedNotebookIds.formUnion(visibleIds)
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Color.brandAccent)
            .disabled(visibleIds.isEmpty)

            Spacer(minLength: 8)

            Button("move to…") { showMoveSheet = true }
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.brandAccent)
                .disabled(viewModel.selectedNotebookIds.isEmpty)

            Button("delete") {
                withAnimation(.inkSpring(InkSpring.smooth)) {
                    viewModel.deleteSelectedNotebooks()
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Color.inkDestructive)
            .disabled(viewModel.selectedNotebookIds.isEmpty)

            Button("done") {
                withAnimation(.inkSpring(InkSpring.snappy)) {
                    viewModel.isSelecting = false
                    viewModel.selectedNotebookIds = []
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.brandAccent)
        }
        .frame(height: 44)
    }
}

// `LibrarySectionHeader` and `RecentlyOpenedStrip` were removed when
// the grid moved to single-context rendering — the sidebar's active
// row now signals which subset of notebooks the grid is showing, so
// the inline "📌 pinned" / "🕐 recently opened" / "📚 all notebooks"
// labels became redundant.
