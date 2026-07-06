import SwiftUI

/// Notebook cover editor for Mac — 8-tone palette + inline title field.
/// Mirrors the iPad customise panel's cover section without pulling in
/// the full `CustomisePanel` (which depends on UIKit thumb previews).
struct MacNotebookCoverSheet: View {
    @Bindable var notebook: Notebook
    @ObservedObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var title: String
    @State private var selectedTone: NotebookCoverTone

    init(notebook: Notebook, libraryVM: LibraryViewModel) {
        self.notebook = notebook
        self.libraryVM = libraryVM
        _title = State(initialValue: notebook.title)
        _selectedTone = State(initialValue: notebook.coverTone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("notebook cover")
                .font(.system(size: 8, weight: .regular))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveTertiary)

            TextField("title", text: $title)
                .font(.system(size: 19, weight: .heavy))
                .textFieldStyle(.plain)
                .onSubmit { commit() }

            CoverTonePickerView(notebook: notebook) {
                selectedTone = notebook.coverTone
                libraryVM.refresh()
            }

            HStack {
                Spacer()
                Button("Done") { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 340)
        .background(theme.surfaceElevated)
    }

    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != notebook.title {
            notebook.title = trimmed
            notebook.markModified()
        }
        CoverToneStore.setTone(selectedTone, for: notebook.id)
        try? StorageService.shared.context.save()
        libraryVM.refresh()
        dismiss()
    }
}
