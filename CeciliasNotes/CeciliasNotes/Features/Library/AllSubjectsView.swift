import SwiftData
import SwiftUI

/// File-system style list of every Subject. Mounted by `LibraryView`
/// when `selectedContext == .allSubjects`. Selection is driven by
/// the top-bar select chip (the same one the notebook grid uses) —
/// the user taps it once and the rows pick up checkbox affordances.
/// Batch delete fires through `viewModel.deleteSelectedSubjects`
/// which cascades into nested notebooks. Tap-without-select jumps
/// into the subject.
struct AllSubjectsView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.theme) private var theme

    // Filter at the @Query level so SwiftData's change-set delivery
    // republishes the moment `isDeleted` flips — a post-fetch Swift
    // filter only catches the row leaving the result set (i.e. a
    // hard delete or insert), not a property mutation on an existing
    // row, which leaves soft-deleted subjects visible in the grid
    // until something else triggers a body re-evaluation. Belt: the
    // `active` filter below still hides any row that slips through
    // (e.g. CloudKit echo importing a non-deleted shadow before
    // SwiftData notices). `deletedAt != nil` is a second-axis check
    // because CloudKit conflict resolution has been observed to
    // revive `isDeleted = false` while leaving `deletedAt` stamped
    // — either flag is enough to consider the row gone.
    @Query(
        filter: #Predicate<Subject> { $0.isDeleted == false },
        sort: [SortDescriptor(\Subject.sortOrder)]
    )
    private var subjects: [Subject]

    private var active: [Subject] {
        subjects.filter { !$0.isDeleted && $0.deletedAt == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if active.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(theme.surface.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("all subjects")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Text("\(active.count)")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(theme.recessiveTertiary)
            Spacer(minLength: 0)
            // Select / actions live on the top-bar strip (see
            // LibraryHeaderView). Mentioning it inline keeps the
            // affordance discoverable for users who land on this
            // screen and don't realise the top bar applies here too.
            if !viewModel.isSelecting {
                Text("use “select” in the top bar to delete in batches")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.recessiveTertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.recessiveQuinary).frame(height: 0.5)
        }
    }

    /// File-system style folder grid. Each subject is a `SubjectFolderCardView`
    /// tile — folder glyph, name, notebook count, and a small stack of
    /// the subject's first few notebook covers fanned out behind the
    /// glyph. Drops the list-row form (replaced 2026-06-22 per user
    /// request for a "thumbnails / folders" surface that reads as
    /// siblings to the rest of the library grid).
    private var list: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(active.dedupedById(), id: \.id) { subject in
                    SubjectFolderCardView(subject: subject, viewModel: viewModel)
                        .frame(maxWidth: .infinity)
                        .frame(width: cardWidth, height: 200)
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: active.map(\.id))
        }
    }

    private var columns: [GridItem] {
        DeviceCapabilities.prefersTabletLayout
            ? [GridItem(.adaptive(minimum: 168), spacing: 16)]
            : [GridItem(.flexible(), spacing: 12)]
    }
    private var cardWidth: CGFloat? {
        DeviceCapabilities.prefersTabletLayout ? 168 : nil
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.recessiveQuaternary)
            Text("no subjects yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.foregroundMuted)
            Text("create a subject from the sidebar to group your notebooks.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(theme.recessiveTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
