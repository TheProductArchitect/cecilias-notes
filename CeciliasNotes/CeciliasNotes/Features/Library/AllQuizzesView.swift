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

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(grouped, id: \.folder) { group in
                    if !group.folder.isEmpty {
                        folderHeader(group.folder)
                    } else if grouped.contains(where: { !$0.folder.isEmpty }) {
                        folderHeader("ungrouped")
                    }
                    ForEach(group.quizzes, id: \.id) { quiz in
                        row(for: quiz)
                        Rectangle()
                            .fill(theme.recessiveQuinary)
                            .frame(height: 0.5)
                            .padding(.leading, 24)
                    }
                }
            }
        }
    }

    private func folderHeader(_ name: String) -> some View {
        Text(name.lowercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.05)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveTertiary)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for quiz: Quiz) -> some View {
        let isSelected = viewModel.selectedQuizIds.contains(quiz.id)
        return HStack(spacing: 12) {
            if viewModel.isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? theme.accent : theme.recessiveTertiary)
            }
            Image(systemName: "questionmark.app")
                .font(.system(size: 16))
                .foregroundStyle(theme.recessiveSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(quiz.title.isEmpty ? "untitled quiz" : quiz.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.foreground)
                Text(subtitleLabel(for: quiz))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.recessiveTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if viewModel.isSelecting {
                if isSelected { viewModel.selectedQuizIds.remove(quiz.id) }
                else          { viewModel.selectedQuizIds.insert(quiz.id) }
            } else {
                viewModel.selectedQuizID = quiz.id
            }
        }
    }

    private func subtitleLabel(for quiz: Quiz) -> String {
        let questionCount = (quiz.questions ?? []).count
        let attemptCount  = (quiz.attempts  ?? []).count
        let q = questionCount == 1 ? "1 question" : "\(questionCount) questions"
        let a = attemptCount == 0 ? "no attempts"
              : attemptCount == 1 ? "1 attempt"
              : "\(attemptCount) attempts"
        return "\(q) • \(a)"
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
