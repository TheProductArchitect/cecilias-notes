import SwiftData
import SwiftUI

/// File-system style list of every Quiz, grouped by folder. Mounted
/// by `LibraryView` when `selectedContext == .allQuizzes`. Same
/// pattern as `AllSubjectsView`: the top-bar select chip drives
/// `viewModel.isSelecting`, rows reflect `selectedQuizIds`, and
/// batch delete fires through the view model so questions +
/// attempt history cascade. Tap-without-select opens the quiz.
struct AllQuizzesView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.theme) private var theme

    @Query(
        filter: #Predicate<Quiz> { $0.isArchived == false },
        sort: \Quiz.createdAt,
        order: .reverse
    )
    private var quizzes: [Quiz]

    private var grouped: [(folder: String, quizzes: [Quiz])] {
        let dict = Dictionary(grouping: quizzes) { quiz -> String in
            quiz.folderName.trimmingCharacters(in: .whitespaces)
        }
        let folders = dict.keys.filter { !$0.isEmpty }.sorted { $0.lowercased() < $1.lowercased() }
        var out: [(folder: String, quizzes: [Quiz])] = []
        if let unfiled = dict[""], !unfiled.isEmpty {
            out.append((folder: "", quizzes: unfiled))
        }
        for folder in folders {
            out.append((folder: folder, quizzes: dict[folder] ?? []))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if quizzes.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(theme.surface.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("all quizzes")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Text("\(quizzes.count)")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(theme.recessiveTertiary)
            Spacer(minLength: 0)
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

    /// File-system style folder grid. Each quiz is a `QuizFolderCardView`
    /// tile — same visual rhythm as the All Subjects grid so the user
    /// reads them as siblings. Replaces the prior LazyVStack-of-rows
    /// surface (2026-06-22 redesign per user request).
    ///
    /// Folder groupings (`quiz.folderName`) are surfaced as section
    /// headers above each group so the existing organisational signal
    /// survives the migration.
    private var list: some View {
        ScrollView {
            LazyVGrid(
                columns: columns,
                spacing: 16,
                pinnedViews: []
            ) {
                ForEach(grouped, id: \.folder) { group in
                    Section {
                        ForEach(group.quizzes, id: \.id) { quiz in
                            QuizFolderCardView(quiz: quiz, viewModel: viewModel)
                                .frame(maxWidth: .infinity)
                                .frame(width: cardWidth, height: 200)
                        }
                    } header: {
                        if !group.folder.isEmpty {
                            folderHeader(group.folder)
                        } else if grouped.contains(where: { !$0.folder.isEmpty }) {
                            folderHeader("ungrouped")
                        }
                    }
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: quizzes.map(\.id))
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

    private func folderHeader(_ name: String) -> some View {
        Text(name.lowercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.05)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.recessiveQuaternary)
            Text("no quizzes yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.foregroundMuted)
            Text("generate a quiz from any notebook's three-dot menu to populate this list.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(theme.recessiveTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
