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

    @Query(sort: [SortDescriptor(\Subject.sortOrder)])
    private var subjects: [Subject]

    private var active: [Subject] { subjects.filter { !$0.isDeleted } }

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

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(active, id: \.id) { subject in
                    row(for: subject)
                    Rectangle()
                        .fill(theme.recessiveQuinary)
                        .frame(height: 0.5)
                        .padding(.leading, 24)
                }
            }
        }
    }

    private func row(for subject: Subject) -> some View {
        let isSelected = viewModel.selectedSubjectIds.contains(subject.id)
        return HStack(spacing: 12) {
            if viewModel.isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? theme.accent : theme.recessiveTertiary)
            }
            Image(systemName: "folder")
                .font(.system(size: 16))
                .foregroundStyle(theme.recessiveSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(subject.name.isEmpty ? "untitled subject" : subject.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.foreground)
                Text(countLabel(for: subject))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.recessiveTertiary)
            }
            Spacer(minLength: 0)
            if subject.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.recessiveTertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if viewModel.isSelecting {
                if isSelected { viewModel.selectedSubjectIds.remove(subject.id) }
                else          { viewModel.selectedSubjectIds.insert(subject.id) }
            } else {
                viewModel.selectedContext = .subject(subject.id)
            }
        }
    }

    private func countLabel(for subject: Subject) -> String {
        let count = (subject.notebooks ?? []).filter { !$0.isDeleted }.count
        return count == 1 ? "1 notebook" : "\(count) notebooks"
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
