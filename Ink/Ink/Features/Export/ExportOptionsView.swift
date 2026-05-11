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
    /// Latched segmented-picker selection. Lives independent of
    /// `options.pageRange` so tapping "Custom" with an empty input
    /// still moves the picker — the typed text drives `pageRange`
    /// validation; the tag drives the picker visual.
    @State private var rangeTag:        Int        = 0
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
        // Tall detent so the preview, page-range, quality, toggles
        // and the pinned Export button are all visible at once — the
        // medium detent forced the user to scroll past the toggles.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { schedulePreview() }
        .onChange(of: options.quality)    { _, _ in schedulePreview() }
        .onChange(of: options.pageRange)  { _, _ in schedulePreview() }
        .onChange(of: options.includeCoverPage) { _, _ in schedulePreview() }
        .onDisappear { previewTask?.cancel(); exportTask?.cancel() }
    }

    // MARK: - Options content

    private var optionsContent: some View {
        // Form scrolls; Export button is pinned outside the ScrollView
        // so it stays visible at the medium detent and isn't buried
        // behind the keyboard when editing the custom range.
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Ink.Spacing.lg) {
                    previewSection
                    pageRangeSection
                    qualitySection
                    togglesSection
                }
                .padding(Ink.Spacing.lg)
            }
            Rectangle()
                .fill(Color.inkBorderSubtle)
                .frame(height: 0.5)
            exportButton
                .padding(.horizontal, Ink.Spacing.lg)
                .padding(.vertical, Ink.Spacing.md)
                .background(Color.inkBackgroundPrimary)
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

            Picker("Page range", selection: $rangeTag) {
                Text("All").tag(0)
                Text("Current").tag(1)
                Text("Custom").tag(2)
            }
            .pickerStyle(.segmented)
            .onChange(of: rangeTag) { _, tag in applyRangeTag(tag) }

            if rangeTag == 2 {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("e.g. 1–5, 8, 12", text: $customRange)
                        .font(.inkBody)
                        .keyboardType(.numbersAndPunctuation)
                        .submitLabel(.done)
                        .padding(Ink.Spacing.sm)
                        .background(Color.inkBackgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                                .stroke(rangeError != nil ? Color.inkDestructive : Color.inkBorderSubtle, lineWidth: 0.5)
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
            .buttonStyle(.inkPressable)
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
                        .buttonStyle(.inkPressable)
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
                .buttonStyle(.inkPressable)
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

    private func applyRangeTag(_ tag: Int) {
        switch tag {
        case 0:
            options.pageRange = .all
            rangeError = nil
        case 1:
            options.pageRange = .current(currentIndex)
            rangeError = nil
        default:
            // Switching to "Custom" with no input shouldn't snap the
            // picker back. Latched `rangeTag` keeps the segment on
            // Custom; `validateCustomRange` either parses the typed
            // value into `pageRange` or surfaces a `rangeError` that
            // gates the Export button until valid input is entered.
            validateCustomRange(customRange)
        }
    }

    private func validateCustomRange(_ input: String) {
        do {
            let r = try parsePageRange(input, total: pages.count)
            options.pageRange = .range(r)
            rangeError = nil
        } catch let e as RangeParseError {
            rangeError = e.message
        } catch {
            rangeError = error.localizedDescription
        }
    }

    /// Parses "1-5, 8, 12" → ClosedRange using the union. Only contiguous union supported; for
    /// non-contiguous we use the min…max span as a conservative approximation.
    private func parsePageRange(_ input: String, total: Int) throws -> ClosedRange<Int> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RangeParseError("Enter a page range.") }

        var pages: [Int] = []
        for part in trimmed.components(separatedBy: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.contains("-") {
                let bounds = p.components(separatedBy: "-")
                guard bounds.count == 2,
                      let lo = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
                      let hi = Int(bounds[1].trimmingCharacters(in: .whitespaces)),
                      lo >= 1, hi <= total, lo <= hi
                else { throw RangeParseError("Invalid range \"\(p)\". Pages are 1–\(total).") }
                pages.append(contentsOf: lo...hi)
            } else {
                guard let n = Int(p), n >= 1, n <= total
                else { throw RangeParseError("Page \(p) is out of range (1–\(total)).") }
                pages.append(n)
            }
        }
        guard let lo = pages.min(), let hi = pages.max() else {
            throw RangeParseError("Enter a page range.")
        }
        return lo...hi
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
            guard !Task.isCancelled else { return }
            await MainActor.run {
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
        // `pages` (`[Page]`) isn't Sendable, so capture only the count
        // for the progress closure rather than the whole array.
        let totalPagesCount = pgs.count
        exportTask = Task {
            do {
                let result = try await ExportService.shared.exportNotebook(
                    nb, pages: pgs, options: opts
                ) { prog in
                    Task { @MainActor in
                        exportProgress  = prog
                        completedPages  = Int(prog * Double(opts.pageRange.resolve(totalPages: totalPagesCount).count))
                    }
                }
                await MainActor.run {
                    exportResult = result
                    withAnimation(.inkSpring(InkSpring.snappy)) { exportState = .success }
                    HapticManager.shared.exportCompleted()
                }
            } catch is CancellationError {
                // user cancelled — already transitioned back
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    withAnimation(.inkSpring(InkSpring.smooth)) { exportState = .error }
                    HapticManager.shared.exportFailed()
                }
            }
        }
    }

    // MARK: - Sharing

    private func shareResult(_ result: ExportResult) {
        let vc = UIActivityViewController(activityItems: [result.fileURL], applicationActivities: nil)
        // iPad popover anchor — required, otherwise UIKit raises.
        if let pop = vc.popoverPresentationController,
           let presenter = topmostPresentedViewController() {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0, height: 0
            )
            pop.permittedArrowDirections = []
        }
        topmostPresentedViewController()?.present(vc, animated: true)
    }

    private func saveToFiles(_ result: ExportResult) {
        // `asCopy: true` keeps the source file in place — the previous
        // call moved it, leaving subsequent Share / Save attempts
        // pointing at a missing URL. The picker must be presented
        // from the topmost view controller (this view is itself in a
        // sheet); presenting from `rootViewController` while another
        // sheet is up causes UIKit to silently drop the presentation,
        // which is why Save-to-Files appeared to "go through" without
        // ever showing the Files picker.
        let picker = UIDocumentPickerViewController(
            forExporting: [result.fileURL],
            asCopy: true
        )
        picker.shouldShowFileExtensions = true
        topmostPresentedViewController()?.present(picker, animated: true)
    }

    /// Walks the key window's view-controller hierarchy to the
    /// deepest currently-presented controller. Necessary because this
    /// view is itself inside a sheet — presenting from the root
    /// view-controller would attempt to present on a controller that
    /// already has a `presentedViewController`, which UIKit refuses.
    private func topmostPresentedViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: { $0.isKeyWindow })
                ?? scene.windows.first,
              var top = window.rootViewController
        else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - RangeParseError

private struct RangeParseError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - ExportViewState

enum ExportViewState: Equatable {
    case options
    case exporting
    case success
    case error
}
