import SwiftUI

/// Finder-style Space-bar preview for a notebook in the library grid.
struct MacNotebookQuickLookView: View {
    let notebook: Notebook
    var onOpen: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storageService: StorageService

    @State private var previewImage: PlatformImage?
    @State private var isLoading = true

    private var tone: NotebookCoverTone { notebook.coverTone }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    tone.background
                    GhostLetter(
                        character: notebook.title.first ?? "?",
                        size: 48,
                        onDarkBackground: !tone.isLight
                    )
                    .offset(x: 8, y: 8)
                }
                .frame(width: 72, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(notebook.title)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(theme.foreground)
                    Text("\(notebook.totalPageCount) page\(notebook.totalPageCount == 1 ? "" : "s")")
                        .font(.system(size: 11).italic())
                        .foregroundStyle(theme.foregroundSubtle)
                    if !notebook.tags.isEmpty {
                        Text(notebook.tags.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.recessiveTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let previewImage {
                    #if os(macOS)
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(theme.hairline, lineWidth: 0.5)
                        )
                    #endif
                } else {
                    Text("no preview available")
                        .font(.system(size: 11).italic())
                        .foregroundStyle(theme.recessiveTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 280)

            HStack {
                Spacer()
                Button("Open Notebook") {
                    onOpen()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                Button("Done") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 440, height: 520)
        .background(theme.surfaceElevated)
        .task { await loadPreview() }
    }

    private func loadPreview() async {
        isLoading = true
        defer { isLoading = false }
        let pages = storageService.fetchPages(in: notebook)
            .filter { !$0.isDeleted }
            .sorted { $0.pageNumber < $1.pageNumber }
        guard let first = pages.first else { return }
        previewImage = await MacExportService.renderPage(
            first,
            notebook: notebook,
            storage: storageService,
            scale: 1.2
        )
    }
}
