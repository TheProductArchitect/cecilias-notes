import SwiftUI

struct SubjectRowView: View {
    let subject: Subject
    @ObservedObject var viewModel: LibraryViewModel

    @State private var isRenaming = false
    @State private var editingName = ""
    @State private var showColourPicker = false
    @State private var showDeleteAlert = false
    @State private var isDropTarget = false
    @FocusState private var renameFocused: Bool

    private var isSelected: Bool { viewModel.selectedSubjectId == subject.id }
    private var notebookCount: Int {
        subject.notebooks.filter { !$0.isDeleted }.count
    }

    var body: some View {
        HStack(spacing: Ink.Spacing.sm) {
            // Colour circle
            Circle()
                .fill(Color(UIColor(hex: subject.colorHex)))
                .frame(width: 12, height: 12)

            // Name / rename field
            if isRenaming {
                TextField("Subject name", text: $editingName)
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextPrimary)
                    .focused($renameFocused)
                    .submitLabel(.done)
                    .onSubmit { commitRename() }
                    .onAppear {
                        editingName    = subject.name
                        renameFocused = true
                    }
            } else {
                Text(subject.name)
                    .font(.inkSubhead)
                    .foregroundColor(isSelected ? .inkTextPrimary : .inkTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Drag handle — always visible at tertiary opacity
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .fontWeight(.medium)
                .foregroundColor(.inkTextTertiary)

            InkBadge("\(notebookCount)", style: .count)
        }
        .padding(.horizontal, Ink.Spacing.sm)
        .padding(.vertical, 10)
        .background(background)
        .contentShape(Rectangle())
        // Single tap: select. Double tap: rename.
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture(count: 1) { viewModel.selectedSubjectId = subject.id }
        .contextMenu { contextMenuContent }
        // Accept dropped notebooks
        .dropDestination(for: Data.self) { items, _ in
            var landed = false
            for data in items {
                if let decoded = try? JSONDecoder().decode(NotebookTransferID.self, from: data) {
                    viewModel.moveNotebook(id: decoded.id, to: subject.id)
                    landed = true
                }
            }
            if landed { HapticManager.shared.dragReorderDropped() }
            return true
        } isTargeted: { targeted in
            withAnimation(.inkSpring(InkSpring.precise)) {
                isDropTarget = targeted
            }
        }
        .alert("Delete \"\(subject.name)\"?", isPresented: $showDeleteAlert) {
            Button("Move Notebooks & Delete", role: .destructive) {
                HapticManager.shared.destructiveConfirmed()
                viewModel.deleteSubject(subject)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Move \(notebookCount) notebook\(notebookCount == 1 ? "" : "s") to Uncategorised and delete this subject?")
        }
        // Reactive: if ViewModel signals this row should rename, begin.
        .onChange(of: viewModel.renamingSubjectId) { _, id in
            if id == subject.id { beginRename() }
        }
        // Dismiss rename on tap outside — handled by the host scroll/list taps naturally,
        // but we also watch focus loss.
        .onChange(of: renameFocused) { _, focused in
            if !focused && isRenaming { commitRename() }
        }
        .popover(isPresented: $showColourPicker) {
            SubjectColourPickerView(currentHex: subject.colorHex) { hex in
                viewModel.recolourSubject(subject, hex: hex)
                showColourPicker = false
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
            .fill(
                isDropTarget
                    ? Color.inkAccentSecondary
                    : (isSelected ? Color.inkBackgroundTertiary : Color.clear)
            )
            .overlay(
                isDropTarget
                    ? RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                        .strokeBorder(Color.inkAccentPrimary, lineWidth: 0.5)
                    : nil
            )
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            beginRename()
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            showColourPicker = true
        } label: {
            Label("Change Colour", systemImage: "paintpalette")
        }
        Divider()
        Button(role: .destructive) {
            showDeleteAlert = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func beginRename() {
        editingName = subject.name
        isRenaming  = true
        // Clear the triggering signal so it can fire again later
        if viewModel.renamingSubjectId == subject.id {
            viewModel.renamingSubjectId = nil
        }
    }

    private func commitRename() {
        isRenaming    = false
        renameFocused = false
        viewModel.renameSubject(subject, name: editingName)
    }
}

// MARK: - Colour picker popover

struct SubjectColourPickerView: View {
    let currentHex: String
    let onSelect: (String) -> Void

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 12), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            Text("Colour")
                .font(.inkHeadline)
                .foregroundColor(.inkTextPrimary)
                .padding(.top, 16)
                .padding(.bottom, 12)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(InkColorPresets.subjectColors, id: \.self) { hex in
                    colourCircle(hex: hex)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Color.inkBackgroundElevated)
        .presentationCompactAdaptation(.popover)
    }

    private func colourCircle(hex: String) -> some View {
        let selected = hex == currentHex
        return Button {
            onSelect(hex)
        } label: {
            ZStack {
                Circle()
                    .fill(Color(UIColor(hex: hex)))
                    .frame(width: 36, height: 36)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(.inkPressable)
        .overlay(
            Circle()
                .strokeBorder(
                    selected ? Color.white.opacity(0.6) : Color.clear,
                    lineWidth: 2
                )
        )
    }
}
