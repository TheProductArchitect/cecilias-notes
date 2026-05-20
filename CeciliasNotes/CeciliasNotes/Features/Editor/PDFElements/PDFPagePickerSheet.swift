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

    let sourceURL: URL
    /// Called when the user confirms with at least one page picked.
    /// Carries the 0-indexed page indices in click order.
    let onConfirm: ([Int]) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var document: PDFDocument?
    @State private var pageCount: Int = 0
    @State private var selectedPages: [Int] = []
    @State private var jumpToInput: String = "1"
    @State private var thumbnailCache: [Int: UIImage] = [:]
    @State private var scrollTargetPage: Int?

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
                onConfirm(selectedPages)
            }
            .foregroundStyle(selectedPages.isEmpty ? theme.foregroundSubtle : theme.accent)
            .disabled(selectedPages.isEmpty)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.lg)
        .padding(.vertical, CeciliasNotes.Spacing.md)
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
            if !selectedPages.isEmpty {
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
