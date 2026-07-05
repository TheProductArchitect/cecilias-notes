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
    @Published var isUniversalSearchPresented = false
    @Published var notebookListMode: MacNotebookListMode = .grid
    @Published var editorZoom: CGFloat = 1
    @Published var editorScrollOffset: CGFloat = 0
    @Published var selectedElementID: UUID?
    @Published var editingTextElement: PageElement?
    @Published var isExportPresented = false
    @Published var exportFormat: MacExportFormat = .pdf
}

enum MacNotebookListMode: String, CaseIterable {
    case grid
    case list
}
