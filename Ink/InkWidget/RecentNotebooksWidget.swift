import WidgetKit
import SwiftUI

// MARK: - RecentNotebooksWidget (medium)

struct RecentNotebooksWidget: Widget {
    let kind = "RecentNotebooks"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: InkWidgetProvider()) { entry in
            RecentNotebooksView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Recent Notebooks")
        .description("Last opened notebook plus your three most recent.")
        .supportedFamilies([.systemMedium])
    }
}

struct RecentNotebooksView: View {
    let entry: NotebookEntry

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            // Left: small-widget layout
            ZStack {
                if let nb = entry.primary {
                    Color(hex: nb.coverColorHex)
                    CoverTextureCanvas(texture: nb.coverTexture)
                } else {
                    Color(hex: "#1D1D1B")
                }
                LastOpenedView(entry: entry)
                    .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity)

            // Right: list of recents
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                ForEach(entry.recents.prefix(3), id: \.id) { nb in
                    if let url = URL(string: "ink://open/\(nb.id.uuidString)") {
                        Link(destination: url) { rowFor(nb) }
                    } else {
                        rowFor(nb)
                    }
                }

                if entry.recents.isEmpty {
                    Text("No notebooks yet")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rowFor(_ nb: NotebookSummary) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: nb.coverColorHex))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(nb.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(Self.dateFormatter.localizedString(for: nb.updatedAt, relativeTo: Date()))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }
}
