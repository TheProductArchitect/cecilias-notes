import SwiftUI

/// Half-height sheet of every unique tag in the current library
/// context. Multi-select with checkmark rows; "clear" wipes the
/// active filter set. Session-only — `LibraryView` drops the filter
/// state when the app backgrounds, so this sheet always reopens with
/// whatever was last selected this session.
struct TagFilterSheet: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            let tags = viewModel.availableTagsInCurrentContext()

            Group {
                if tags.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Text("no tags yet")
                            .font(.system(size: 13).italic())
                            .foregroundStyle(theme.recessiveTertiary)
                        Text("add tags from a notebook's customise panel.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.recessiveTertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(tags, id: \.self) { tag in
                                tagRow(tag)
                                CeciliasNotesDivider().padding(.leading, 20)
                            }
                        }
                    }
                }
            }
            .navigationTitle("filter by tag")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.isTagFilterActive {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("clear") {
                            viewModel.clearTagFilters()
                        }
                        .foregroundStyle(theme.accent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
            #else
            // macOS toolbar placements are different from iOS. `.cancellationAction`
            // routes to the leading edge, `.confirmationAction` to trailing —
            // same visual layout as iPad without needing the iOS-only
            // `topBarLeading` / `topBarTrailing` cases.
            .toolbar {
                if viewModel.isTagFilterActive {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("clear") {
                            viewModel.clearTagFilters()
                        }
                        .foregroundStyle(theme.accent)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func tagRow(_ tag: String) -> some View {
        let isOn = viewModel.activeTagFilters.contains(tag)
        return Button {
            viewModel.toggleTagFilter(tag)
        } label: {
            HStack {
                Text(tag)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.foreground)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
