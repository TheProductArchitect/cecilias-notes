import AppKit
import SwiftUI

/// Mac recent exports — backed by the shared `ExportManifest` (same as iPad).
struct MacRecentExportsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var records: [ExportRecord] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if records.isEmpty {
                emptyState
            } else {
                List(records) { record in
                    exportRow(record)
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("recent exports")
                    .font(.system(size: 8, weight: .regular))
                    .tracking(0.12)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.recessiveTertiary)
                Text(MacExportResult.exportsFolderLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.foregroundSubtle)
            }
            Spacer()
            Button("Open Exports folder") {
                MacExportReveal.openExportsFolder()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.foregroundSubtle)
            Text("No exports yet")
                .foregroundStyle(theme.foregroundMuted)
            Text("Export a notebook from the editor — files appear here and in the Exports folder.")
                .font(.system(size: 11))
                .foregroundStyle(theme.foregroundSubtle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportRow(_ record: ExportRecord) -> some View {
        HStack(spacing: 10) {
            Button {
                if record.fileExists {
                    MacExportReveal.showInFinder(record.fileURL)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: record.fileExists ? "doc.richtext" : "doc.badge.exclamationmark")
                        .foregroundStyle(record.fileExists ? theme.accent : theme.foregroundSubtle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.notebookTitle)
                            .lineLimit(1)
                        Text("\(record.formattedDate) · \(record.formattedSize) · \(record.pageCount) pages")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.foregroundMuted)
                        Text(MacExportResult.friendlyPath(for: record.fileURL))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.recessiveTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if record.fileExists {
                        Image(systemName: "folder")
                            .foregroundStyle(theme.foregroundSubtle)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!record.fileExists)
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        isLoading = true
        await ExportManifest.shared.refresh()
        records = await ExportManifest.shared.loadedRecords()
        isLoading = false
    }
}
