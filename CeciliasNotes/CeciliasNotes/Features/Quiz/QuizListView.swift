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

    /// Quizzes grouped by folder name. Empty folder name lands the
    /// quiz under the default "ungrouped" bucket. Within each
    /// group quizzes keep the @Query sort (createdAt desc).
    private var grouped: [(folder: String, quizzes: [Quiz])] {
        let dict = Dictionary(grouping: quizzes) { quiz -> String in
            let trimmed = quiz.folderName.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "" : trimmed
        }
        // Ungrouped first, then folders alphabetically.
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

    /// All folder names currently in use — feeds the row context
    /// menu's "move to folder…" submenu so the user can drop into
    /// an existing folder without retyping it.
    private var existingFolders: [String] {
        Array(Set(quizzes.compactMap { quiz -> String? in
            let trimmed = quiz.folderName.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        })).sorted { $0.lowercased() < $1.lowercased() }
    }

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
                ForEach(grouped, id: \.folder) { group in
                    if !group.folder.isEmpty {
                        folderHeader(group.folder)
                    }
                    ForEach(group.quizzes) { quiz in
                        QuizSidebarRow(
                            quiz: quiz,
                            viewModel: viewModel,
                            isGenerating: generation.generatingQuizIDs.contains(quiz.id),
                            existingFolders: existingFolders
                        )
                    }
                }
            }
        }
    }

    /// Folder name strip — single-line, recessive caption. Tap to
    /// rename / delete the folder via context menu surfaced on
    /// the rows themselves; this row is just a divider.
    private func folderHeader(_ name: String) -> some View {
        Text(name.lowercased())
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(0.04)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveTertiary)
            .padding(.horizontal, Self.horizontalInset)
            .padding(.top, 10)
            .padding(.bottom, 4)
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
    let existingFolders: [String]
    @Environment(\.theme) private var theme

    private var isSelected: Bool { viewModel.selectedQuizID == quiz.id }
    @State private var confirmDelete = false
    @State private var isRenaming = false
    @State private var renameBuffer = ""
    @State private var isCreatingFolder = false
    @State private var newFolderBuffer = ""

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
            Button {
                renameBuffer = quiz.title
                isRenaming = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Menu {
                if !existingFolders.isEmpty {
                    ForEach(existingFolders, id: \.self) { folder in
                        Button {
                            moveQuiz(to: folder)
                        } label: {
                            if quiz.folderName == folder {
                                Label(folder, systemImage: "checkmark")
                            } else {
                                Text(folder)
                            }
                        }
                    }
                    Divider()
                }
                Button {
                    newFolderBuffer = ""
                    isCreatingFolder = true
                } label: {
                    Label("New folder…", systemImage: "folder.badge.plus")
                }
                if !quiz.folderName.isEmpty {
                    Button {
                        moveQuiz(to: "")
                    } label: {
                        Label("Remove from folder", systemImage: "folder.badge.minus")
                    }
                }
            } label: {
                Label(quiz.folderName.isEmpty ? "Move to folder…" : "Folder: \(quiz.folderName)",
                      systemImage: "folder")
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("new folder", isPresented: $isCreatingFolder) {
            TextField("folder name", text: $newFolderBuffer)
            Button("create") {
                let trimmed = newFolderBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                moveQuiz(to: trimmed)
                newFolderBuffer = ""
            }
            Button("cancel", role: .cancel) { newFolderBuffer = "" }
        } message: {
            Text("group related quizzes under a folder in the sidebar. existing folders are listed above this option.")
        }
        .alert("rename quiz", isPresented: $isRenaming) {
            TextField("quiz name", text: $renameBuffer)
            Button("rename") { commitRename() }
            Button("cancel", role: .cancel) { renameBuffer = "" }
        } message: {
            Text("multiple quizzes for the same notebook share the same auto-generated title; rename to tell them apart.")
        }
        .alert("delete this quiz?", isPresented: $confirmDelete) {
            Button("delete", role: .destructive) { delete() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("\(quiz.title.isEmpty ? "this quiz" : quiz.title) and its questions and attempt history will be removed. this can't be undone.")
        }
    }

    private func commitRename() {
        let trimmed = renameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != quiz.title else {
            renameBuffer = ""
            return
        }
        quiz.title = trimmed
        do {
            try StorageService.shared.context.save()
        } catch {
            #if DEBUG
            dlog("[QuizList] rename SAVE FAILED quizId=\(quiz.id): \(error)")
            #endif
        }
        renameBuffer = ""
        HapticManager.shared.toolSwitched()
    }

    private func moveQuiz(to folder: String) {
        quiz.folderName = folder
        quiz.updatedAt = Date()
        do {
            try StorageService.shared.context.save()
        } catch {
            #if DEBUG
            dlog("[QuizList] move SAVE FAILED quizId=\(quiz.id): \(error)")
            #endif
        }
        HapticManager.shared.toolSwitched()
    }

    private func delete() {
        // Clear the selection if it points at this quiz so the detail
        // pane doesn't try to render a deleted row.
        if viewModel.selectedQuizID == quiz.id {
            viewModel.selectedQuizID = nil
        }
        let ctx = StorageService.shared.context
        ctx.delete(quiz)   // cascades to questions, attempts, responses
        do {
            try ctx.save()
        } catch {
            #if DEBUG
            dlog("[QuizList] delete SAVE FAILED quizId=\(quiz.id): \(error)")
            #endif
        }
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
