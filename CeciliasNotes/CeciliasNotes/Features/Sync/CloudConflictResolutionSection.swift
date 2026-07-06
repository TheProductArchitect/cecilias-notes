import SwiftUI

/// Settings → Cloud — explains CloudKit LWW and lists recent agent
/// import merges where local edits were preserved.
struct CloudConflictResolutionSection: View {
    @State private var records: [SyncConflictLog.Record] = []
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("conflicts")

            Text("icloud database sync uses last-writer-wins — the newest edit on each field wins automatically. when an external agent ships a notebook while you edited on device, incoming pages merge by id so your work is kept.")
                .font(.system(size: 11))
                .foregroundStyle(theme.foregroundSubtle)
                .fixedSize(horizontal: false, vertical: true)

            if records.isEmpty {
                Text("no recent merge conflicts")
                    .font(.system(size: 12).italic())
                    .foregroundStyle(theme.foregroundSubtle)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { item in
                        conflictRow(item)
                    }
                }
                Button("clear history") {
                    SyncConflictLog.clear()
                    refresh()
                }
                .font(.system(size: 12))
                .foregroundStyle(theme.foregroundMuted)
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .syncConflictLogChanged)) { _ in
            refresh()
        }
    }

    private func conflictRow(_ item: SyncConflictLog.Record) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.notebookTitle)
                .font(.system(size: 13))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
            Text("\(item.sourceFilename) — \(item.resolution)")
                .font(.system(size: 10).italic())
                .foregroundStyle(theme.foregroundSubtle)
                .lineLimit(2)
            Text(relativeDate(item.date))
                .font(.system(size: 10))
                .foregroundStyle(theme.recessiveTertiary)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }

    private func refresh() {
        records = SyncConflictLog.records
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .regular))
            .tracking(0.12)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveTertiary)
    }
}
