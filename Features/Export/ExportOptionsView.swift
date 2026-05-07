import SwiftUI

// MARK: - ExportOptionsView

/// .medium detent sheet. Shows options, live preview, and starts export.
/// Transitions in-place to ExportProgressView without dismissing the sheet.
struct ExportOptionsView: View {

    let notebook:     Notebook
    let pages:        [Page]
    let currentIndex: Int
    let onDismiss:    () -> Void

    @State private var options          = ExportOptions()
    @State private var customRange      = ""
    @State private var rangeError:      String?    = nil
    @State private var previewImage:    UIImage?   = nil
    @State private var previewTask:     Task<Void, Never>? = nil
    @State private var exportState:     ExportViewState = .options
    @State private var exportProgress:  Double     = 0
    @State private var exportResult:    ExportResult?  = nil
    @State private var exportError:     String?    = nil
    @State private var exportTask:      Task<Void, Never>? = nil

    private var firstPage: Page? { pages.first }

    var body: some View {
        NavigationStack {
            Group {
                switch exportState {
                case .options:    optionsContent
                case .exporting:  progressContent
                case .success:    successContent
                case .error:      errorContent
                }
            }
            .navigationTitle(exportState == .options ? "Export PDF" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if exportState == .options {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onDismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear { schedulePreview() }
        .onChange(of: options.quality)    { _, _ in schedulePreview() }
        .onChange(of: options.pageRange)  { _, _ in schedulePreview() }
        .onChange(of: options.includeCoverPage) { _, _ in schedulePreview() }
        .onDisappear { previewTask?.cancel(); exportTask?.cancel() }
    }

    // MARK: - Options content

    private var optionsContent: some View {
        ScrollView {
            VStack(spacing: Ink.Spacing.lg) {
                previewSection
                pageRangeSection
                qualitySection
                togglesSection
                exportButton
            }
            .padding(Ink.Spacing.lg)
        }
    }

    // MARK: - Preview thumbnail

    private var previewSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Ink.Radius.md, style: .continuous)
                .fill(Color.inkBackgroundSecondary)
                .frame(height: 140)

            if let img = previewImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
                    )
                    .transition(.opacity.animation(.inkSpring(InkSpring.precise)))
            } else {
                ProgressView()
                    .tint(.inkAccentPrimary)
            }
        }
    }

    // MARK: - Page range

    private var pageRangeSection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            sectionHeader("Pages")

            Picker("Page range", selection: Binding(
                get: { rangeTag },
                set: { applyRangeTag($0) }
            )) {
                Text("All").tag(0)
                Text("Current").tag(1)
                Text("Custom").tag(2)
            }
            .pickerStyle(.segmented)

            if rangeTag == 2 {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("e.g. 1–5, 8, 12", text: $customRange)
                        .font(.inkBody)
                        .keyboardType(.numbersAndPunctuation)
                        .padding(Ink.Spacing.sm)
                        .background(Color.inkBackgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                                .stroke(rangeError != nil ? Color.red : Color.inkBorderSubtle, lineWidth: 0.5)
                        )
                        .onChange(of: customRange) { _, v in validateCustomRange(v) }

                    if let err = rangeError {
                        Text(err)
                            .font(.inkCaption)
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }

    // MARK: - Quality

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            sectionHeader("Quality")

            Picker("Quality", selection: $options.quality) {
                Text("Standard (150 dpi)").tag(ExportQuality.standard)
                Text("High (300 dpi)").tag(ExportQuality.high)
            }
            .pickerStyle(.segmented)

            Text("Estimated size: \(estimatedSizeLabel)")
                .font(.inkCaption)
                .foregroundColor(.inkTextSecondary)
        }
    }

    // MARK: - Toggles

    private var togglesSection: some View {
        VStack(spacing: 0) {
            toggleRow("Include page numbers", systemImage: "number", value: $options.includePageNumbers)
            InkDivider()
            toggleRow("Include cover page",   systemImage: "doc.richtext",    value: $options.includeCoverPage)
            InkDivider()
            toggleRow("Include audio transcripts", systemImage: "waveform",   value: $options.includeTranscriptions)
        }
        .inkCard()
    }

    // MARK: - Export button

    private var exportButton: some View {
        InkButton("Export PDF", style: .primary) {
            guard rangeError == nil else { return }
            startExport()
        }
        .frame(maxWidth: .infinity)
        .disabled(rangeError != nil)
    }

    // MARK: - Progress content

    private var progressContent: some View {
        VStack(spacing: Ink.Spacing.xl) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.inkBackgroundSecondary, lineWidth: 4)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: exportProgress)
                    .stroke(Color.inkAccentPrimary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.inkSpring(InkSpring.smooth), value: exportProgress)

                Text("\(Int(exportProgress * 100))%")
                    .font(.inkCaption)
                    .foregroundColor(.inkTextSecondary)
                    .monospacedDigit()
            }

            Text(progressLabel)
                .font(.inkBody)
                .foregroundColor(.inkTextSecondary)
                .monospacedDigit()

            Button("Cancel") {
                exportTask?.cancel()
                withAnimation(.inkSpring(InkSpring.smooth)) {
                    exportState = .options
                }
            }
            .buttonStyle(.plain)
            .font(.inkSubhead)
            .foregroundColor(.inkTextTertiary)

            Spacer()
        }
        .padding(Ink.Spacing.lg)
    }

    // MARK: - Success content

    private var successContent: some View {
        VStack(spacing: Ink.Spacing.lg) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.inkAccentPrimary)
                .inkAnimation(InkSpring.snappy, value: exportState == .success)

            if let result = exportResult {
                VStack(spacing: 4) {
                    Text("Export complete")
                        .font(.inkHeadline)
                        .foregroundColor(.inkTextPrimary)
                    Text("\(result.pageCount) pages · \(ByteCountFormatter.string(fromByteCount: result.fileSizeBytes, countStyle: .file))")
                        .font(.inkSubhead)
                        .foregroundColor(.inkTextSecondary)
                }

                VStack(spacing: Ink.Spacing.sm) {
                    InkButton("Share…", style: .primary) {
                        shareResult(result)
                    }
                    .frame(maxWidth: .infinity)

                    InkButton("Save to Files…", style: .secondary) {
                        saveToFiles(result)
                    }
                    .frame(maxWidth: .infinity)

                    Button("Done") { onDismiss() }
                        .buttonStyle(.plain)
                        .font(.inkSubhead)
                        .foregroundColor(.inkTextTertiary)
                }
            }

            Spacer()
        }
        .padding(Ink.Spacing.lg)
    }

    // MARK: - Error content

    private var errorContent: some View {
        VStack(spacing: Ink.Spacing.lg) {
            Spacer()

            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text(exportError ?? "Export failed.")
                .font(.inkBody)
                .foregroundColor(.inkTextSecondary)
                .multilineTextAlignment(.center)

            InkButton("Try Again", style: .primary) {
                withAnimation(.inkSpring(InkSpring.smooth)) {
                    exportState = .options
                }
            }
            .frame(maxWidth: .infinity)

            Button("Cancel") { onDismiss() }
                .buttonStyle(.plain)
                .font(.inkSubhead)
                .foregroundColor(.inkTextTertiary)

            Spacer()
        }
        .padding(Ink.Spacing.lg)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.inkSubhead)
            .foregroundColor(.inkTextSecondary)
    }

    private func toggleRow(_ label: String, systemImage: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Label(label, systemImage: systemImage)
                .font(.inkBody)
                .foregroundColor(.inkTextPrimary)
        }
        .toggleStyle(.switch)
        .tint(.inkAccentPrimary)
        .padding(.horizontal, Ink.Spacing.md)
        .padding(.vertical, Ink.Spacing.sm)
    }

    // MARK: - Range tag <-> ExportOptions sync

    private var rangeTag: Int {
        switch options.pageRange {
        case .all:     return 0
        case .current: return 1
        case .range:   return 2
        }
    }

    private func applyRangeTag(_ tag: Int) {
        switch tag {
        case 0:  options.pageRange = .all
        case 1:  options.pageRange = .current(currentIndex)
        default: validateCustomRange(customRange)
        }
    }

    private func validateCustomRange(_ input: String) {
        let result = parsePageRange(input, total: pages.count)
        switch result {
        case .success(let r):
            options.pageRange = .range(r)
            rangeError = nil
        case .failure(let msg):
            rangeError = msg
        }
    }

    /// Parses "1-5, 8, 12" → ClosedRange using the union. Only contiguous union supported; for
    /// non-contiguous we use the min…max span as a conservative approximation.
    private func parsePageRange(_ input: String, total: Int) -> Result<ClosedRange<Int>, String> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("Enter a page range.") }

        var pages: [Int] = []
        for part in trimmed.components(separatedBy: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.contains("-") {
                let bounds = p.components(separatedBy: "-")
                guard bounds.count == 2,
                      let lo = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
                      let hi = Int(bounds[1].trimmingCharacters(in: .whitespaces)),
                      lo >= 1, hi <= total, lo <= hi
                else { return .failure("Invalid range "\(p)". Pages are 1–\(total).") }
                pages.append(contentsOf: lo...hi)
            } else {
                guard let n = Int(p), n >= 1, n <= total
                else { return .failure("Page \(p) is out of range (1–\(total)).") }
                pages.append(n)
            }
        }
        guard let lo = pages.min(), let hi = pages.max() else {
            return .failure("Enter a page range.")
        }
        return .success(lo...hi)
    }

    // MARK: - Estimated size

    private var estimatedSizeLabel: String {
        guard let first = firstPage else { return "—" }
        let bounds  = CGRect(origin: .zero, size: first.pageSize.pointSize)
        let indices = options.pageRange.resolve(totalPages: pages.count)
        let bytes   = options.quality.estimatedSizeBytes(pageBounds: bounds, pageCount: max(1, indices.count))
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Progress label

    @State private var completedPages = 0
    private var progressLabel: String {
        let total = options.pageRange.resolve(totalPages: pages.count).count
        return "Exporting… \(completedPages) / \(total) pages"
    }

    // MARK: - Preview

    private func schedulePreview() {
        previewTask?.cancel()
        previewImage = nil
        guard let page = firstPage else { return }
        let opts = options
        let nb   = notebook
        previewTask = Task.detached(priority: .userInitiated) {
            let img = await ExportService.shared.renderPreviewThumbnail(
                page: page, notebook: nb, options: opts, size: CGSize(width: 200, height: 260)
            )
            await MainActor.run { [weak previewTask = previewTask] in
                guard !(previewTask?.isCancelled ?? true) else { return }
                withAnimation { previewImage = img }
            }
        }
    }

    // MARK: - Export

    private func startExport() {
        completedPages = 0
        withAnimation(.inkSpring(InkSpring.smooth)) { exportState = .exporting }
        let nb   = notebook
        let pgs  = pages
        let opts = options
        exportTask = Task {
            do {
                let result = try await ExportService.shared.exportNotebook(
                    nb, pages: pgs, options: opts
                ) { prog in
                    Task { @MainActor in
                        exportProgress  = prog
                        completedPages  = Int(prog * Double(opts.pageRange.resolve(totalPages: pgs.count).count))
                    }
                }
                await MainActor.run {
                    exportResult = result
                    withAnimation(.inkSpring(InkSpring.snappy)) { exportState = .success }
                }
            } catch is CancellationError {
                // user cancelled — already transitioned back
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    withAnimation(.inkSpring(InkSpring.smooth)) { exportState = .error }
                }
            }
        }
    }

    // MARK: - Sharing

    private func shareResult(_ result: ExportResult) {
        let vc = UIActivityViewController(activityItems: [result.fileURL], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?
            .rootViewController?.present(vc, animated: true)
    }

    private func saveToFiles(_ result: ExportResult) {
        let picker = UIDocumentPickerViewController(forExporting: [result.fileURL])
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?
            .rootViewController?.present(picker, animated: true)
    }
}

// MARK: - ExportViewState

enum ExportViewState: Equatable {
    case options
    case exporting
    case success
    case error
}
