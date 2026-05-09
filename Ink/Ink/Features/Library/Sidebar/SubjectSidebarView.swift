import SwiftUI

struct SubjectSidebarView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @EnvironmentObject private var cloudSync: CloudSyncManager

    var body: some View {
        VStack(spacing: 0) {
            wordmark
            InkDivider()

            List {
                // All Notes — always first, not deletable or reorderable
                AllNotesRow(viewModel: viewModel)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .listRowSeparator(.hidden)

                // Subject rows — drag-reorderable. Folders and notebooks
                // live in the main browser (Files-style) rather than nested
                // here, so this list is intentionally flat.
                ForEach(viewModel.subjects) { subject in
                    SubjectRowView(subject: subject, viewModel: viewModel)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                        // Swipe → reveal Delete on either edge so the
                        // gesture works whether the user swipes left
                        // (iOS Mail-style) or right (the "swipe right
                        // to delete" the user asked for). Tapping the
                        // pill calls through the same flow as the
                        // context-menu Delete: notebooks get moved to
                        // Uncategorised, the subject is soft-deleted.
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                HapticManager.shared.destructiveConfirmed()
                                viewModel.deleteSubject(subject)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                HapticManager.shared.destructiveConfirmed()
                                viewModel.deleteSubject(subject)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .onMove { from, to in
                    viewModel.reorderSubjects(from: from, to: to)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))  // enables onMove without edit UI

            Spacer(minLength: 0)
            InkDivider()
            bottomBar
        }
        .background(Color.inkBackgroundSecondary)
    }

    // MARK: Subviews

    private var wordmark: some View {
        HStack {
            Text("Ink")
                .font(.inkTitle2)
                .foregroundColor(.inkTextPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 0) {
            iCloudStatusView(syncStatus: cloudSync.syncStatus)
                .padding(.leading, 16)
            Spacer()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                InkButton("New Subject", style: .ghost) {
                    viewModel.createSubject()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .offset(y: 56)  // sits just below the iCloud indicator row
        }
        .padding(.bottom, 56)
    }
}

// MARK: - All Notes row

private struct AllNotesRow: View {
    @ObservedObject var viewModel: LibraryViewModel

    private var isSelected: Bool { viewModel.selectedSubjectId == nil }

    var body: some View {
        HStack(spacing: Ink.Spacing.sm) {
            Image(systemName: "folder")
                .fontWeight(.medium)
                .foregroundColor(isSelected ? .inkAccentPrimary : .inkTextSecondary)
                .frame(width: 20)

            Text("All Notes")
                .font(.inkSubhead)
                .foregroundColor(isSelected ? .inkTextPrimary : .inkTextSecondary)

            Spacer()

            InkBadge("\(viewModel.totalNotebookCount)", style: .count)
        }
        .padding(.horizontal, Ink.Spacing.sm)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                .fill(isSelected ? Color.inkBackgroundTertiary : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { viewModel.selectedSubjectId = nil }
        // Accept dropped notebooks → move to Uncategorised
        .dropDestination(for: Data.self) { items, _ in
            var landed = false
            for data in items {
                if let decoded = try? JSONDecoder().decode(NotebookTransferID.self, from: data) {
                    viewModel.moveNotebook(id: decoded.id, to: nil)
                    landed = true
                }
            }
            if landed { HapticManager.shared.dragReorderDropped() }
            return true
        }
    }
}

// MARK: - iCloud status indicator

struct iCloudStatusView: View {
    let syncStatus: CloudSyncManager.SyncStatus

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 14))
            .fontWeight(.medium)
            .foregroundColor(.inkTextTertiary)
            .inkAnimation(InkSpring.smooth, value: symbolName)
    }

    private var symbolName: String {
        switch syncStatus {
        case .disabled:           return "cloud"
        case .checking:           return "arrow.clockwise.icloud"
        case .upToDate:           return "checkmark.icloud"
        case .syncing:            return "arrow.clockwise.icloud"
        case .error:              return "exclamationmark.icloud"
        }
    }
}
