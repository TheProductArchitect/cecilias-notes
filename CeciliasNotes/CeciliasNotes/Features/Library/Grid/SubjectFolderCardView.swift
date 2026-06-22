import SwiftUI

/// Files-style folder card for a `Subject`, used in the All Subjects
/// grid surface. Visual language matches `FolderCardView` (filled
/// folder glyph + name + count badge) plus a stack-of-notebooks
/// preview that picks the first few notebooks' cover colours and
/// fans them out behind the folder. Gives the All Subjects screen
/// the same "files" feel as the rest of the library.
///
/// Tap behaviour follows the existing AllSubjectsView row:
///   • In selection mode, toggles `viewModel.selectedSubjectIds`.
///   • Otherwise, navigates into the subject (`selectedContext`).
struct SubjectFolderCardView: View {
    let subject: Subject
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.theme) private var theme

    @State private var isHovered = false

    private var isSelected: Bool {
        viewModel.selectedSubjectIds.contains(subject.id)
    }

    private var notebooks: [Notebook] {
        (subject.notebooks ?? []).filter { !$0.isDeleted }
    }

    private var notebookCount: Int { notebooks.count }

    /// Up to three notebooks, oldest first, used for the cover-colour
    /// fan behind the folder glyph. Keeping it stable (oldest first)
    /// avoids the stack reshuffling every time SwiftData rehydrates
    /// the relationship in a different order.
    private var previewNotebooks: [Notebook] {
        notebooks
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: CeciliasNotes.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous)
                    .fill(theme.surface)

                notebookStackPreview

                Image(systemName: notebookCount == 0 ? "folder" : "folder.fill")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(theme.accent.opacity(0.85))
                    .accessibilityHidden(true)

                if notebookCount > 0 {
                    VStack {
                        HStack {
                            Spacer()
                            CeciliasNotesBadge("\(notebookCount)", style: .count)
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
                Text(subject.name.isEmpty ? "untitled subject" : subject.name)
                    .font(.ceciliasNotesSubhead)
                    .foregroundColor(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(countLabel)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.recessiveTertiary)
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
                    viewModel.selectedSubjectIds.remove(subject.id)
                } else {
                    viewModel.selectedSubjectIds.insert(subject.id)
                }
            } else {
                viewModel.selectedContext = .subject(subject.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Subject \(subject.name), \(notebookCount) notebook\(notebookCount == 1 ? "" : "s")")
        .accessibilityAddTraits(.isButton)
    }

    /// Up to three rectangles fanned out behind the folder glyph,
    /// each tinted with one of the subject's notebooks' cover colours.
    /// Stays hidden for empty subjects so the folder glyph reads as
    /// "empty folder" rather than "broken decoration".
    @ViewBuilder
    private var notebookStackPreview: some View {
        if previewNotebooks.isEmpty {
            EmptyView()
        } else {
            ZStack {
                ForEach(Array(previewNotebooks.enumerated()), id: \.element.id) { index, notebook in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(coverColor(for: notebook))
                        .frame(width: 38, height: 50)
                        .rotationEffect(.degrees(Double(index - 1) * 6))
                        .offset(
                            x: CGFloat(index - 1) * 14,
                            y: CGFloat(index) * 2
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
                }
            }
            .offset(y: 24)
            .accessibilityHidden(true)
        }
    }

    private func coverColor(for notebook: Notebook) -> Color {
        guard !notebook.coverColorHex.isEmpty else {
            return theme.accent.opacity(0.35)
        }
        return Color(uiColor: UIColor(hex: notebook.coverColorHex))
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

    private var countLabel: String {
        notebookCount == 1 ? "1 notebook" : "\(notebookCount) notebooks"
    }
}
