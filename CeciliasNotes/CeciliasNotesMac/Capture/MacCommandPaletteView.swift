import SwiftData
import SwiftUI

/// ⌘K command palette — fuzzy jump to subjects, notebooks, and actions.
struct MacCommandPaletteView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Row: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let action: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("jump to…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .focused($focused)
                .onSubmit { performFirst() }

            Rectangle().fill(theme.hairline).frame(height: 0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredRows) { row in
                        Button { row.action(); dismiss() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: row.icon)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.recessiveTertiary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(theme.foreground)
                                    if !row.subtitle.isEmpty {
                                        Text(row.subtitle)
                                            .font(.system(size: 10).italic())
                                            .foregroundStyle(theme.recessiveTertiary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 480)
        .background(theme.surfaceElevated)
        .onAppear { focused = true }
    }

    private var filteredRows: [Row] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rows = allRows
        if !q.isEmpty {
            rows = rows.filter {
                $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
            }
        }
        return Array(rows.prefix(12))
    }

    private var allRows: [Row] {
        var rows: [Row] = [
            Row(id: "action-new", title: "New notebook", subtitle: "⌘N", icon: "plus") {
                NotificationCenter.default.post(name: .macNewNotebook, object: nil)
            },
            Row(id: "action-search", title: "Search library", subtitle: "⌘F", icon: "magnifyingglass") {
                NotificationCenter.default.post(name: .macOpenSearch, object: nil)
            },
            Row(id: "action-capture", title: "Quick capture", subtitle: "⌥⌘Space", icon: "square.and.pencil") {
                NotificationCenter.default.post(name: .macQuickCaptureToggle, object: nil)
            },
            Row(id: "action-settings", title: "Settings", subtitle: "⌘,", icon: "gearshape") {
                NotificationCenter.default.post(name: .macOpenSettings, object: nil)
            },
        ]

        for subject in libraryVM.subjects {
            rows.append(Row(
                id: "subject-\(subject.id.uuidString)",
                title: subject.name,
                subtitle: "subject",
                icon: "folder"
            ) {
                libraryVM.selectedContext = .subject(subject.id)
            })
        }

        for notebook in StorageService.shared.fetchAllNotebooks().filter({ !$0.isDeleted }).prefix(60) {
            let subjectName = libraryVM.subjects.first { $0.id == notebook.subjectId }?.name ?? "unfiled"
            rows.append(Row(
                id: "nb-\(notebook.id.uuidString)",
                title: notebook.title,
                subtitle: subjectName.lowercased(),
                icon: "book.closed"
            ) {
                libraryVM.selectedNotebookId = notebook.id
            })
        }
        return rows
    }

    private func performFirst() {
        filteredRows.first?.action()
        dismiss()
    }
}
