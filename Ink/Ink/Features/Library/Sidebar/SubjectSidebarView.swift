import SwiftUI
import SwiftData

/// Recessive 118pt-wide sidebar. No header, no logo, no panel tint —
/// it sits beside the masthead and recedes until the user reaches for
/// it. Three sections (subjects, pinned, recent), then a bottom bar
/// with "+ new subject" and the iCloud status indicator.
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

    private static let horizontalInset: CGFloat = 13

    /// Subject-count colour — #aaa light / dim dark equivalent. Slightly
    /// darker than the all-purpose `inkRecessiveQuinary` (which has to
    /// stay light enough for sidebar dividers).
    private static let countColor = Color(
        light: Color(hex: "#aaaaaa"),
        dark:  Color(hex: "#5e5e5c")
    )

    /// "nothing yet" empty-state colour — #bbb light. Sits between
    /// counts and dividers in the recessive ramp.
    private static let emptyStateColor = Color(
        light: Color(hex: "#bbbbbb"),
        dark:  Color(hex: "#555553")
    )

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    subjectsSection
                    sectionDivider
                    pinnedSection
                    sectionDivider
                    recentContextRow
                }
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            bottomBar
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.inkRecessiveQuinary)
                .frame(width: 0.5)
                .ignoresSafeArea()
        }
    }

    // MARK: Subjects

    private var subjectsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("subjects")
            // "All Notes" — kept as the first row so the cross-subject
            // view stays reachable. Italicised so it reads as a meta
            // entry rather than a real subject.
            allNotesRow
            ForEach(viewModel.subjects) { subject in
                subjectRow(for: subject)
            }
        }
    }

    private var allNotesRow: some View {
        AllNotesListRow(
            viewModel: viewModel,
            countColor: Self.countColor
        )
    }

    private func subjectRow(for subject: Subject) -> some View {
        SubjectListRow(
            subject: subject,
            viewModel: viewModel,
            countColor: Self.countColor
        )
    }

    // MARK: Pinned

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("pinned")
            if viewModel.pinnedNotebooks.isEmpty {
                Text("nothing yet")
                    .font(.system(size: 10, weight: .regular).italic())
                    .foregroundStyle(Self.emptyStateColor)
                    .padding(.horizontal, Self.horizontalInset)
                    .padding(.vertical, 4)
            } else {
                ForEach(viewModel.pinnedNotebooks.prefix(4)) { notebook in
                    pinnedRow(for: notebook)
                }
            }
        }
    }

    private func pinnedRow(for notebook: Notebook) -> some View {
        let subjectName = subjectName(for: notebook.subjectId)
        return Button {
            viewModel.selectedNotebookId = notebook.id
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(notebook.title.lowercased())
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Color.inkRecessivePrimary)
                    .lineLimit(1)
                if !subjectName.isEmpty {
                    Text(subjectName.lowercased())
                        .font(.system(size: 8.5, weight: .regular).italic())
                        .foregroundStyle(Color.inkRecessiveQuinary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.horizontalInset)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
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
                    .foregroundStyle(isSelected ? Color.inkNearBlack : Color.inkRecessivePrimary)
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
                        .foregroundStyle(Color.brandAccent)
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
                    .foregroundStyle(Color.brandAccent)
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
            .fill(Color.inkRecessiveQuinary)
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
            .foregroundStyle(Color.inkRecessiveQuaternary)
            .padding(.horizontal, Self.horizontalInset)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.inkRecessiveQuinary)
            .frame(height: 0.5)
            .opacity(0.4)
            .padding(.horizontal, Self.horizontalInset)
            .padding(.vertical, 12)
    }

    private func subjectName(for id: UUID?) -> String {
        guard let id else { return "" }
        return viewModel.subjects.first { $0.id == id }?.name ?? ""
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

    var body: some View {
        content()
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(Color.inkNearBlack)
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
                    .foregroundStyle(isSelected ? Color.inkNearBlack : Color.inkRecessivePrimary)
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

    @Query private var notebooks: [Notebook]

    init(subject: Subject, viewModel: LibraryViewModel, countColor: Color) {
        self.subject     = subject
        self.viewModel   = viewModel
        self.countColor  = countColor

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

    var body: some View {
        SidebarRow(
            isSelected: isSelected,
            onTap: { viewModel.selectedContext = .subject(subject.id) }
        ) {
            HStack(spacing: 0) {
                Text(subject.name.lowercased())
                    .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.inkNearBlack : Color.inkRecessivePrimary)
                    .lineLimit(1)
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
                    viewModel.moveNotebook(id: decoded.id, to: subject.id)
                    landed = true
                }
            }
            if landed { HapticManager.shared.dragReorderDropped() }
            return true
        }
        .contextMenu {
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
}

// MARK: - iCloud status indicator

struct iCloudStatusView: View {
    let syncStatus: CloudSyncManager.SyncStatus

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 11))
            .fontWeight(.regular)
            .foregroundStyle(symbolColor)
            .symbolEffect(.pulse, isActive: isPulsing)
            .inkAnimation(InkSpring.smooth, value: symbolName)
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
            return Color.inkRecessiveTertiary
        case .checking, .syncing:
            return Color.brandAccent
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
