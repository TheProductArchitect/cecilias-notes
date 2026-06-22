import SwiftUI

/// Files-style card for a `Quiz` in the All Quizzes grid. Mirrors
/// `SubjectFolderCardView` so the All Subjects and All Quizzes
/// surfaces share visual rhythm — the user reads them as siblings.
///
/// A quiz isn't a "folder" semantically — it has questions, not
/// children — so the glyph is a question-mark tile rather than a
/// folder. Question + attempt counts sit beneath the title, matching
/// the row form the previous AllQuizzesView surface used.
struct QuizFolderCardView: View {
    let quiz: Quiz
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.theme) private var theme

    @State private var isHovered = false

    private var isSelected: Bool {
        viewModel.selectedQuizIds.contains(quiz.id)
    }

    private var questionCount: Int { (quiz.questions ?? []).count }
    private var attemptCount:  Int { (quiz.attempts  ?? []).count }

    var body: some View {
        VStack(spacing: CeciliasNotes.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous)
                    .fill(theme.surface)

                Image(systemName: questionCount == 0
                      ? "questionmark.app.dashed"
                      : "questionmark.app.fill")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(theme.accent.opacity(0.85))
                    .accessibilityHidden(true)

                if questionCount > 0 {
                    VStack {
                        HStack {
                            Spacer()
                            CeciliasNotesBadge("\(questionCount)", style: .count)
                                .padding(8)
                        }
                        Spacer()
                    }
                }

                if viewModel.isSelecting {
                    VStack {
                        HStack {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(isSelected ? theme.accent : theme.recessiveTertiary)
                                .background(Circle().fill(theme.surface).padding(2))
                                .padding(8)
                            Spacer()
                        }
                        Spacer()
                    }
                }
            }
            .frame(height: 140)

            VStack(alignment: .leading, spacing: 2) {
                Text(quiz.title.isEmpty ? "untitled quiz" : quiz.title)
                    .font(.ceciliasNotesSubhead)
                    .foregroundColor(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(subtitleLabel)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.recessiveTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(CeciliasNotes.Spacing.sm)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous))
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { hovered in
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.precise)) { isHovered = hovered }
        }
        .contentShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous))
        .onTapGesture {
            if viewModel.isSelecting {
                if isSelected {
                    viewModel.selectedQuizIds.remove(quiz.id)
                } else {
                    viewModel.selectedQuizIds.insert(quiz.id)
                }
            } else {
                viewModel.selectedQuizID = quiz.id
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quiz \(quiz.title), \(questionCount) question\(questionCount == 1 ? "" : "s"), \(attemptCount) attempt\(attemptCount == 1 ? "" : "s")")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous)
            .fill(isSelected ? theme.accent.opacity(0.08) : Color.clear)
            .overlay(
                isSelected
                    ? RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous)
                        .strokeBorder(theme.accent, lineWidth: 1)
                    : nil
            )
    }

    private var subtitleLabel: String {
        let q = questionCount == 1 ? "1 question" : "\(questionCount) questions"
        let a = attemptCount == 0 ? "no attempts"
              : attemptCount == 1 ? "1 attempt"
              : "\(attemptCount) attempts"
        return "\(q) • \(a)"
    }
}
