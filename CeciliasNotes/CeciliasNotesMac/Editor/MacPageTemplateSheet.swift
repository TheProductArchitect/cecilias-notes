import SwiftData
import SwiftUI

/// Mac page-template picker — sets notebook default and/or the
/// current page background. Reuses `MacTemplateBackground` previews.
struct MacPageTemplateSheet: View {
    let notebook: Notebook
    let page: Page?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @EnvironmentObject private var storageService: StorageService

    @State private var applyToCurrentPage = true

    private let thumbSize = CGSize(width: 52, height: 68)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("page template")
                .font(.system(size: 8, weight: .regular))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveTertiary)

            Toggle("Apply to current page", isOn: $applyToCurrentPage)
                .disabled(page == nil)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(TemplateCategory.allCases, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.displayName)
                                .font(.system(size: 9).italic())
                                .foregroundStyle(theme.recessiveQuaternary)

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 56), spacing: 10)],
                                spacing: 10
                            ) {
                                ForEach(PageTemplate.allCases.filter { $0.category == category }, id: \.self) { template in
                                    templateButton(template)
                                }
                            }
                        }
                    }
                }
            }

            Text(applyToCurrentPage
                 ? "also sets default for new pages"
                 : "applies to pages added after this")
                .font(.system(size: 9).italic())
                .foregroundStyle(theme.recessiveQuaternary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 420, height: 520)
        .background(theme.surfaceElevated)
    }

    private func templateButton(_ template: PageTemplate) -> some View {
        let isSelected = (page?.backgroundTemplate == template)
            || (page == nil && notebook.defaultTemplate == template)

        return Button {
            apply(template)
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

    private func apply(_ template: PageTemplate) {
        try? storageService.updateNotebook(
            notebook,
            title: nil,
            coverColorHex: nil,
            isPinned: nil,
            tags: nil,
            defaultTemplate: template
        )
        if applyToCurrentPage, let page {
            page.backgroundTemplate = template
            page.updatedAt = Date()
            try? storageService.context.save()
        }
    }
}
