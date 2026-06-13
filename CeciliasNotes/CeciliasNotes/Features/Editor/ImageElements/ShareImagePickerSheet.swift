import SwiftUI

/// Lighter cousin of `PDFPagePickerSheet` for the share-inbox image
/// flow. There's only one image so there's nothing to "select" —
/// the sheet shrinks to a destination chooser plus a thumbnail
/// preview of the image about to be filed.
struct ShareImagePickerSheet: View {

    let sourceURL: URL
    let subjects: [Subject]
    let notebooks: [Notebook]
    let onConfirm: (ShareImageImporter.Destination) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme

    @State private var preview: UIImage?
    @State private var pickedSubjectId: UUID?
    @State private var pickedNotebookId: UUID?
    @State private var useNewNotebook: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            topBar
            CeciliasNotesDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.lg) {
                    previewSection
                    destinationSection
                    detailSection
                }
                .padding(CeciliasNotes.Spacing.lg)
            }
        }
        .background(theme.surface.ignoresSafeArea())
        .task { await loadPreview() }
        .onAppear {
            pickedSubjectId = subjects.first?.id
            pickedNotebookId = notebooks.first?.id
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button("Cancel") { onCancel() }
                .foregroundStyle(theme.foreground)
            Spacer()
            Text(sourceURL.deletingPathExtension().lastPathComponent)
                .font(.ceciliasNotesSubhead)
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Done") { onConfirm(resolvedDestination) }
                .foregroundStyle(canConfirm ? theme.accent : theme.foregroundSubtle)
                .disabled(!canConfirm)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.lg)
        .padding(.vertical, CeciliasNotes.Spacing.md)
    }

    // MARK: - Sections

    @ViewBuilder
    private var previewSection: some View {
        if let preview {
            Image(uiImage: preview)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surface)
                .frame(height: 160)
                .overlay(ProgressView().tint(theme.accent))
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("import to")
                .font(.system(size: 11, weight: .medium).smallCaps())
                .tracking(0.06)
                .foregroundStyle(theme.foregroundSubtle)
            HStack(spacing: 8) {
                destinationChip(
                    title: "new notebook",
                    subtitle: "create one for this image",
                    isSelected: useNewNotebook
                ) { useNewNotebook = true }
                destinationChip(
                    title: "existing notebook",
                    subtitle: "append a new page",
                    isSelected: !useNewNotebook
                ) { useNewNotebook = false }
            }
        }
    }

    @ViewBuilder
    private var detailSection: some View {
        if useNewNotebook {
            subjectMenu
        } else {
            notebookMenu
        }
    }

    private var subjectMenu: some View {
        Menu {
            // Subjects only — notebooks need a real subject; surfacing
            // "Uncategorised" here would file the image into a bucket
            // that isn't actually a subject.
            ForEach(subjects) { subject in
                Button(subject.name) { pickedSubjectId = subject.id }
            }
        } label: {
            HStack(spacing: 6) {
                Text("subject")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.foregroundSubtle)
                Text(subjectName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.foregroundSubtle)
            }
        }
        .disabled(subjects.isEmpty)
    }

    private var notebookMenu: some View {
        Menu {
            ForEach(notebooks) { nb in
                Button(nb.title) { pickedNotebookId = nb.id }
            }
        } label: {
            HStack(spacing: 6) {
                Text("notebook")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.foregroundSubtle)
                Text(notebookName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.foregroundSubtle)
            }
        }
        .disabled(notebooks.isEmpty)
    }

    private func destinationChip(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.accent : theme.foreground)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.foregroundSubtle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent : theme.borderSubtle,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived

    private var subjectName: String {
        guard let id = pickedSubjectId,
              let match = subjects.first(where: { $0.id == id })
        else { return subjects.isEmpty ? "no subjects yet" : (subjects.first?.name ?? "—") }
        return match.name
    }

    private var notebookName: String {
        guard let id = pickedNotebookId,
              let match = notebooks.first(where: { $0.id == id })
        else { return notebooks.isEmpty ? "no notebooks yet" : (notebooks.first?.title ?? "—") }
        return match.title
    }

    private var canConfirm: Bool {
        if useNewNotebook { return !subjects.isEmpty }
        return !notebooks.isEmpty
    }

    private var resolvedDestination: ShareImageImporter.Destination {
        if useNewNotebook {
            return .newNotebook(subjectId: pickedSubjectId ?? subjects.first?.id)
        }
        return .existingNotebook(notebookId: pickedNotebookId ?? notebooks.first!.id)
    }

    private func loadPreview() async {
        let url = sourceURL
        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        await MainActor.run { self.preview = image }
    }
}
