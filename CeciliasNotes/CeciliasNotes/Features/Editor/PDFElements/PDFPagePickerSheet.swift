@preconcurrency import PDFKit
import SwiftUI
import UIKit

/// Custom multi-select page picker for Workflow B (PDF-as-reference).
/// Presented after the user picks a PDF from the document picker
/// via the image tool's long-press menu.
///
/// Layout:
///   • Top bar: Cancel / document title / Done.
///   • Header: "Go to page N of M" jump field.
///   • Grid: lazy thumbnail grid (page index labelled beneath each
///     thumbnail; selected thumbs get accent border + checkmark).
///   • Footer hint with selected-page count.
struct PDFPagePickerSheet: View {

    /// Context the sheet is presented from. Drives the destination
    /// chooser UI — different destinations make sense from inside
    /// an editor vs. from the library (e.g. "on this page" only
    /// applies when there's a current page to embed onto).
    enum Mode {
        /// In-editor: shows after-current-page / on-current-page /
        /// new-notebook chips. New notebook inherits the source
        /// notebook's subject by default.
        case editor
        /// Library (share-inbox or similar): shows existing-notebook
        /// (pick which) / new-notebook (pick which subject) chips.
        case library(subjects: [Subject], notebooks: [Notebook])
    }

    let sourceURL: URL
    /// Called when the user confirms with at least one page picked.
    /// Carries the 0-indexed page indices in click order plus the
    /// chosen import destination.
    let onConfirm: ([Int], PDFReferenceImporter.Destination) -> Void
    let onCancel: () -> Void
    var mode: Mode = .editor

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var document: PDFDocument?
    @State private var pageCount: Int = 0
    @State private var selectedPages: [Int] = []
    @State private var jumpToInput: String = "1"
    @State private var thumbnailCache: [Int: UIImage] = [:]
    @State private var scrollTargetPage: Int?
    /// Destination chooser — defaults to `.afterCurrentPage` for
    /// editor mode, `.newNotebook(nil)` for library mode (see
    /// `.onAppear` initialiser below).
    @State private var destination: PDFReferenceImporter.Destination = .afterCurrentPage
    /// Library-mode pickers: subject (for new notebook) and
    /// notebook (for existing). Seeded from the mode payload on
    /// first appear.
    @State private var librarySubjectId: UUID?
    @State private var libraryNotebookId: UUID?

    private let thumbnailSize = CGSize(width: 110, height: 140)
    private let columns: [GridItem] = Array(
        repeating: GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 12),
        count: 1
    )

    var body: some View {
        VStack(spacing: 0) {
            topBar
            CeciliasNotesDivider()
            if document != nil, pageCount > 0 {
                destinationPicker
                CeciliasNotesDivider()
                jumpField
                CeciliasNotesDivider()
                thumbnailGrid
                CeciliasNotesDivider()
                footerHint
            } else {
                placeholder
            }
        }
        .background(theme.surface.ignoresSafeArea())
        .task { await loadDocument() }
        .onAppear {
            // Seed library-mode defaults from the mode payload so
            // the picker's initial destination is already valid
            // (no unselected dropdowns on first render).
            if case .library(let subjects, let notebooks) = mode {
                librarySubjectId = subjects.first?.id
                libraryNotebookId = notebooks.first?.id
                destination = .newNotebook(subjectId: librarySubjectId)
            }
        }
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
            Button("Done") {
                onConfirm(selectedPages, destination)
            }
            .foregroundStyle(selectedPages.isEmpty ? theme.foregroundSubtle : theme.accent)
            .disabled(selectedPages.isEmpty)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.lg)
        .padding(.vertical, CeciliasNotes.Spacing.md)
    }

    // MARK: - Destination picker

    /// Two surfaces:
    ///   • Editor mode: the three "where do these land" chips
    ///     (after this page / on this page / new notebook).
    ///   • Library mode: existing notebook (with notebook picker)
    ///     vs new notebook (with subject picker).
    @ViewBuilder
    private var destinationPicker: some View {
        switch mode {
        case .editor:
            editorDestinationPicker
        case .library(let subjects, let notebooks):
            libraryDestinationPicker(subjects: subjects, notebooks: notebooks)
        }
    }

    private var editorDestinationPicker: some View {
        HStack(spacing: 8) {
            destinationChip(
                title: "after this page",
                subtitle: "one new page per PDF page",
                value: .afterCurrentPage
            )
            destinationChip(
                title: "on this page",
                subtitle: "embed as elements",
                value: .onCurrentPage
            )
            destinationChip(
                title: "new notebook",
                subtitle: "switches to it after import",
                // In-editor "new notebook" inherits subject from
                // the source notebook (the importer reads
                // `viewModel.notebook.subjectId` when subjectId is
                // nil), so we pass nil here.
                value: .newNotebook(subjectId: nil)
            )
        }
        .padding(.horizontal, CeciliasNotes.Spacing.lg)
        .padding(.vertical, CeciliasNotes.Spacing.sm)
    }

    private func libraryDestinationPicker(
        subjects: [Subject],
        notebooks: [Notebook]
    ) -> some View {
        let isNew: Bool = {
            if case .newNotebook = destination { return true }
            return false
        }()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                destinationChip(
                    title: "new notebook",
                    subtitle: "create one with these pages",
                    value: .newNotebook(subjectId: librarySubjectId)
                )
                destinationChip(
                    title: "existing notebook",
                    subtitle: "append to one you've made",
                    value: libraryNotebookId.map {
                        PDFReferenceImporter.Destination.existingNotebook(notebookId: $0)
                    } ?? .newNotebook(subjectId: librarySubjectId)
                )
            }

            if isNew {
                Menu {
                    // Subject menu lists user-created subjects only.
                    // Notebooks are required to live in a subject, so
                    // we don't surface "Uncategorised" as an option
                    // here — picking it would put the notebook in a
                    // bucket that isn't a real subject.
                    ForEach(subjects) { subject in
                        Button(subject.name) {
                            librarySubjectId = subject.id
                            destination = .newNotebook(subjectId: subject.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("subject")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.foregroundSubtle)
                        Text(librarySubjectName(subjects: subjects))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.foreground)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.foregroundSubtle)
                    }
                }
                .disabled(subjects.isEmpty)
            } else {
                Menu {
                    ForEach(notebooks) { nb in
                        Button(nb.title) {
                            libraryNotebookId = nb.id
                            destination = .existingNotebook(notebookId: nb.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("notebook")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.foregroundSubtle)
                        Text(libraryNotebookName(notebooks: notebooks))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.foreground)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.foregroundSubtle)
                    }
                }
            }
        }
        .padding(.horizontal, CeciliasNotes.Spacing.lg)
        .padding(.vertical, CeciliasNotes.Spacing.sm)
    }

    /// Chip-level "is this chip selected" check that compares
    /// destination *cases* only — the associated values (subjectId
    /// for newNotebook, notebookId for existingNotebook) shouldn't
    /// affect chip highlighting (those live in the dropdown below
    /// the chip, not on the chip itself).
    private func chipsMatch(
        _ a: PDFReferenceImporter.Destination,
        _ b: PDFReferenceImporter.Destination
    ) -> Bool {
        switch (a, b) {
        case (.afterCurrentPage, .afterCurrentPage): return true
        case (.onCurrentPage, .onCurrentPage):       return true
        case (.newNotebook, .newNotebook):           return true
        case (.existingNotebook, .existingNotebook): return true
        default:                                     return false
        }
    }

    private func librarySubjectName(subjects: [Subject]) -> String {
        guard let id = librarySubjectId,
              let match = subjects.first(where: { $0.id == id })
        else { return subjects.isEmpty ? "no subjects yet" : (subjects.first?.name ?? "—") }
        return match.name
    }

    private func libraryNotebookName(notebooks: [Notebook]) -> String {
        guard let id = libraryNotebookId,
              let match = notebooks.first(where: { $0.id == id })
        else { return notebooks.first?.title ?? "—" }
        return match.title
    }

    private func destinationChip(
        title: String,
        subtitle: String,
        value: PDFReferenceImporter.Destination
    ) -> some View {
        let isSelected = chipsMatch(destination, value)
        return Button {
            destination = value
            HapticManager.shared.toolSwitched()
        } label: {
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

    // MARK: - Jump field

    private var jumpField: some View {
        HStack(spacing: CeciliasNotes.Spacing.sm) {
            Text("Go to page")
                .font(.ceciliasNotesBody)
                .foregroundStyle(theme.foregroundMuted)
            TextField("1", text: $jumpToInput)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .frame(width: 56)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.recessiveQuinary)
                )
                .onSubmit { handleJump() }
            Text("of \(pageCount)")
                .font(.ceciliasNotesBody)
                .foregroundStyle(theme.foregroundMuted)
            Spacer()
            Button("Go") { handleJump() }
                .foregroundStyle(theme.accent)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.lg)
        .padding(.vertical, CeciliasNotes.Spacing.sm)
    }

    private func handleJump() {
        guard let raw = Int(jumpToInput.trimmingCharacters(in: .whitespaces)),
              raw >= 1, raw <= pageCount else { return }
        scrollTargetPage = raw - 1
    }

    // MARK: - Thumbnail grid

    private var thumbnailGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        thumbnailCell(for: index)
                            .id(index)
                    }
                }
                .padding(CeciliasNotes.Spacing.lg)
            }
            .onChange(of: scrollTargetPage) { _, newValue in
                guard let target = newValue else { return }
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                scrollTargetPage = nil
            }
        }
    }

    @ViewBuilder
    private func thumbnailCell(for index: Int) -> some View {
        let isSelected = selectedPages.contains(index)
        let selectionIndex = selectedPages.firstIndex(of: index)

        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = thumbnailCache[index] {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(theme.recessiveQuinary)
                            .task { await renderThumbnail(for: index) }
                    }
                }
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            isSelected ? theme.accent : theme.borderSubtle,
                            lineWidth: isSelected ? 2 : 0.5
                        )
                )

                if isSelected {
                    ZStack {
                        Circle().fill(theme.accent)
                            .frame(width: 22, height: 22)
                        if let selectionIndex {
                            Text("\(selectionIndex + 1)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.surface)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(theme.surface)
                        }
                    }
                    .offset(x: -6, y: 6)
                }
            }
            Text("\(index + 1)")
                .font(.ceciliasNotesCaption)
                .foregroundStyle(isSelected ? theme.accent : theme.foregroundMuted)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleSelection(at: index) }
    }

    private func toggleSelection(at index: Int) {
        HapticManager.shared.toolSwitched()
        if let pos = selectedPages.firstIndex(of: index) {
            selectedPages.remove(at: pos)
        } else {
            selectedPages.append(index)
        }
    }

    // MARK: - Footer

    private var footerHint: some View {
        HStack {
            Text(selectedPages.isEmpty
                ? "Tap pages to select"
                : "\(selectedPages.count) page\(selectedPages.count == 1 ? "" : "s") selected")
                .font(.ceciliasNotesCaption)
                .foregroundStyle(theme.foregroundSubtle)
            Spacer()
            // Select all toggles between "select every page" and
            // "deselect every page" so a power user can flip the
            // entire selection without scrolling and tapping each
            // thumbnail individually.
            Button(selectedPages.count == pageCount ? "Deselect All" : "Select All") {
                if selectedPages.count == pageCount {
                    selectedPages.removeAll()
                } else {
                    selectedPages = Array(0..<pageCount)
                }
                HapticManager.shared.toolSwitched()
            }
            .font(.ceciliasNotesCaption)
            .foregroundStyle(theme.accent)
            if !selectedPages.isEmpty && selectedPages.count != pageCount {
                Button("Clear") {
                    selectedPages.removeAll()
                    HapticManager.shared.toolSwitched()
                }
                .font(.ceciliasNotesCaption)
                .foregroundStyle(theme.foregroundMuted)
            }
        }
        .padding(.horizontal, CeciliasNotes.Spacing.lg)
        .padding(.vertical, CeciliasNotes.Spacing.sm)
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        VStack(spacing: CeciliasNotes.Spacing.md) {
            Spacer()
            ProgressView()
            Text("Opening PDF…")
                .font(.ceciliasNotesCaption)
                .foregroundStyle(theme.foregroundSubtle)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - PDF loading

    /// Transfers a freshly-loaded `PDFDocument` out of a detached
    /// task. `PDFDocument` isn't `Sendable`; the document is created
    /// inside the task and handed off exactly once, never shared, so
    /// `@unchecked Sendable` is sound here.
    private struct LoadedPDF: @unchecked Sendable {
        let document: PDFDocument
        let pageCount: Int
    }

    private func loadDocument() async {
        let url = sourceURL
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let loaded: LoadedPDF? = await Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(url: url) else { return nil }
            return LoadedPDF(document: doc, pageCount: doc.pageCount)
        }.value

        await MainActor.run {
            if let loaded {
                self.document = loaded.document
                self.pageCount = loaded.pageCount
            }
        }
    }

    private func renderThumbnail(for index: Int) async {
        guard let document, index < document.pageCount else { return }
        let target = thumbnailSize
        let image: UIImage? = await Task.detached(priority: .background) {
            guard let page = document.page(at: index) else { return nil }
            return page.thumbnail(of: target, for: .mediaBox)
        }.value
        await MainActor.run {
            if let image { thumbnailCache[index] = image }
        }
    }
}
