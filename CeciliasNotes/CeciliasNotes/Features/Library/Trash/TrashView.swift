import SwiftUI

/// Library-area surface that replaces the notebook grid while
/// `LibraryViewModel.isShowingTrash == true`. Lists every soft-
/// deleted record across subjects, folders, notebooks, pages, and
/// page elements with restore + permanent-delete affordances per
/// row, plus an "Empty Trash" action in the header.
struct TrashView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.theme) private var theme

    @State private var items: [TrashItem] = []
    @State private var pendingPermanentDelete: TrashItem?
    @State private var showEmptyTrashConfirmation: Bool = false
    @State private var refreshTick: Int = 0

    private let service = TrashService.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.hairline)
            if items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(theme.background)
        .onAppear { reload() }
        .alert(
            "Permanently delete \"\(pendingPermanentDelete?.displayName ?? "")\"?",
            isPresented: Binding(
                get: { pendingPermanentDelete != nil },
                set: { if !$0 { pendingPermanentDelete = nil } }
            ),
            presenting: pendingPermanentDelete
        ) { item in
            Button("Delete forever", role: .destructive) {
                permanentlyDelete(item)
            }
            Button("Cancel", role: .cancel) {
                pendingPermanentDelete = nil
            }
        } message: { _ in
            Text("This cannot be undone.")
        }
        .alert(
            "Empty trash?",
            isPresented: $showEmptyTrashConfirmation
        ) {
            Button("Empty", role: .destructive) { emptyTrash() }
            Button("Cancel", role: .cancel) { }
        } message: {
            let n = items.count
            Text("\(n) item\(n == 1 ? "" : "s") will be permanently deleted. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("trash")
                .font(.system(size: 22, weight: .regular).italic())
                .foregroundStyle(theme.foreground)

            Spacer()

            Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(theme.foregroundSubtle)
                .monospacedDigit()
                .padding(.trailing, CeciliasNotes.Spacing.md)

            Button {
                showEmptyTrashConfirmation = true
            } label: {
                Text("Empty Trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(items.isEmpty ? theme.recessiveQuaternary : theme.danger)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                items.isEmpty ? theme.recessiveQuinary : theme.danger,
                                lineWidth: 0.5
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(items.isEmpty)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.lg)
        .padding(.vertical, CeciliasNotes.Spacing.md)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    TrashRow(
                        item: item,
                        onRestore: { restore(item) },
                        onPermanentDelete: { pendingPermanentDelete = item }
                    )
                    Divider()
                        .background(theme.hairline)
                        .padding(.leading, CeciliasNotes.Spacing.lg)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: CeciliasNotes.Spacing.md) {
            Spacer()
            Image(systemName: "trash")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(theme.recessiveTertiary)
            Text("Trash is empty")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(theme.foreground)
            Text("Deleted items will appear here.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(theme.foregroundSubtle)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func reload() {
        items = service.fetchAll()
        viewModel.refreshTrashCount()
    }

    private func restore(_ item: TrashItem) {
        do {
            try service.restore(item)
            HapticManager.shared.notebookCreated()
            reload()
            viewModel.refresh()
        } catch {
            viewModel.error = .storageFailed(action: "restore", underlying: error)
        }
    }

    private func permanentlyDelete(_ item: TrashItem) {
        do {
            try service.permanentlyDelete(item)
            HapticManager.shared.destructiveConfirmed()
            pendingPermanentDelete = nil
            reload()
            viewModel.refresh()
        } catch {
            viewModel.error = .storageFailed(action: "delete", underlying: error)
        }
    }

    private func emptyTrash() {
        do {
            try service.emptyTrash()
            HapticManager.shared.destructiveConfirmed()
            reload()
            viewModel.refresh()
        } catch {
            viewModel.error = .storageFailed(action: "empty trash", underlying: error)
        }
    }
}

// MARK: - Row

private struct TrashRow: View {
    let item: TrashItem
    let onRestore: () -> Void
    let onPermanentDelete: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: CeciliasNotes.Spacing.md) {
            Image(systemName: item.iconSystemName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(theme.recessiveSecondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.context)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(theme.foregroundSubtle)
                        .lineLimit(1)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.recessiveQuaternary)
                    Text(relativeTime(item.deletedAt))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(theme.foregroundSubtle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button(action: onRestore) {
                    Text("Restore")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(theme.accent.opacity(0.4), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onPermanentDelete) {
                    Text("Delete Forever")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.danger)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(theme.danger.opacity(0.4), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CeciliasNotes.Spacing.lg)
        .padding(.vertical, CeciliasNotes.Spacing.md)
        .contextMenu {
            Button("Restore", action: onRestore)
            Button("Delete Forever", role: .destructive, action: onPermanentDelete)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
