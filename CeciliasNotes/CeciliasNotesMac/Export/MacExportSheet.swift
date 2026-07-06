import AppKit
import SwiftUI

struct MacExportSheet: View {
    let notebook: Notebook?
    @ObservedObject var state: MacLibraryState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storageService: StorageService

    @State private var phase: Phase = .options

    private enum Phase: Equatable {
        case options
        case exporting
        case success(MacExportResult)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .options:
                optionsView
            case .exporting:
                exportingView
            case .success(let result):
                successView(result)
            case .failure(let message):
                failureView(message)
            }
        }
        .frame(width: 440)
        .padding(24)
    }

    // MARK: - Options

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export notebook")
                .font(.title3.weight(.semibold))

            Text("Exports are saved to \(MacExportResult.exportsFolderLabel) so you can find them again from Recent Exports in the library.")
                .font(.system(size: 11))
                .foregroundStyle(theme.foregroundSubtle)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Format", selection: $state.exportFormat) {
                ForEach(MacExportFormat.allCases, id: \.self) { format in
                    Text(format.label).tag(format)
                }
            }
            .pickerStyle(.radioGroup)

            HStack {
                if notebook != nil {
                    Button("Print…") { printNotebook() }
                        .buttonStyle(.plain)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { startExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(notebook == nil)
            }
        }
    }

    // MARK: - Exporting

    private var exportingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Exporting…")
                .font(.headline)
            Text("Rendering \(notebook?.title ?? "notebook")")
                .font(.caption)
                .foregroundStyle(theme.foregroundMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    // MARK: - Success

    private func successView(_ result: MacExportResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Export complete")
                        .font(.headline)
                    Text("\(result.pageCount) pages · \(result.formattedSize) · \(result.formatLabel)")
                        .font(.caption)
                        .foregroundStyle(theme.foregroundMuted)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(result.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Text(MacExportResult.exportsFolderLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.foregroundSubtle)
                Text(result.friendlyPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.recessiveTertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(spacing: 8) {
                Button {
                    MacExportReveal.showInFinder(result.url)
                } label: {
                    Label(
                        result.isDirectory ? "Show folder in Finder" : "Show in Finder",
                        systemImage: "folder"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)

                HStack(spacing: 8) {
                    Button {
                        MacExportReveal.openExportsFolder()
                    } label: {
                        Label("Open Exports folder", systemImage: "folder.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        share(url: result.url)
                    } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Failure

    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.danger)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Export failed")
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(theme.foregroundMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Try again") {
                    phase = .options
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    private func startExport() {
        guard let notebook else { return }
        phase = .exporting
        let pages = storageService.fetchPages(in: notebook)
        Task {
            do {
                let result = try await MacExportService.export(
                    notebook: notebook,
                    pages: pages,
                    format: state.exportFormat,
                    storage: storageService
                )
                await MainActor.run {
                    phase = .success(result)
                }
            } catch {
                await MainActor.run {
                    phase = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func printNotebook() {
        guard let notebook else { return }
        MacPrintService.printNotebook(notebook, storage: storageService)
    }

    private func share(url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        if let view = NSApp.keyWindow?.contentView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }
}
