import SwiftUI

/// Half-height sheet of every unique tag in the current library
/// context. Multi-select with checkmark rows; "clear" wipes the
/// active filter set. Session-only — `LibraryView` drops the filter
/// state when the app backgrounds, so this sheet always reopens with
/// whatever was last selected this session.
struct TagFilterSheet: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let tags = viewModel.availableTagsInCurrentContext()

            Group {
                if tags.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Text("no tags yet")
                            .font(.system(size: 13).italic())
                            .foregroundStyle(Color.inkRecessiveTertiary)
                        Text("add tags from a notebook's customise panel.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.inkRecessiveTertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(tags, id: \.self) { tag in
                                tagRow(tag)
                                InkDivider().padding(.leading, 20)
                            }
                        }
                    }
                }
            }
            .navigationTitle("filter by tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.isTagFilterActive {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("clear") {
                            viewModel.clearTagFilters()
                        }
                        .foregroundStyle(Color.brandAccent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") { dismiss() }
                        .foregroundStyle(Color.brandAccent)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func tagRow(_ tag: String) -> some View {
        let isOn = viewModel.activeTagFilters.contains(tag)
        return Button {
            viewModel.toggleTagFilter(tag)
        } label: {
            HStack {
                Text(tag)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.inkTextPrimary)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.brandAccent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
