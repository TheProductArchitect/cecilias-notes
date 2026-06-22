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
    @Environment(\.theme) private var theme

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

    /// Compact form factor (iPhone) drops the masthead from 180pt to
    /// 96pt, hides the bottom-right ghost letter (no room), drops
    /// the date eyebrow (also no room), and stacks the right-zone
    /// toolbar above the wordmark instead of beside it. Net: the
    /// library home shows ~6 notebook rows above the fold on a
    /// standard iPhone screen instead of ~2.
    private var isCompact: Bool { DeviceCapabilities.isPhoneIdiom }
    private var bandHeight: CGFloat { isCompact ? 96 : 180 }


    var body: some View {
        ZStack(alignment: .bottom) {
            // Ghost letter — iPad only. On iPhone the band is too
            // short for the 160pt glyph to read as anything but
            // visual noise.
            if !isCompact {
                GhostLetter(
                    character: ghostCharacter,
                    size: 160,
                    onDarkBackground: false
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 24, y: 24)
                .clipped()
                .accessibilityHidden(true)
            }

            // iPhone stacks the wordmark above the toolbar strip
            // — they don't fit side-by-side on a 393pt screen
            // (wordmark ~190pt + 7-icon toolbar ~252pt = 442pt > 393pt),
            // which is what was pushing the wordmark off the left
            // edge under every previous attempt. iPad keeps the
            // side-by-side composition.
            Group {
                if isCompact {
                    VStack(alignment: .leading, spacing: 6) {
                        leftZone
                        toolbarStrip
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 0) {
                        leftZone
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 16)

                        rightColumn
                            .frame(maxWidth: 320, maxHeight: .infinity, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, isCompact ? 16 : 24)
            .padding(.top, isCompact ? 8 : 16)
        }
        .frame(height: bandHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.foreground)
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
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: viewModel.isSelecting)
        .onAppear { greeting = GreetingPicker.pick() }
    }

    // MARK: Left zone

    private var leftZone: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Date eyebrow drops on iPhone — the band is too short
            // for the date + wordmark stack to read cleanly, and
            // the iOS status bar already shows the date.
            if !isCompact {
                DateEyebrow()
            }
            BrandWordmark(userName: userName, compact: isCompact)
        }
    }

    // MARK: Right column — greeting (top) + toolbar strip (bottom)

    private var rightColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // Greeting card is iPad-only: it requires the 180pt
            // band to sit above the toolbar without crowding it.
            if shouldShowGreeting && !isCompact {
                greetingCard
            }
            Spacer(minLength: 0)
            toolbarStrip
        }
    }

    private var greetingCard: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Rectangle()
                .fill(theme.recessiveQuinary)
                .frame(height: 0.5)
                .frame(maxWidth: 80)

            Text(greeting)
                .font(.system(size: 10, weight: .regular).italic())
                .foregroundStyle(theme.recessiveSecondary)
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
            // Step 10: sync state badge — leftmost in the strip so
            // it sits at the natural reading-order start without
            // displacing the existing actions. Read-only surface
            // backed by `CloudSyncManager`; tap opens a small menu
            // (last-synced timestamp / retry on error / etc.).
            SyncStatusIndicator()

            // Search
            Button {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                    viewModel.isSearchActive.toggle()
                    if !viewModel.isSearchActive { viewModel.deactivateSearch() }
                }
            } label: {
                Image(systemName: viewModel.isSearchActive ? "xmark" : "magnifyingglass")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(theme.recessiveQuaternary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.ceciliasNotesPressable)
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
                            ? theme.accent
                            : theme.recessiveQuaternary
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
                        .foregroundStyle(theme.recessiveQuaternary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.ceciliasNotesPressable)
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
                            ? theme.accent
                            : theme.recessiveQuaternary
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.ceciliasNotesPressable)
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
                dlog("[Library] toolbar + tapped, opening notebook creation flow")
                #endif
                viewModel.createNotebookWithFallback()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(theme.recessiveQuaternary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.ceciliasNotesPressable)
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
                    .foregroundStyle(theme.recessiveQuaternary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.ceciliasNotesPressable)
            .accessibilityLabel("Open PDF")

            // Select — icon-only to fit the toolbar strip without
            // wrapping (the text form was overflowing into a second
            // line after the filter / image / PDF icons landed
            // alongside). `checkmark.circle.fill` + brand accent
            // signals "active" when the grid is in select mode;
            // recessive ring otherwise. Matches the icon-only
            // pattern of every other button in this strip.
            Button {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                    viewModel.isSelecting.toggle()
                }
            } label: {
                Image(systemName: viewModel.isSelecting
                      ? "checkmark.circle.fill"
                      : "checkmark.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(viewModel.isSelecting
                                     ? theme.accent
                                     : theme.recessiveQuaternary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.ceciliasNotesPressable)
            .accessibilityLabel(viewModel.isSelecting ? "Exit select" : "Select")
        }
    }

    private var selectingStrip: some View {
        // Pivots its actions on the active library context. In
        // `.allSubjects` it operates on subjects, in `.allQuizzes`
        // on quizzes, otherwise on notebooks (the historical
        // behaviour). One bar, three pools — keeps the user's
        // muscle memory consistent (tap the top-right select chip,
        // tap rows, tap delete) regardless of which file-system
        // style surface they're in.
        switch viewModel.selectedContext {
        case .allSubjects: return AnyView(subjectsSelectingStrip)
        case .allQuizzes:  return AnyView(quizzesSelectingStrip)
        default:           return AnyView(notebooksSelectingStrip)
        }
    }

    private var notebooksSelectingStrip: some View {
        let visibleIds = Set(viewModel.notebooks.map(\.id))
        let allVisibleSelected = !visibleIds.isEmpty
            && visibleIds.isSubset(of: viewModel.selectedNotebookIds)
        return HStack(spacing: 8) {
            Text("\(viewModel.selectedNotebookIds.count) selected")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.recessivePrimary)

            Button(allVisibleSelected ? "deselect all" : "select all") {
                if allVisibleSelected {
                    viewModel.selectedNotebookIds.subtract(visibleIds)
                } else {
                    viewModel.selectedNotebookIds.formUnion(visibleIds)
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(theme.accent)
            .disabled(visibleIds.isEmpty)

            Spacer(minLength: 8)

            Button("move to…") { showMoveSheet = true }
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(theme.accent)
                .disabled(viewModel.selectedNotebookIds.isEmpty)

            Button("delete") {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                    viewModel.deleteSelectedNotebooks()
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(theme.danger)
            .disabled(viewModel.selectedNotebookIds.isEmpty)

            Button("done") {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                    viewModel.isSelecting = false
                    viewModel.selectedNotebookIds = []
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.accent)
        }
        .frame(height: 44)
    }

    private var subjectsSelectingStrip: some View {
        let visibleIds = Set(viewModel.subjects.map(\.id))
        let allVisibleSelected = !visibleIds.isEmpty
            && visibleIds.isSubset(of: viewModel.selectedSubjectIds)
        return HStack(spacing: 8) {
            Text("\(viewModel.selectedSubjectIds.count) selected")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.recessivePrimary)

            Button(allVisibleSelected ? "deselect all" : "select all") {
                if allVisibleSelected {
                    viewModel.selectedSubjectIds.subtract(visibleIds)
                } else {
                    viewModel.selectedSubjectIds.formUnion(visibleIds)
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(theme.accent)
            .disabled(visibleIds.isEmpty)

            Spacer(minLength: 8)

            Button("delete") {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                    viewModel.deleteSelectedSubjects()
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(theme.danger)
            .disabled(viewModel.selectedSubjectIds.isEmpty)

            Button("done") {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                    viewModel.isSelecting = false
                    viewModel.selectedSubjectIds = []
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.accent)
        }
        .frame(height: 44)
    }

    private var quizzesSelectingStrip: some View {
        return HStack(spacing: 8) {
            Text("\(viewModel.selectedQuizIds.count) selected")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.recessivePrimary)

            Spacer(minLength: 8)

            Button("delete") {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                    viewModel.deleteSelectedQuizzes()
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(theme.danger)
            .disabled(viewModel.selectedQuizIds.isEmpty)

            Button("done") {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                    viewModel.isSelecting = false
                    viewModel.selectedQuizIds = []
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.accent)
        }
        .frame(height: 44)
    }
}

// `LibrarySectionHeader` and `RecentlyOpenedStrip` were removed when
// the grid moved to single-context rendering — the sidebar's active
// row now signals which subset of notebooks the grid is showing, so
// the inline "📌 pinned" / "🕐 recently opened" / "📚 all notebooks"
// labels became redundant.
