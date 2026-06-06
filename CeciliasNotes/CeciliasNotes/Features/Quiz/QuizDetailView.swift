import SwiftUI
import SwiftData

/// Quiz overview shown in the library detail pane when a quiz is
/// selected in the sidebar. Title + source scope + stats, then the
/// question list for review. (The full-screen "take quiz" flow is the
/// next screen; the `start quiz` button is wired once `QuizTakingView`
/// lands.)
struct QuizDetailView: View {
    let quizID: UUID
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject private var generation = QuizGenerationService.shared
    @Environment(\.theme) private var theme

    @Query private var quizzes: [Quiz]

    init(quizID: UUID, viewModel: LibraryViewModel) {
        self.quizID = quizID
        self.viewModel = viewModel
        _quizzes = Query(filter: #Predicate<Quiz> { $0.id == quizID })
    }

    private var quiz: Quiz? { quizzes.first }
    private var isGenerating: Bool { generation.generatingQuizIDs.contains(quizID) }
    @State private var isTaking = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            if let quiz {
                VStack(alignment: .leading, spacing: 20) {
                    header(quiz)
                    HStack(spacing: 16) {
                        if !quiz.orderedQuestions.isEmpty && !isGenerating {
                            startButton
                        }
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text("delete quiz")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(theme.danger)
                        }
                        .buttonStyle(.plain)
                    }
                    Rectangle().fill(theme.recessiveQuinary).frame(height: 0.5)
                    content(quiz)
                }
                .padding(28)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("quiz not found")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.foregroundSubtle)
                    .padding(40)
            }
        }
        .background(theme.surface)
        .fullScreenCover(isPresented: $isTaking) {
            if let quiz {
                QuizTakingView(
                    quiz: quiz,
                    context: StorageService.shared.context,
                    onClose: { isTaking = false }
                )
            }
        }
        .alert("delete this quiz?", isPresented: $confirmDelete) {
            Button("delete", role: .destructive) { deleteQuiz() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("the quiz, its questions, and attempt history will be removed. this can't be undone.")
        }
    }

    private func deleteQuiz() {
        guard let quiz else { return }
        viewModel.selectedQuizID = nil
        let ctx = StorageService.shared.context
        ctx.delete(quiz)
        try? ctx.save()
        HapticManager.shared.destructiveConfirmed()
    }

    private var startButton: some View {
        Button { isTaking = true } label: {
            Text("start quiz →")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.accent)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Header

    private func header(_ quiz: Quiz) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(quiz.title.isEmpty ? "untitled quiz" : quiz.title)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(theme.foreground)

            Text(scopeLabel(quiz.sourceScope))
                .font(.system(size: 9, weight: .regular))
                .tracking(0.08)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveQuaternary)

            Text(statsLine(quiz))
                .font(.system(size: 12))
                .foregroundStyle(theme.foregroundMuted)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ quiz: Quiz) -> some View {
        let questions = quiz.orderedQuestions
        if isGenerating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(theme.accent)
                Text("generating…")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.foregroundMuted)
            }
            .padding(.top, 8)
        } else if questions.isEmpty {
            Text("nothing to quiz on here. the on-device engine looks for clear concept → definition patterns (\u{201C}X: ...\u{201D}, \u{201C}X is ...\u{201D}, headings + bullets). conversational notes won't yield questions — apple intelligence or mcp do a much better job with free-form text.")
                .font(.system(size: 13))
                .foregroundStyle(theme.foregroundSubtle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        } else {
            sectionLabel("\(questions.count) questions")
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(questions.enumerated()), id: \.element.id) { idx, q in
                    questionRow(index: idx + 1, question: q)
                }
            }
        }
    }

    @ViewBuilder
    private func questionRow(index: Int, question q: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(index). \(q.question)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            switch q.type {
            case .multipleChoice:
                let letters = ["A", "B", "C", "D"]
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, opt in
                    HStack(spacing: 8) {
                        Text(i < letters.count ? letters[i] : "•")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.foregroundSubtle)
                        Text(opt)
                            .font(.system(size: 13))
                            .foregroundStyle(i == q.correctOptionIndex ? theme.accent : theme.recessivePrimary)
                        if i == q.correctOptionIndex {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                }
            case .flashcard:
                Text(q.backText ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.recessivePrimary)
                    .fixedSize(horizontal: false, vertical: true)
            case .shortAnswer:
                if let sample = q.sampleAnswer {
                    Text("sample: \(sample)")
                        .font(.system(size: 13).italic())
                        .foregroundStyle(theme.foregroundSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Labels

    private func scopeLabel(_ scope: QuizScope) -> String {
        switch scope.type {
        case .notebook:
            return "from: 1 notebook"
        case .custom:
            let n = scope.notebookIDs.count
            return "from: \(n) notebook\(n == 1 ? "" : "s")"
        case .subject:
            return "from: \(scope.subjectName ?? "subject")"
        }
    }

    private func statsLine(_ quiz: Quiz) -> String {
        let qCount = quiz.orderedQuestions.count
        let attempts = quiz.attempts ?? []
        var parts = ["\(qCount) question\(qCount == 1 ? "" : "s")"]
        parts.append("\(attempts.count) attempt\(attempts.count == 1 ? "" : "s")")
        if let best = attempts.compactMap(\.score).max() {
            parts.append("best \(Int((best * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
    }
}
