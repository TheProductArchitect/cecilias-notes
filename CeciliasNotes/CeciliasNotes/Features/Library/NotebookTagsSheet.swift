import SwiftUI

/// Lightweight tag editor for library context menus (Mac right-click, iPad long-press).
struct NotebookTagsSheet: View {
    @Bindable var notebook: Notebook
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var tagBuffer = ""
    @State private var tagError: String?
    @State private var isAddingTag = false
    @FocusState private var tagFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(notebook.title)
                    .font(.system(size: 17, weight: .heavy))
                    .lineLimit(2)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if notebook.tags.isEmpty && !isAddingTag {
                            Text("add tags")
                                .font(.system(size: 12).italic())
                                .foregroundStyle(theme.recessiveTertiary)
                        }

                        ForEach(notebook.tags, id: \.self) { tag in
                            tagPill(tag)
                        }

                        if isAddingTag {
                            inlineTagComposer
                        } else {
                            addTagButton
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let tagError {
                    Text(tagError)
                        .font(.system(size: 9).italic())
                        .foregroundStyle(Color.red.opacity(0.75))
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(minWidth: 320, minHeight: 180)
            .navigationTitle("tags")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func tagPill(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.system(size: 12))
            Button {
                removeTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
        }
        .foregroundStyle(Color(light: .white, dark: Color.coverTextBlack))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(
                Color(light: Color.coverTextBlack, dark: Color(hex: "#f5f5f5"))
            )
        )
    }

    private var addTagButton: some View {
        Button {
            tagBuffer = ""
            tagError = nil
            isAddingTag = true
            DispatchQueue.main.async { tagFieldFocused = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.recessivePrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add tag")
    }

    private var inlineTagComposer: some View {
        HStack(spacing: 4) {
            TextField("tag", text: $tagBuffer)
                .font(.system(size: 12))
                .focused($tagFieldFocused)
                .submitLabel(.done)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { commitTagBuffer() }
                .onChange(of: tagFieldFocused) { _, focused in
                    if !focused { commitTagBuffer() }
                }
                .frame(minWidth: 60, maxWidth: 120)
            Button {
                cancelTagComposer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(theme.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().strokeBorder(theme.accent, lineWidth: 0.8))
    }

    private func commitTagBuffer() {
        defer {
            tagBuffer = ""
            isAddingTag = false
        }
        let existing = notebook.tags
        switch TagValidator.validate(tagBuffer, against: existing) {
        case .success(let normal):
            var updated = existing
            updated.append(normal)
            notebook.tags = updated
            persistTags()
            tagError = nil
        case .failure(.empty):
            tagError = nil
        case .failure(.tooLong):
            tagError = "tag is too long (max 32 chars)."
        case .failure(.containsDigit):
            tagError = "tags can't include numbers."
        case .failure(.containsEmoji):
            tagError = "tags can't include emoji."
        case .failure(.duplicate):
            tagError = nil
        case .failure(.tooManyTags):
            tagError = "20-tag limit reached."
        }
    }

    private func cancelTagComposer() {
        tagBuffer = ""
        tagError = nil
        isAddingTag = false
    }

    private func removeTag(_ tag: String) {
        var updated = notebook.tags
        guard let idx = updated.firstIndex(of: tag) else { return }
        updated.remove(at: idx)
        notebook.tags = updated
        persistTags()
        tagError = nil
    }

    private func persistTags() {
        do {
            try StorageService.shared.updateNotebook(
                notebook,
                title: nil,
                coverColorHex: nil,
                isPinned: nil,
                tags: notebook.tags
            )
            viewModel.refresh()
        } catch {
            tagError = "couldn't save tags."
        }
    }
}
