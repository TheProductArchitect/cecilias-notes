import SwiftUI

struct NewNotebookSheet: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    // Form state
    @State private var title: String = ""
    @State private var selectedSubjectId: UUID?
    @State private var coverColorHex: String = InkColorPresets.subjectColors[6]   // #007AFF
    @State private var coverTexture: CoverTexture = .none
    // Defaults read from Settings (`ink.newpage.size`, `ink.newpage.template`).
    @State private var pageSize: PageSize = {
        if let raw = UserDefaults.standard.string(forKey: "ink.newpage.size"),
           let v = PageSize(rawValue: raw) { return v }
        return .a4
    }()
    @State private var selectedTemplate: PageTemplate = {
        if let raw = UserDefaults.standard.string(forKey: "ink.newpage.template"),
           let data = raw.data(using: .utf8),
           let t = try? JSONDecoder().decode(PageTemplate.self, from: data) { return t }
        return .blank
    }()

    @FocusState private var titleFocused: Bool

    private let maxTitle = 80
    private let charWarningThreshold = 60   // show counter when ≤60 chars remain

    private var remainingChars: Int { maxTitle - title.count }
    private var showCharCount: Bool { remainingChars <= charWarningThreshold }
    private var canCreate: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Spacing.xl) {
                    titleSection
                    subjectSection
                    coverColourSection
                    coverTextureSection
                    pageSizeSection
                    templateSection
                }
                .padding(.horizontal, Ink.Spacing.lg)
                .padding(.top, Ink.Spacing.md)
                .padding(.bottom, Ink.Spacing.xl)
            }
            .background(Color.inkBackgroundPrimary)
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.inkTextSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .font(.inkHeadline)
                        .foregroundColor(canCreate ? .inkAccentPrimary : .inkTextTertiary)
                        .disabled(!canCreate)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            selectedSubjectId = viewModel.selectedSubjectId
            titleFocused = true
        }
    }

    // MARK: Sections

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.xs) {
            sectionLabel("Title")
            HStack {
                InkTextField("Untitled", text: $title, maxLength: maxTitle)
                if showCharCount {
                    Text("\(remainingChars)")
                        .font(.inkCaption)
                        .foregroundColor(remainingChars <= 10 ? .inkDestructive : .inkTextTertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var subjectSection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            sectionLabel("Subject")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Ink.Spacing.sm) {
                    subjectPill(id: nil, label: "Uncategorised", colorHex: nil)
                    ForEach(viewModel.subjects) { subject in
                        subjectPill(id: subject.id, label: subject.name, colorHex: subject.colorHex)
                    }
                    // New Subject pill
                    Button {
                        viewModel.createSubject()
                        dismiss()   // user finishes in the sidebar rename
                    } label: {
                        Label("New Subject", systemImage: "plus")
                            .font(.inkFootnote)
                            .foregroundColor(.inkAccentPrimary)
                            .padding(.horizontal, Ink.Spacing.sm)
                            .padding(.vertical, Ink.Spacing.xs)
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.inkAccentPrimary, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
        }
    }

    private var coverColourSection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            sectionLabel("Cover Colour")
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(36), spacing: 10), count: 6),
                spacing: 10
            ) {
                ForEach(InkColorPresets.subjectColors, id: \.self) { hex in
                    Button {
                        withAnimation(.inkAnimation(InkSpring.snappy, value: hex)) {
                            coverColorHex = hex
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(UIColor(hex: hex)))
                                .frame(width: 36, height: 36)
                            if hex == coverColorHex {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var coverTextureSection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            sectionLabel("Texture")
            HStack(spacing: Ink.Spacing.sm) {
                ForEach(CoverTexture.allCases, id: \.self) { texture in
                    Button {
                        withAnimation(.inkAnimation(InkSpring.snappy, value: texture)) {
                            coverTexture = texture
                        }
                    } label: {
                        CoverTexturePreview(
                            texture: texture,
                            isSelected: coverTexture == texture
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var pageSizeSection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            sectionLabel("Page Size")
            segmentedPicker(
                options: PageSize.allCases,
                selected: $pageSize,
                label: \.displayName
            )
        }
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            sectionLabel("Template")
            let templateOptions: [(String, PageTemplate)] = [
                ("Blank",   .blank),
                ("Lined",   .lined(spacing: 32)),
                ("Grid",    .grid(spacing: 24)),
                ("Dots",    .dotGrid(spacing: 24, dotSize: 2)),
                ("Cornell", .cornell),
            ]
            HStack(spacing: Ink.Spacing.xs) {
                ForEach(templateOptions, id: \.0) { name, template in
                    Button {
                        withAnimation(.inkAnimation(InkSpring.snappy, value: name)) {
                            selectedTemplate = template
                        }
                    } label: {
                        Text(name)
                            .font(.inkCaption)
                            .foregroundColor(
                                selectedTemplate == template
                                    ? .inkAccentPrimary
                                    : .inkTextSecondary
                            )
                            .padding(.horizontal, Ink.Spacing.sm)
                            .padding(.vertical, Ink.Spacing.xs)
                            .background(
                                RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                                    .fill(
                                        selectedTemplate == template
                                            ? Color.inkAccentSecondary
                                            : Color.inkBackgroundSecondary
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.inkFootnote)
            .foregroundColor(.inkTextTertiary)
    }

    private func subjectPill(id: UUID?, label: String, colorHex: String?) -> some View {
        let isSelected = selectedSubjectId == id
        return Button {
            withAnimation(.inkAnimation(InkSpring.snappy, value: id)) {
                selectedSubjectId = id
            }
        } label: {
            HStack(spacing: 6) {
                if let hex = colorHex {
                    Circle()
                        .fill(Color(UIColor(hex: hex)))
                        .frame(width: 8, height: 8)
                }
                Text(label)
                    .font(.inkFootnote)
                    .foregroundColor(isSelected ? .inkAccentPrimary : .inkTextSecondary)
            }
            .padding(.horizontal, Ink.Spacing.sm)
            .padding(.vertical, Ink.Spacing.xs)
            .background(
                Capsule()
                    .fill(isSelected ? Color.inkAccentSecondary : Color.inkBackgroundSecondary)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.inkAccentPrimary : Color.clear,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func segmentedPicker<T: Hashable>(
        options: [T],
        selected: Binding<T>,
        label: KeyPath<T, String>
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = selected.wrappedValue == option
                Button {
                    withAnimation(.inkAnimation(InkSpring.precise, value: option)) {
                        selected.wrappedValue = option
                    }
                } label: {
                    Text(option[keyPath: label])
                        .font(.inkCaption)
                        .foregroundColor(isSelected ? .inkAccentPrimary : .inkTextSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            isSelected
                                ? Color.inkBackgroundElevated
                                : Color.clear
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.inkBackgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                .strokeBorder(Color.inkBorderDefault, lineWidth: 0.5)
        )
    }

    // MARK: Create action

    private func create() {
        guard canCreate else { return }
        viewModel.createNotebook(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            subjectId: selectedSubjectId,
            coverColorHex: coverColorHex,
            coverTexture: coverTexture,
            pageSize: pageSize,
            template: selectedTemplate
        )
        dismiss()
    }
}
