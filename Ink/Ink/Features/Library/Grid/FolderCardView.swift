import SwiftUI

/// Files-style folder card rendered inside the browser grid alongside
/// `NotebookCardView`. Tap to descend into the folder; long-press for
/// Rename / Delete; accepts dropped notebooks to move them in.
struct FolderCardView: View {
    let folder: Folder
    @ObservedObject var viewModel: LibraryViewModel

    @State private var isHovered      = false
    @State private var isDropTarget   = false
    @State private var isRenaming     = false
    @State private var editingName    = ""
    @State private var showDeletePrompt = false
    @FocusState private var renameFocused: Bool

    private var itemCount: Int { viewModel.itemCount(in: folder) }

    var body: some View {
        VStack(spacing: CeciliasNotes.Spacing.sm) {
            // Folder glyph fills the upper portion of the card so a folder
            // and a notebook cover read as siblings at the same grid size.
            ZStack {
                RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous)
                    .fill(Color.inkBackgroundSecondary)

                Image(systemName: itemCount == 0 ? "folder" : "folder.fill")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(Color.inkAccentPrimary.opacity(0.85))
                    .accessibilityHidden(true)

                // Item count badge in the corner, only when non-empty.
                if itemCount > 0 {
                    VStack {
                        HStack {
                            Spacer()
                            CeciliasNotesBadge("\(itemCount)", style: .count)
                                .padding(8)
                        }
                        Spacer()
                    }
                }
            }
            .frame(height: 140)

            if isRenaming {
                TextField("Folder name", text: $editingName)
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextPrimary)
                    .multilineTextAlignment(.center)
                    .focused($renameFocused)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .onSubmit { commitRename() }
                    .onAppear {
                        editingName   = folder.name
                        renameFocused = true
                    }
            } else {
                Text(folder.name)
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(CeciliasNotes.Spacing.sm)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous))
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { hovered in
            withAnimation(.inkSpring(CeciliasNotesSpring.precise)) { isHovered = hovered }
        }
        .contentShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous))
        .onTapGesture {
            if isRenaming { return }
            withAnimation(.inkSpring(CeciliasNotesSpring.snappy)) {
                viewModel.navigate(into: folder)
            }
        }
        // Note: a `.simultaneousGesture(LongPressGesture)` used to live
        // here for haptic pre-warm. It raced pencil taps and ate the
        // first one. Removed — see NotebookCardView for the same fix.
        .contextMenu { contextMenu }
        // Accept dropped notebooks → move into this folder
        .dropDestination(for: Data.self) { items, _ in
            var landed = false
            for data in items {
                if let decoded = try? JSONDecoder().decode(NotebookTransferID.self, from: data),
                   let notebook = viewModel.notebook(id: decoded.id) {
                    viewModel.moveNotebook(notebook, toFolder: folder.id)
                    landed = true
                }
            }
            if landed { HapticManager.shared.dragReorderDropped() }
            return true
        } isTargeted: { targeted in
            withAnimation(.inkSpring(CeciliasNotesSpring.precise)) { isDropTarget = targeted }
        }
        .onChange(of: viewModel.renamingFolderId) { _, id in
            if id == folder.id { beginRename() }
        }
        .onChange(of: renameFocused) { _, focused in
            if !focused && isRenaming { commitRename() }
        }
        .confirmationDialog(
            "Delete \"\(folder.name)\"?",
            isPresented: $showDeletePrompt,
            titleVisibility: .visible
        ) {
            if itemCount == 0 {
                Button("Delete Folder", role: .destructive) {
                    HapticManager.shared.destructiveConfirmed()
                    viewModel.deleteFolder(folder)
                }
            } else {
                Button("Move Items & Delete Folder") {
                    HapticManager.shared.destructiveConfirmed()
                    viewModel.deleteFolder(folder)
                }
                Button("Delete Folder and All Contents", role: .destructive) {
                    HapticManager.shared.destructiveConfirmed()
                    viewModel.deleteFolderAndContents(folder)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if itemCount == 0 {
                Text("This folder is empty.")
            } else {
                Text("This folder contains \(itemCount) item\(itemCount == 1 ? "" : "s"). Choose how to delete it.")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.name), \(itemCount) item\(itemCount == 1 ? "" : "s")")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous)
            .fill(isDropTarget ? Color.inkAccentSecondary : Color.clear)
            .overlay(
                isDropTarget
                    ? RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous)
                        .strokeBorder(Color.inkAccentPrimary, lineWidth: 1)
                    : nil
            )
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button { beginRename() } label: {
            Label("Rename", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            showDeletePrompt = true
        } label: {
            Label("Delete Folder", systemImage: "trash")
        }
    }

    private func beginRename() {
        editingName = folder.name
        isRenaming  = true
        if viewModel.renamingFolderId == folder.id {
            viewModel.renamingFolderId = nil
        }
    }

    private func commitRename() {
        isRenaming    = false
        renameFocused = false
        viewModel.renameFolder(folder, name: editingName)
    }
}
