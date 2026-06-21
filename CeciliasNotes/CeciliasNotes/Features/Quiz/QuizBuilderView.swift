import SwiftUI
import SwiftData

/// Three-step (two-screen) quiz builder presented as a bottom sheet.
/// Step 1 picks the source scope; Step 2 picks the format + options and
/// kicks off generation via `QuizGenerationService`.
struct QuizBuilderView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<Notebook> { $0.isDeleted == false }, sort: \Notebook.updatedAt, order: .reverse)
    private var notebooks: [Notebook]
    @Query(filter: #Predicate<Subject> { $0.isDeleted == false }, sort: \Subject.name)
    private var subjects: [Subject]

    // Step
    private enum Step { case scope, format }
    @State private var step: Step = .scope

    // Scope
    @State private var scopeType: QuizScope.ScopeType = .notebook
    @State private var selectedNotebookID: UUID?
    @State private var selectedSubjectID: UUID?
    @State private var customSelected: Set<UUID> = []
    @State private var includeTranscriptions: Bool = true

    // Format + options
    @State private var format: QuizFormat = .multipleChoice
    @State private var questionCount: Int = 10
    @State private var autoAdd: Bool = false
    @State private var tier: AITier = .appleIntelligence

    private var aiAvailable: Bool { IntelligenceService.shared.canRun }
    private var mcpAvailable: Bool { MCPStatusMonitor.shared.hasEverConnected }
    private var shortAnswerAvailable: Bool { aiAvailable || mcpAvailable }
    private var availableTiers: [AITier] { QuizGenerationService.shared.availableTiers() }

    /// Tracks which row's eligibility popover is open. Identity is
    /// notebook / subject UUID (the source row's id) plus the
    /// reason text — we only ever surface one popover at a time.
    @State private var eligibilityPopoverFor: UUID?

    /// Result of running the source-text pre-flight on a notebook or
    /// a subject. `eligible` carries the rough size; `ineligible`
    /// carries the user-facing reason rendered in the popover.
    enum QuizEligibility {
        case eligible(unitCount: Int)
        case ineligible(reason: String)

        var isEligible: Bool {
            if case .eligible = self { return true }
            return false
        }
    }

    /// Pre-flights a notebook for quiz generation by checking how
    /// much typed / transcribed / PDF text is on hand. Hand-drawn
    /// ink is invisible to every tier (no OCR), so a notebook full
    /// of strokes only is `.ineligible` with a clear explanation.
    private func eligibility(for notebook: Notebook) -> QuizEligibility {
        let context = StorageService.shared.context
        let scope = QuizScope(
            type: .notebook,
            notebookIDs: [notebook.id],
            includeTranscriptions: includeTranscriptions
        )
        let count = QuizSourceCollector.contentUnitCount(scope: scope, context: context)
        if count > 0 { return .eligible(unitCount: count) }
        return .ineligible(reason: """
            this notebook has no text the model can read. quiz \
            generation needs typed text blocks, audio transcripts, \
            or text extracted from imported PDFs. handwritten ink is \
            not recognised yet.
            """)
    }

    /// Pre-flights a subject by aggregating its notebooks. Ineligible
    /// when *every* notebook in the subject is empty of usable text.
    private func eligibility(for subject: Subject) -> QuizEligibility {
        let context = StorageService.shared.context
        let scope = QuizScope(
            type: .subject,
            subjectID: subject.id,
            subjectName: subject.name,
            includeTranscriptions: includeTranscriptions
        )
        let count = QuizSourceCollector.contentUnitCount(scope: scope, context: context)
        if count > 0 { return .eligible(unitCount: count) }
        let notebookCount = notebooks.filter { $0.subjectId == subject.id }.count
        if notebookCount == 0 {
            return .ineligible(reason: "this subject has no notebooks yet.")
        }
        return .ineligible(reason: """
            none of the notebooks in this subject have text the model \
            can read. quiz generation needs typed text blocks, audio \
            transcripts, or text extracted from imported PDFs. \
            handwritten ink is not recognised yet.
            """)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if step == .scope { scopeStep } else { formatStep }
                }
                .padding(24)
            }
            footer
        }
        .background(theme.surface.ignoresSafeArea())
        .presentationDetents([.fraction(0.82), .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: seedDefaults)
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack {
            Text("new quiz")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(theme.foreground)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.foregroundSubtle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    // MARK: Step 1 — Scope

    private var scopeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            label("what to quiz on")

            Picker("", selection: $scopeType) {
                Text("notebook").tag(QuizScope.ScopeType.notebook)
                Text("subject").tag(QuizScope.ScopeType.subject)
                Text("custom").tag(QuizScope.ScopeType.custom)
            }
            .pickerStyle(.segmented)

            switch scopeType {
            case .notebook: notebookList(multi: false)
            case .custom:   notebookList(multi: true)
            case .subject:  subjectList
            }

            if let preview = previewLine {
                Text(preview)
                    .font(.system(size: 13).italic())
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Rectangle().fill(theme.recessiveQuinary).frame(height: 0.5)

            HStack {
                Text("include audio transcriptions")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.foreground)
                Spacer()
                Toggle("", isOn: $includeTranscriptions).labelsHidden().tint(theme.accent)
            }
        }
    }

    private func notebookList(multi: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(notebooks) { nb in
                let elig = eligibility(for: nb)
                let isEligible = elig.isEligible
                let isSelected = multi ? customSelected.contains(nb.id) : selectedNotebookID == nb.id
                // Row split into a tappable name column (disabled
                // when ineligible) and an always-tappable trailing
                // strip with the (i) icon. Disabling the outer
                // Button used to disable the (i) too, so the user
                // had no way to discover WHY a row was greyed out.
                HStack(spacing: 0) {
                    Button {
                        guard isEligible else { return }
                        if multi {
                            if customSelected.contains(nb.id) { customSelected.remove(nb.id) }
                            else { customSelected.insert(nb.id) }
                        } else {
                            selectedNotebookID = nb.id
                        }
                    } label: {
                        HStack {
                            Text(nb.title.isEmpty ? "untitled" : nb.title.lowercased())
                                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? theme.accent
                                                : (isEligible ? theme.foreground : theme.foregroundSubtle))
                            Spacer()
                            Text("\(nb.totalPageCount) pages")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.foregroundSubtle)
                        }
                        .padding(.vertical, 12)
                        .padding(.leading, 14)
                        .padding(.trailing, 8)
                        .contentShape(Rectangle())
                        .opacity(isEligible ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEligible)
                    HStack(spacing: 8) {
                        if !isEligible {
                            eligibilityInfoButton(id: nb.id, reason: ineligibleReason(elig))
                        }
                        if isSelected {
                            Image(systemName: multi ? "checkmark.square.fill" : "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 14)
                }
                Rectangle().fill(theme.recessiveQuinary).frame(height: 0.5)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.recessiveQuinary, lineWidth: 0.5)
        )
    }

    private var subjectList: some View {
        VStack(spacing: 0) {
            ForEach(subjects) { subject in
                let elig = eligibility(for: subject)
                let isEligible = elig.isEligible
                let isSelected = selectedSubjectID == subject.id
                HStack(spacing: 0) {
                    Button {
                        guard isEligible else { return }
                        selectedSubjectID = subject.id
                    } label: {
                        HStack {
                            Text(subject.name.lowercased())
                                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? theme.accent
                                                : (isEligible ? theme.foreground : theme.foregroundSubtle))
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .padding(.leading, 14)
                        .padding(.trailing, 8)
                        .contentShape(Rectangle())
                        .opacity(isEligible ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEligible)
                    HStack(spacing: 8) {
                        if !isEligible {
                            eligibilityInfoButton(id: subject.id, reason: ineligibleReason(elig))
                        }
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 14)
                }
                Rectangle().fill(theme.recessiveQuinary).frame(height: 0.5)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.recessiveQuinary, lineWidth: 0.5)
        )
    }

    /// (i) icon next to an ineligible row. Tap opens a popover with
    /// the reason — same UI for notebooks and subjects.
    @ViewBuilder
    private func eligibilityInfoButton(id: UUID, reason: String) -> some View {
        Button {
            eligibilityPopoverFor = (eligibilityPopoverFor == id) ? nil : id
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(theme.foregroundSubtle)
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: Binding(
                get: { eligibilityPopoverFor == id },
                set: { if !$0 { eligibilityPopoverFor = nil } }
            ),
            attachmentAnchor: .point(.center),
            arrowEdge: .top
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("can't generate a quiz here")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foregroundMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(width: 300)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func ineligibleReason(_ elig: QuizEligibility) -> String {
        if case .ineligible(let reason) = elig { return reason }
        return ""
    }

    // MARK: Step 2 — Format

    private var formatStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            label("question format")
            HStack(spacing: 12) {
                formatCard(.multipleChoice, title: "multiple\nchoice", caption: "4 options,\nauto-scored", enabled: true)
                formatCard(.flashcard, title: "flashcards", caption: "term →\ndefinition,\nself-rated", enabled: true)
                formatCard(.shortAnswer, title: "short\nanswer", caption: "typed\nresponse,\nAI-marked", enabled: shortAnswerAvailable)
            }

            label("options")
            VStack(spacing: 0) {
                stepperRow
                Rectangle().fill(theme.recessiveQuinary).frame(height: 0.5)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("auto-add questions").font(.system(size: 14)).foregroundStyle(theme.foreground)
                        Text("as notes grow, weekly").font(.system(size: 12)).foregroundStyle(theme.foregroundSubtle)
                    }
                    Spacer()
                    Toggle("", isOn: $autoAdd).labelsHidden().tint(theme.accent)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.recessiveQuinary, lineWidth: 0.5)
            )

            if availableTiers.count > 1 {
                label("generate using")
                Picker("", selection: $tier) {
                    ForEach(availableTiers, id: \.self) { t in
                        Text(tierLabel(t)).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            } else if availableTiers.isEmpty {
                Text("quiz generation needs apple intelligence or mcp. turn on apple intelligence in settings → intelligence, or connect mcp on your mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foregroundSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func formatCard(_ value: QuizFormat, title: String, caption: String, enabled: Bool) -> some View {
        let isSelected = format == value && enabled
        return Button {
            guard enabled else { return }
            format = value
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(enabled ? theme.foreground : theme.foregroundSubtle)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foregroundSubtle)
                    .fixedSize(horizontal: false, vertical: true)
                if !enabled {
                    Text("requires Apple Intelligence or MCP")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .padding(14)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? theme.accent : theme.recessiveQuinary,
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Hard ceiling on questions per quiz. Apple Intelligence's 3B
    /// model caps the full prompt at 4096 tokens; per-format
    /// instruction blocks add a fixed overhead per question slot,
    /// and at ~30 questions the prompt template alone starts
    /// crowding out the source-text room left after the
    /// QuizGen corpus cap (~9.5k chars / ~2.4k tokens). 20 keeps a
    /// comfortable margin under that ceiling for every format. The
    /// user can always generate a second quiz from the same source
    /// if they need more questions.
    private static let maxQuestionsPerQuiz: Int = 20
    private static let minQuestionsPerQuiz: Int = 5

    private var stepperRow: some View {
        HStack {
            Text("number of questions").font(.system(size: 14)).foregroundStyle(theme.foreground)
            Spacer()
            Button { questionCount = max(Self.minQuestionsPerQuiz, questionCount - 1) } label: {
                Image(systemName: "minus").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.foregroundMuted)
            }.buttonStyle(.plain)
            .disabled(questionCount <= Self.minQuestionsPerQuiz)
            Text("\(questionCount)").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.foreground)
                .frame(minWidth: 28)
            Button { questionCount = min(Self.maxQuestionsPerQuiz, questionCount + 1) } label: {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
            }.buttonStyle(.plain)
            .disabled(questionCount >= Self.maxQuestionsPerQuiz)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.recessiveQuinary).frame(height: 0.5)
            if step == .scope {
                primaryButton("next — format →", fill: theme.foreground, enabled: scopeIsValid) {
                    step = .format
                }
            } else {
                primaryButton(
                    "generate quiz →",
                    fill: theme.accent,
                    enabled: scopeIsValid && !availableTiers.isEmpty
                ) {
                    generate()
                }
            }
        }
    }

    private func primaryButton(_ title: String, fill: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(fill.opacity(enabled ? 1 : 0.4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: Logic

    private func seedDefaults() {
        let defaults = UserDefaults.standard
        includeTranscriptions = defaults.object(forKey: "ceciliasnotes.quiz.includeTranscriptions") as? Bool ?? true
        autoAdd = defaults.bool(forKey: "ceciliasnotes.quiz.autoAdd")
        // Apple Intelligence is the preferred default; fall back
        // to whatever tier is currently available. On-device was
        // retired so a persisted ".onDevice" choice from older
        // installs is silently upgraded.
        let persisted = AITier(rawValue: defaults.string(forKey: "ceciliasnotes.quiz.engine") ?? "")
        if let persisted, availableTiers.contains(persisted), persisted != .onDevice {
            tier = persisted
        } else {
            tier = availableTiers.first ?? .appleIntelligence
        }
        // Pre-scope to the currently selected subject if any.
        if case .subject(let id) = viewModel.selectedContext {
            scopeType = .subject
            selectedSubjectID = id
        }
    }

    private var scopeIsValid: Bool {
        switch scopeType {
        case .notebook: return selectedNotebookID != nil
        case .subject:  return selectedSubjectID != nil
        case .custom:   return !customSelected.isEmpty
        }
    }

    private func buildScope() -> QuizScope {
        switch scopeType {
        case .notebook:
            return QuizScope(type: .notebook,
                             notebookIDs: [selectedNotebookID].compactMap { $0 },
                             includeTranscriptions: includeTranscriptions)
        case .custom:
            return QuizScope(type: .custom,
                             notebookIDs: Array(customSelected),
                             includeTranscriptions: includeTranscriptions)
        case .subject:
            let name = subjects.first { $0.id == selectedSubjectID }?.name
            return QuizScope(type: .subject,
                             subjectID: selectedSubjectID,
                             subjectName: name,
                             includeTranscriptions: includeTranscriptions)
        }
    }

    private var previewLine: String? {
        guard scopeIsValid else { return nil }
        let count = QuizSourceCollector.contentUnitCount(
            scope: buildScope(), context: StorageService.shared.context
        )
        if count == 0 {
            return "no typed content found in this scope. add text blocks to your notes to generate questions."
        }
        return "~\(count) pages of content found"
    }

    private func generate() {
        let scope = buildScope()
        let quiz = QuizGenerationService.shared.createQuiz(
            title: builderTitle(for: scope),
            scope: scope,
            format: format,
            requestedTier: tier,
            questionCount: questionCount,
            autoUpdate: autoAdd
        )
        viewModel.selectedQuizID = quiz.id
        dismiss()
    }

    private func builderTitle(for scope: QuizScope) -> String {
        switch scope.type {
        case .notebook:
            return notebooks.first { $0.id == selectedNotebookID }?.title.lowercased() ?? "new quiz"
        case .subject:
            return (scope.subjectName ?? "new quiz").lowercased()
        case .custom:
            return "new quiz"
        }
    }

    private func tierLabel(_ t: AITier) -> String {
        switch t {
        case .onDevice:          return "on-device"   // legacy — never shown via availableTiers
        case .appleIntelligence: return "apple intel."
        case .mcp:               return "mcp"
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8)).tracking(0.08).textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
    }
}
