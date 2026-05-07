import SwiftUI

// MARK: - RecentExportsView

/// Half-height sheet listing the last 10 export records.
/// Presented from the Library's … menu.
struct RecentExportsView: View {

    /// Called when the user wants to re-export a notebook by id.
    let onReExport: (UUID) -> Void

    @State private var records:           [ExportRecord] = []
    @State private var isLoading:         Bool           = true
    @State private var sharingRecord:     ExportRecord?
    @State private var missingRecord:     ExportRecord?
    @State private var showMissingAlert:  Bool           = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if records.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Recent Exports")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task { await load() }
        .sheet(item: $sharingRecord) { record in
            ActivityView(url: record.fileURL)
        }
        .alert("File Not Found", isPresented: $showMissingAlert, presenting: missingRecord) { record in
            Button("Re-export") { onReExport(record.notebookId) }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("The exported file for "\(record.notebookTitle)" no longer exists.")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Ink.Spacing.md) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.inkTextTertiary)
            Text("No exports yet")
                .font(.inkBody)
                .foregroundColor(.inkTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(records) { record in
                row(for: record)
            }
            .onDelete { offsets in
                Task {
                    for idx in offsets {
                        await ExportManifest.shared.delete(id: records[idx].id)
                    }
                    await load()
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(for record: ExportRecord) -> some View {
        Button {
            if record.fileExists {
                sharingRecord = record
            } else {
                missingRecord    = record
                showMissingAlert = true
            }
        } label: {
            HStack(spacing: Ink.Spacing.md) {
                Image(systemName: record.fileExists ? "doc.richtext" : "doc.richtext.fill")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(record.fileExists ? .inkAccentPrimary : .inkTextTertiary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.notebookTitle)
                        .font(.inkBody)
                        .foregroundColor(.inkTextPrimary)
                        .lineLimit(1)

                    HStack(spacing: Ink.Spacing.xs) {
                        Text(record.formattedDate)
                        Text("·")
                        Text(record.formattedSize)
                        Text("·")
                        Text("\(record.pageCount) pages")
                    }
                    .font(.inkFootnote)
                    .foregroundColor(.inkTextSecondary)
                }

                Spacer()

                if record.fileExists {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.inkTextTertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        await ExportManifest.shared.refresh()
        records   = await ExportManifest.shared.loadedRecords()
        isLoading = false
    }
}

// MARK: - ActivityView (UIActivityViewController bridge)

struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
