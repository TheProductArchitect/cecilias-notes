import SwiftUI

/// Slide-down customise panel anchored to the top of the editor. Non-modal:
/// the editor remains visible behind it and updates live as the user picks
/// covers, page sizes, and templates. Direct manipulation — no save/cancel
/// pattern. "Done" or tapping outside the panel dismisses.
///
/// Mounted from `EditorView` as a top-aligned overlay above the toolbar
/// chrome (zIndex above pill / minimap, below modal sheets).
struct CustomisePanel: View {
    @ObservedObject var viewModel: EditorViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titleBuffer: String = ""
    @FocusState private var titleFocused: Bool

    private let coverThumbSize     = CGSize(width: 80,  height: 104)
    private let templateThumbSize  = CGSize(width: 80,  height: 104)

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, Ink.Spacing.lg)
                .padding(.top, Ink.Spacing.md)
                .padding(.bottom, Ink.Spacing.md)
                .background(
                    UnevenRoundedRectangle(
                        cornerRadii: .init(
                            topLeading: 0, bottomLeading: Ink.Radius.lg,
                            bottomTrailing: Ink.Radius.lg, topTrailing: 0
                        ),
                        style: .continuous
                    )
                    .fill(Color.inkBackgroundElevated)
                    .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
                )
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear { titleBuffer = viewModel.notebook.title }
    }

    // MARK: Content sections

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.md) {
            nameSection
            coverSection
            pageSizeSection
            templateSection
            doneRow
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.xs) {
            Text("Name")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)

            TextField("Notebook name", text: $titleBuffer)
                .font(.inkBody)
                .foregroundColor(.inkTextPrimary)
                .submitLabel(.done)
                .focused($titleFocused)
                .padding(.horizontal, Ink.Spacing.sm)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                        .fill(Color.inkBackgroundSecondary)
                )
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.xs) {
            Text("Cover")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(NotebookCover.allCases, id: \.self) { cover in
                        let isSelected = isCurrentCover(cover)
                        CoverThumbView(cover: cover, size: coverThumbSize)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? Color.inkAccentPrimary : Color.clear,
                                        lineWidth: 3
                                    )
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.applyCustomCover(cover)
                            }
                            .accessibilityLabel("Cover \(cover.displayName)")
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var pageSizeSection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.xs) {
            Text("Page Size")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)

            // Native segmented picker — colours match the design system.
            Picker("Page Size", selection: pageSizeBinding) {
                ForEach(PageSize.allCases, id: \.self) { size in
                    Text(size.displayName).tag(size)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.xs) {
            Text("Page Template")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(PageTemplate.defaults, id: \.self) { template in
                        let isSelected = isCurrentTemplate(template)
                        TemplateThumbView(template: template, size: templateThumbSize)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? Color.inkAccentPrimary : Color.inkBorderSubtle,
                                        lineWidth: isSelected ? 3 : 0.5
                                    )
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.applyCustomTemplate(template)
                            }
                            .accessibilityLabel("Template \(template.displayName)")
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var doneRow: some View {
        HStack {
            Spacer()
            InkButton("Done", style: .primary) {
                commitTitle()
                viewModel.closeCustomisePanel()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, Ink.Spacing.xs)
    }

    // MARK: Helpers

    private func commitTitle() {
        viewModel.renameNotebook(titleBuffer)
        // Reflect any normalisation back into the buffer.
        titleBuffer = viewModel.notebook.title
    }

    /// A cover is "selected" if its (colorHex, texture) matches the
    /// notebook's current values. Hex compare is case-insensitive to
    /// match the way colours round-trip through SwiftData.
    private func isCurrentCover(_ cover: NotebookCover) -> Bool {
        cover.colorHex.caseInsensitiveCompare(viewModel.notebook.coverColorHex) == .orderedSame
            && cover.texture == viewModel.notebook.coverTexture
    }

    private func isCurrentTemplate(_ template: PageTemplate) -> Bool {
        template == viewModel.notebook.defaultTemplate
    }

    private var pageSizeBinding: Binding<PageSize> {
        Binding(
            get: { viewModel.notebook.pageSize },
            set: { viewModel.applyCustomPageSize($0) }
        )
    }
}

// MARK: - PageTemplate display helpers

extension PageTemplate {
    fileprivate var displayName: String {
        switch self {
        case .blank:     return "Blank"
        case .lined:     return "Lines"
        case .grid:      return "Grid"
        case .dotGrid:   return "Dotted"
        case .cornell:   return "Cornell"
        case .music:     return "Music"
        }
    }
}
