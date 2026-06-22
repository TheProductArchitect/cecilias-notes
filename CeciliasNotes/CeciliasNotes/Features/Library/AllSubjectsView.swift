import SwiftData
import SwiftUI

/// File-system style list of every Subject. Mounted by `LibraryView`
/// when `selectedContext == .allSubjects`. Mirrors the existing
/// `TrashView` shape — single-column list, multi-select for batch
/// delete — but without per-row context menus the sidebar already
/// provides. The user gets a quick "I want to clean out several
/// subjects at once" surface without having to long-press each row
/// in the sidebar.
struct AllSubjectsView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.theme) private var theme

    @Query(sort: [SortDescriptor(\Subject.sortOrder)])
    private var subjects: [Subject]

    @State private var selection: Set<UUID> = []
    @State private var isEditing: Bool = false
    @State private var confirmDelete: Bool = false

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
        .alert(
            "delete \(selection.count) \(selection.count == 1 ? "subject" : "subjects")?",
            isPresented: $confirmDelete
        ) {
            Button("delete", role: .destructive) { deleteSelected() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("removes the selected subjects. notebooks inside them are moved to trash and can be restored individually.")
        }
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
            if isEditing {
                Button(role: .destructive) {
                    if !selection.isEmpty { confirmDelete = true }
                } label: {
                    Text("delete \(selection.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selection.isEmpty ? theme.recessiveTertiary : theme.danger)
                }
                .buttonStyle(.plain)
                .disabled(selection.isEmpty)
            }
            Button {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                    isEditing.toggle()
                    if !isEditing { selection.removeAll() }
                }
            } label: {
                Text(isEditing ? "done" : "select")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
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
        let isSelected = selection.contains(subject.id)
        return HStack(spacing: 12) {
            if isEditing {
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
            if isEditing {
                if isSelected { selection.remove(subject.id) }
                else          { selection.insert(subject.id) }
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

    private func deleteSelected() {
        let targets = active.filter { selection.contains($0.id) }
        for subject in targets {
            viewModel.deleteSubject(subject)
        }
        selection.removeAll()
        HapticManager.shared.destructiveConfirmed()
    }
}
