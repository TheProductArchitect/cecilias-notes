import SwiftUI
import SwiftData

/// The sidebar "quizzes" section — section label + one row per quiz +
/// empty state. Sits below Recent (above the bottom bar's "+ new quiz"
/// / "+ new subject"). Styling matches the subjects/recent rows exactly:
/// 11pt recessive-primary text, promoted to bold near-black with a 2pt
/// leading rule when active.
struct QuizListView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject private var generation = QuizGenerationService.shared
    @Environment(\.theme) private var theme

    private static let horizontalInset: CGFloat = 13

    @Query(
        filter: #Predicate<Quiz> { $0.isArchived == false },
        sort: \Quiz.createdAt, order: .reverse
    )
    private var quizzes: [Quiz]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("quizzes")
            if quizzes.isEmpty {
                Text("nothing yet")
                    .font(.system(size: 10, weight: .regular).italic())
                    .foregroundStyle(theme.recessiveQuinary)
                    .padding(.horizontal, Self.horizontalInset)
                    .padding(.vertical, 6)
            } else {
                ForEach(quizzes) { quiz in
                    QuizSidebarRow(
                        quiz: quiz,
                        viewModel: viewModel,
                        isGenerating: generation.generatingQuizIDs.contains(quiz.id)
                    )
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7.5, weight: .regular))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
            .padding(.horizontal, Self.horizontalInset)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Quiz row

private struct QuizSidebarRow: View {
    let quiz: Quiz
    @ObservedObject var viewModel: LibraryViewModel
    let isGenerating: Bool
    @Environment(\.theme) private var theme

    private var isSelected: Bool { viewModel.selectedQuizID == quiz.id }
    @State private var confirmDelete = false

    /// Best completed-attempt score as 0–1, or nil if never attempted.
    private var bestScore: Double? {
        (quiz.attempts ?? []).compactMap(\.score).max()
    }

    /// AI added questions since the most recent attempt.
    private var hasNewQuestions: Bool {
        guard let updated = quiz.lastAutoUpdateAt else { return false }
        let lastAttempt = (quiz.attempts ?? []).map(\.startedAt).max()
        guard let lastAttempt else { return true }   // grew but never attempted
        return updated > lastAttempt
    }

    var body: some View {
        Button {
            viewModel.selectedQuizID = quiz.id
        } label: {
            HStack(spacing: 6) {
                Text(quiz.title.isEmpty ? "untitled quiz" : quiz.title.lowercased())
                    .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? theme.foreground : theme.recessivePrimary)
                    .lineLimit(1)

                if let bestScore {
                    scorePill(bestScore)
                }
                if hasNewQuestions {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 5, height: 5)
                }

                Spacer(minLength: 0)

                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(theme.accent)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(theme.foreground)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("delete this quiz?", isPresented: $confirmDelete) {
            Button("delete", role: .destructive) { delete() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("\(quiz.title.isEmpty ? "this quiz" : quiz.title) and its questions and attempt history will be removed. this can't be undone.")
        }
    }

    private func delete() {
        // Clear the selection if it points at this quiz so the detail
        // pane doesn't try to render a deleted row.
        if viewModel.selectedQuizID == quiz.id {
            viewModel.selectedQuizID = nil
        }
        let ctx = StorageService.shared.context
        ctx.delete(quiz)   // cascades to questions, attempts, responses
        try? ctx.save()
        HapticManager.shared.destructiveConfirmed()
    }

    @ViewBuilder
    private func scorePill(_ score: Double) -> some View {
        let pct = Int((score * 100).rounded())
        let (bg, fg): (Color, Color) = {
            switch score {
            case 0.8...:    return (theme.accent.opacity(0.14), theme.accent)
            case 0.5..<0.8: return (theme.recessiveQuinary.opacity(0.5), theme.foregroundMuted)
            default:        return (theme.danger.opacity(0.12), theme.danger)
            }
        }()
        Text("\(pct)%")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(bg)
            )
    }
}
