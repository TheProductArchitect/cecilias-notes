import SwiftUI

/// Defers `@Published` writes to the next runloop tick. Direct mutation
/// during SwiftUI view updates (scroll geometry, List selection bindings,
/// notification handlers) triggers render loops that freeze interaction.
@MainActor
enum MacStateUpdates {
    static func deferred(_ work: @MainActor @escaping () -> Void) {
        Task { @MainActor in work() }
    }
}

@MainActor
final class MacLibraryState: ObservableObject {
    @Published var selectedContext: LibraryContext = .allNotes
    @Published var selectedNotebookID: UUID?
    @Published var selectedPageID: UUID?
    @Published var isShowingTrash = false
    @Published var isSyncingLibrary = CloudKitContainerState.status == .uninitialized
    @Published var searchText = ""
    @Published var notebookListMode: MacNotebookListMode = .grid
    @Published var editorZoom: CGFloat = 1
    @Published var editorScrollOffset: CGFloat = 0
    @Published var pendingHandoffScrollOffset: CGFloat?
    @Published var selectedElementID: UUID?
    @Published var editingBlockID: UUID?
    @Published var editingTextElement: PageElement?
    @Published var isExportPresented = false
    @Published var exportFormat: MacExportFormat = .pdf
    @Published var isFocusMode = false
    @Published var headerVisibility: HeaderVisibility = .visible
    @Published var isCustomisePanelOpen = false
    @Published var isEditingNotebookTitle = false

    private var headerManualReHideTask: Task<Void, Never>?
    private var interactionGraceTask: Task<Void, Never>?
    private var activeInteractions = Set<MacHeaderInteraction>()

    // MARK: - Header visibility (mirrors iPad `EditorViewModel`)

    func notifyHeaderWritingBegan(notebook: Notebook) {
        guard notebook.autoHideHeader else { return }
        guard activeInteractions.isEmpty else { return }
        guard interactionGraceTask == nil else { return }
        switch headerVisibility {
        case .visible:
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                headerVisibility = .hiddenWhileWriting
            }
        case .visibleManual:
            headerManualReHideTask?.cancel()
            headerManualReHideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                    self.headerVisibility = .hiddenWhileWriting
                }
            }
        case .hiddenWhileWriting:
            break
        }
    }

    func revealHeaderManually() {
        headerManualReHideTask?.cancel()
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
            headerVisibility = .visibleManual
        }
    }

    func beginHeaderInteraction(_ reason: MacHeaderInteraction) {
        interactionGraceTask?.cancel()
        interactionGraceTask = nil
        headerManualReHideTask?.cancel()
        activeInteractions.insert(reason)
        if !headerVisibility.isHeaderVisible {
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                headerVisibility = .visibleManual
            }
        }
    }

    func endHeaderInteraction(_ reason: MacHeaderInteraction, notebook: Notebook) {
        activeInteractions.remove(reason)
        guard activeInteractions.isEmpty else { return }
        interactionGraceTask?.cancel()
        interactionGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.interactionGraceTask = nil
            guard notebook.autoHideHeader, self.activeInteractions.isEmpty else { return }
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                self.headerVisibility = .hiddenWhileWriting
            }
        }
    }

    func pulseHeaderInteraction(_ reason: MacHeaderInteraction, notebook: Notebook) {
        beginHeaderInteraction(reason)
        endHeaderInteraction(reason, notebook: notebook)
    }

    func notifyAutoHidePreferenceChanged(notebook: Notebook) {
        objectWillChange.send()
        guard !notebook.autoHideHeader else { return }
        headerManualReHideTask?.cancel()
        interactionGraceTask?.cancel()
        interactionGraceTask = nil
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
            headerVisibility = .visible
        }
    }

    func openCustomisePanel() {
        isCustomisePanelOpen = true
        beginHeaderInteraction(.customisePanel)
    }

    func closeCustomisePanel(notebook: Notebook) {
        isCustomisePanelOpen = false
        endHeaderInteraction(.customisePanel, notebook: notebook)
    }
}

enum MacHeaderInteraction: Hashable {
    case recordingPanel
    case customisePanel
    case share
    case undoRedo
}

enum MacNotebookListMode: String, CaseIterable {
    case grid
    case list
}

/// Mirrors iPad `HeaderVisibility` — duplicated here because the
/// editor target file is excluded from the Mac build.
enum HeaderVisibility {
    case visible
    case hiddenWhileWriting
    case visibleManual

    var isHeaderVisible: Bool {
        switch self {
        case .visible, .visibleManual: return true
        case .hiddenWhileWriting:      return false
        }
    }
}
