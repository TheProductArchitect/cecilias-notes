import AppKit
import SwiftUI

struct MacExportSheet: View {
    let notebook: Notebook?
    @ObservedObject var state: MacLibraryState
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storageService: StorageService
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var successPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2)
            Picker("Format", selection: $state.exportFormat) {
                ForEach(MacExportFormat.allCases, id: \.self) { format in
                    Text(format.label).tag(format)
                }
            }
            .pickerStyle(.radioGroup)

            if let successPath {
                Text("Saved to \(successPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }

            HStack {
                if notebook != nil {
                    Button("Print…") { printNotebook() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export") { export() }
                    .disabled(notebook == nil || isExporting)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func export() {
        guard let notebook else { return }
        isExporting = true
        errorMessage = nil
        successPath = nil
        let pages = storageService.fetchPages(in: notebook)
        Task {
            do {
                let url = try await MacExportService.export(
                    notebook: notebook,
                    pages: pages,
                    format: state.exportFormat,
                    storage: storageService
                )
                await MainActor.run {
                    successPath = url.path
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }

    private func printNotebook() {
        guard let notebook else { return }
        let pages = storageService.fetchPages(in: notebook)
        Task {
            guard let first = pages.first,
                  let image = await MacExportService.renderPage(
                    first, notebook: notebook, storage: storageService, scale: 2
                  ) else { return }
            await MainActor.run {
                let printInfo = NSPrintInfo.shared
                let operation = NSPrintOperation(view: NSImageView(image: image), printInfo: printInfo)
                operation.run()
            }
        }
    }
}
