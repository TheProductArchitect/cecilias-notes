import SwiftUI

/// Read-only origin panel — created / last modified device + timestamps.
struct NotebookOriginInfoView: View {
    let notebook: Notebook
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("origin")
                .padding(.bottom, 8)

            originRow(
                eyebrow: "created",
                date: notebook.createdAt,
                device: notebook.createdOnDevice,
                platformRaw: notebook.createdOnPlatform
            )

            hairline

            originRow(
                eyebrow: "last modified",
                date: notebook.updatedAt,
                device: notebook.lastModifiedOnDevice,
                platformRaw: notebook.lastModifiedOnPlatform
            )

            if notebook.isAgentWritten || notebook.sourceInkbookFilename != nil {
                hairline
                provenanceBlock
            }

            if showsMultiDeviceFootnote {
                hairline
                Text("Created and last edited on different devices — changes sync via iCloud.")
                    .font(.system(size: 10).italic())
                    .foregroundStyle(theme.recessiveQuaternary)
                    .padding(.vertical, 10)
            }
        }
    }

    private var showsMultiDeviceFootnote: Bool {
        guard let created = notebook.createdOnPlatform,
              let modified = notebook.lastModifiedOnPlatform,
              !created.isEmpty, !modified.isEmpty else { return false }
        return created != modified
    }

    @ViewBuilder
    private var provenanceBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if notebook.isAgentWritten {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.recessiveTertiary)
                    Text(agentLine)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.foreground)
                }
            }
            if let filename = notebook.sourceInkbookFilename, !filename.isEmpty {
                Text("imported from \(filename)")
                    .font(.system(size: 10).italic())
                    .foregroundStyle(theme.recessiveTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 12)
    }

    private var agentLine: String {
        var parts: [String] = []
        if let name = notebook.agentName, !name.isEmpty {
            parts.append("written by \(name)")
        }
        if let model = notebook.agentModel, !model.isEmpty {
            parts.append(model)
        }
        return parts.isEmpty ? "agent-written" : parts.joined(separator: " · ")
    }

    private func originRow(
        eyebrow: String,
        date: Date,
        device: String?,
        platformRaw: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let platform = NotebookOriginPlatform.from(raw: platformRaw) {
                Image(systemName: platform.systemImage)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(theme.recessiveTertiary)
                    .frame(width: 20)
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.recessiveQuaternary)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow)
                    .font(.system(size: 8))
                    .tracking(0.08)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.recessiveQuaternary)

                Text(NotebookOriginDisplay.formattedDate(date))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.foreground)

                if let location = NotebookOriginDisplay.locationLine(
                    device: device,
                    platformRaw: platformRaw
                ) {
                    Text(location)
                        .font(.system(size: 11).italic())
                        .foregroundStyle(theme.recessiveTertiary)
                } else {
                    Text("device unknown — edited before origin tracking")
                        .font(.system(size: 10).italic())
                        .foregroundStyle(theme.recessiveQuaternary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(height: 0.5)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
    }
}

/// Compact sheet wrapper for library context menu / toolbar.
struct NotebookOriginInfoSheet: View {
    let notebook: Notebook
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("notebook info")
                    .font(.system(size: 8, weight: .regular))
                    .tracking(0.12)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.recessiveTertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            NotebookOriginInfoView(notebook: notebook)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surfaceElevated)
    }
}
