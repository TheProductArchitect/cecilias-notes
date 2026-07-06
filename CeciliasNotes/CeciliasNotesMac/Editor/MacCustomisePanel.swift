import SwiftData
import SwiftUI

/// Slide-down customise panel for Mac — mirrors iPad `CustomisePanel`
/// sections without `EditorViewModel`.
struct MacCustomisePanel: View {
    @Bindable var notebook: Notebook
    @ObservedObject var state: MacLibraryState
    @ObservedObject var libraryVM: LibraryViewModel
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storage: StorageService

    @State private var titleBuffer = ""
    @FocusState private var titleFocused: Bool
    @State private var isAddingTag = false
    @State private var tagBuffer = ""
    @FocusState private var tagFieldFocused: Bool

    private let thumbSize = CGSize(width: 52, height: 68)

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    nameSection
                    coverSection
                    pageSizeSection
                    templateSection
                    behaviourSection
                    tagsSection
                    originSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .frame(maxWidth: 560)
        .background(theme.surfaceElevated)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        .onAppear {
            titleBuffer = notebook.title
        }
    }

    private var header: some View {
        HStack {
            Text("customise")
                .font(.system(size: 8, weight: .regular))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveTertiary)
            Spacer()
            Button("done") {
                commitTitle()
                state.closeCustomisePanel(notebook: notebook)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.accent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("name")
            TextField("title", text: $titleBuffer)
                .font(.system(size: 22, weight: .heavy))
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("notebook cover")
            CoverTonePickerView(notebook: notebook) {
                libraryVM.refresh()
            }
        }
    }

    private var pageSizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("page size")
            HStack(spacing: 0) {
                ForEach(Array(PageSize.allCases.enumerated()), id: \.element) { index, size in
                    let isSelected = notebook.pageSize == size
                    Button {
                        MacNotebookCustomization.applyPageSize(size, notebook: notebook, storage: storage)
                        libraryVM.refresh()
                    } label: {
                        Text(size.displayName.lowercased())
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? theme.foreground : theme.recessiveTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < PageSize.allCases.count - 1 {
                        Rectangle()
                            .fill(theme.hairline)
                            .frame(width: 0.5, height: 18)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
        }
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("page template")
            ForEach(TemplateCategory.allCases, id: \.self) { category in
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.displayName)
                        .font(.system(size: 9).italic())
                        .foregroundStyle(theme.recessiveQuaternary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(PageTemplate.allCases.filter { $0.category == category }, id: \.self) { template in
                                templateThumb(template)
                            }
                        }
                    }
                }
            }
            Text("applies to pages added after this")
                .font(.system(size: 9).italic())
                .foregroundStyle(theme.recessiveQuaternary)
        }
    }

    private func templateThumb(_ template: PageTemplate) -> some View {
        let isSelected = notebook.defaultTemplate == template
        return Button {
            MacNotebookCustomization.applyDefaultTemplate(template, notebook: notebook, storage: storage)
            libraryVM.refresh()
        } label: {
            VStack(spacing: 4) {
                MacTemplateBackground(template: template, theme: theme)
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isSelected ? theme.accent : theme.hairline, lineWidth: isSelected ? 1.5 : 0.5)
                    )
                Text(template.displayName)
                    .font(.system(size: 8).italic())
                    .foregroundStyle(theme.recessiveQuaternary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("behaviour")
                .padding(.bottom, 4)
            toggleRow(
                label: "auto-add pages",
                isOn: Binding(
                    get: { notebook.autoAddPagesOnScroll },
                    set: { notebook.autoAddPagesOnScroll = $0 }
                )
            )
            toggleRow(
                label: "auto-hide top bar",
                isOn: Binding(
                    get: { notebook.autoHideHeader },
                    set: {
                        notebook.autoHideHeader = $0
                        state.notifyAutoHidePreferenceChanged(notebook: notebook)
                    }
                )
            )
            Text("auto-add: new page when scrolling near bottom · auto-hide: hides toolbar while writing")
                .font(.system(size: 10))
                .foregroundStyle(theme.recessiveTertiary)
                .padding(.top, 6)
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("tags")
            FlowLayout(spacing: 6) {
                ForEach(notebook.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.recessiveQuinary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if isAddingTag {
                    TextField("tag", text: $tagBuffer)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 80)
                        .focused($tagFieldFocused)
                        .onSubmit { commitTag() }
                } else {
                    Button {
                        isAddingTag = true
                        tagFieldFocused = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var originSection: some View {
        NotebookOriginInfoView(notebook: notebook)
    }

    private func toggleRow(label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(theme.foreground)
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(theme.accent)
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
    }

    private func commitTitle() {
        MacNotebookCustomization.rename(notebook, title: titleBuffer, storage: storage)
        titleBuffer = notebook.title
        libraryVM.refresh()
    }

    private func commitTag() {
        let trimmed = tagBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !notebook.tags.contains(trimmed) else {
            tagBuffer = ""
            isAddingTag = false
            return
        }
        var tags = notebook.tags
        tags.append(trimmed)
        try? storage.updateNotebook(notebook, title: nil, coverColorHex: nil, isPinned: nil, tags: tags)
        tagBuffer = ""
        isAddingTag = false
        libraryVM.refresh()
    }
}

/// Simple horizontal flow for tag chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int]
        var height: CGFloat
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row(indices: [], height: 0)
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [], height: 0)
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
