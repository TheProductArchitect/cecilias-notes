import SwiftUI
import SwiftData

/// Full-screen quiz experience. Thin progress bar + counter + exit at
/// the top; the body switches on the current question's type. On the
/// last answer it hands off to `QuizResultsView`.
struct QuizTakingView: View {
    @StateObject private var vm: QuizTakingViewModel
    private let context: ModelContext
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @State private var showQuitConfirm = false

    init(quiz: Quiz, context: ModelContext, onClose: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: QuizTakingViewModel(quiz: quiz, context: context))
        self.context = context
        self.onClose = onClose
    }

    var body: some View {
        Group {
            if vm.isFinished, let result = vm.result {
                QuizResultsView(
                    result: result,
                    onReviewMissed: { reviewMissed(result) },
                    onDone: onClose
                )
            } else {
                taking
            }
        }
        .background(theme.surface.ignoresSafeArea())
    }

    /// Restart the session over just the missed questions as a
    /// non-persisted practice run. Closes the sheet if nothing missed.
    private func reviewMissed(_ result: QuizResult) {
        let missedSet = Set(result.missedQuestionIDs)
        let subset = vm.questions.filter { missedSet.contains($0.id) }
        if subset.isEmpty { onClose(); return }
        vm.restart(with: subset)
    }

    // MARK: - Taking

    private var taking: some View {
        VStack(spacing: 0) {
            progressBar
            topBar
            if let q = vm.current {
                questionBody(q)
                    .id(q.id)   // reset per-question local state
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 28)
            } else {
                Spacer()
            }
        }
        .alert("quit quiz?", isPresented: $showQuitConfirm) {
            Button("quit", role: .destructive, action: onClose)
            Button("keep going", role: .cancel) {}
        } message: {
            Text("your progress will be lost.")
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(theme.recessiveQuinary.opacity(0.4))
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: geo.size.width * vm.progress)
                    .animation(.easeInOut(duration: 0.25), value: vm.progress)
            }
        }
        .frame(height: 1)
    }

    private var topBar: some View {
        HStack {
            Button { showQuitConfirm = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(theme.foregroundSubtle)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("\(vm.index + 1) / \(vm.questions.count)")
                .font(.system(size: 9, weight: .regular))
                .tracking(0.08)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveQuaternary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func questionBody(_ q: QuizQuestion) -> some View {
        switch q.type {
        case .multipleChoice:
            MultipleChoiceQuestionView(question: q, vm: vm)
        case .flashcard:
            FlashcardQuestionView(question: q, vm: vm)
        case .shortAnswer:
            ShortAnswerQuestionView(question: q, vm: vm)
        }
    }
}

// MARK: - Source label

private struct FromLabel: View {
    let question: QuizQuestion
    @Environment(\.theme) private var theme
    var body: some View {
        Group {
            if let title = notebookTitle {
                Text("from: \(title.lowercased())")
            } else {
                Text("from: your notes")
            }
        }
        .font(.system(size: 9).italic())
        .foregroundStyle(theme.recessiveQuaternary)
    }
    private var notebookTitle: String? {
        guard let id = question.sourceNotebookID else { return nil }
        var d = FetchDescriptor<Notebook>(predicate: #Predicate<Notebook> { $0.id == id })
        d.fetchLimit = 1
        return (try? StorageService.shared.context.fetch(d))?.first?.title
    }
}

// MARK: - Multiple choice

private struct MultipleChoiceQuestionView: View {
    let question: QuizQuestion
    @ObservedObject var vm: QuizTakingViewModel
    @Environment(\.theme) private var theme
    @State private var selected: Int?

    private let letters = ["A", "B", "C", "D"]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            FromLabel(question: question)
            Text(question.question)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(theme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { i, opt in
                    optionRow(i, opt)
                    if i < question.options.count - 1 {
                        Rectangle().fill(theme.recessiveQuinary).frame(height: 0.5)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.recessiveQuinary, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Spacer()
            if selected != nil {
                HStack {
                    Spacer()
                    Button {
                        vm.advanceOrFinish()
                    } label: {
                        Text("next →")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 24)
            }
        }
        .padding(.top, 12)
    }

    private func optionRow(_ i: Int, _ opt: String) -> some View {
        let isAnswered = selected != nil
        let isCorrect = i == question.correctOptionIndex
        let isSelected = i == selected
        let (bg, fg): (Color, Color) = {
            guard isAnswered else { return (.clear, theme.foreground) }
            if isCorrect { return (theme.accent, .white) }
            if isSelected { return (theme.danger, .white) }
            return (.clear, theme.foreground)
        }()
        return Button {
            guard selected == nil else { return }
            selected = i
            vm.answerMultipleChoice(i)
        } label: {
            HStack(spacing: 12) {
                Text(i < letters.count ? letters[i] : "•")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(fg.opacity(isAnswered && (isCorrect || isSelected) ? 0.9 : 0.5))
                Text(opt)
                    .font(.system(size: 15))
                    .foregroundStyle(fg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAnswered)
    }
}

// MARK: - Flashcard

private struct FlashcardQuestionView: View {
    let question: QuizQuestion
    @ObservedObject var vm: QuizTakingViewModel
    @Environment(\.theme) private var theme
    @State private var flipped = false

    var body: some View {
        VStack(spacing: 20) {
            FromLabel(question: question)
                .frame(maxWidth: .infinity, alignment: .leading)

            card
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture {
                    if !flipped {
                        withAnimation(.easeInOut(duration: 0.4)) { flipped = true }
                    }
                }

            if flipped {
                ratingRow
            } else {
                Text("tap to reveal →")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(theme.recessiveQuaternary)
            }
        }
        .padding(.vertical, 16)
    }

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.recessiveQuinary, lineWidth: 0.5)
            VStack(spacing: 12) {
                if flipped {
                    Text(question.frontText ?? question.question)
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(theme.foreground)
                    Text(question.backText ?? "")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.recessivePrimary)
                        .multilineTextAlignment(.center)
                } else {
                    Text(question.frontText ?? question.question)
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(theme.foreground)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(28)
            // Counter-rotate the content so it isn't mirrored after the
            // container's 3D flip.
            .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        }
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
    }

    private var ratingRow: some View {
        HStack(spacing: 10) {
            ratingButton("again", .again, tint: theme.danger)
            ratingButton("hard", .hard, tint: Color(light: Color(hex: "#ff9500"), dark: Color(hex: "#ff9f0a")))
            ratingButton("good", .good, tint: theme.accent)
            ratingButton("easy", .easy, tint: Color(light: Color(hex: "#34c759"), dark: Color(hex: "#30d158")))
        }
    }

    private func ratingButton(_ label: String, _ rating: FlashcardRating, tint: Color) -> some View {
        Button {
            vm.answerFlashcard(rating)
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Short answer

private struct ShortAnswerQuestionView: View {
    let question: QuizQuestion
    @ObservedObject var vm: QuizTakingViewModel
    @Environment(\.theme) private var theme

    @State private var text = ""
    @State private var marking = false
    @State private var feedback: String?
    @State private var score: Double?
    @State private var showSelfAssess = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FromLabel(question: question)
            Text(question.question)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(theme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 15))
                .frame(minHeight: 120, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.recessiveQuinary, lineWidth: 0.5)
                )
                .focused($focused)
                .disabled(feedback != nil || showSelfAssess)

            if let feedback {
                VStack(alignment: .leading, spacing: 6) {
                    if let score {
                        Text("\(Int((score * 100).rounded()))%")
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundStyle(theme.accent)
                    }
                    Text(feedback)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.foregroundMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                nextButton
            } else if showSelfAssess {
                if let sample = question.sampleAnswer {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("sample answer")
                            .font(.system(size: 8)).tracking(0.08).textCase(.uppercase)
                            .foregroundStyle(theme.recessiveQuaternary)
                        Text(sample)
                            .font(.system(size: 14))
                            .foregroundStyle(theme.recessivePrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 12) {
                    selfAssessButton("i got it", gotIt: true)
                    selfAssessButton("i didn't", gotIt: false)
                }
            } else {
                submitButton
            }
            Spacer()
        }
        .padding(.top, 12)
        .onAppear { focused = true }
    }

    private var submitButton: some View {
        HStack {
            Spacer()
            Button {
                Task { await submit() }
            } label: {
                if marking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("marking…").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(theme.foregroundMuted)
                } else {
                    Text("submit answer →")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || marking)
        }
    }

    private var nextButton: some View {
        HStack {
            Spacer()
            Button { vm.advanceOrFinish() } label: {
                Text(vm.isLastQuestion ? "finish →" : "next →")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func selfAssessButton(_ label: String, gotIt: Bool) -> some View {
        Button {
            vm.answerShortAnswerSelfAssessed(gotIt, text: text)
            vm.advanceOrFinish()
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(gotIt ? theme.accent : theme.foregroundMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.recessiveQuinary, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func submit() async {
        focused = false
        marking = true
        let mark = await vm.markShortAnswer(text)
        marking = false
        if let mark {
            score = mark.score
            feedback = mark.feedback
        } else {
            // No AI marker available — fall back to self-assessment
            // against the sample answer.
            showSelfAssess = true
        }
    }
}
