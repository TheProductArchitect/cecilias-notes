import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Supporting types

enum NotebookSortOrder: String, CaseIterable, Identifiable {
    case lastModified  = "Last Modified"
    case created       = "Date Created"
    case alphabetical  = "Alphabetical"
    case manual        = "Manual"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .lastModified:  return "clock"
        case .created:       return "calendar"
        case .alphabetical:  return "textformat.abc"
        case .manual:        return "hand.draw"
        }
    }
}

struct GroupedSearchResults {
    var notebookMatches:     [SearchResult] = []
    var textBlockMatches:    [SearchResult] = []
    var transcriptionMatches:[SearchResult] = []

    var isEmpty: Bool {
        notebookMatches.isEmpty && textBlockMatches.isEmpty && transcriptionMatches.isEmpty
    }
    var total: Int { notebookMatches.count + textBlockMatches.count + transcriptionMatches.count }
}

// Used for drag-and-drop between card and sidebar row.
struct NotebookTransferID: Transferable, Codable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

// MARK: - LibraryViewModel

@MainActor
final class LibraryViewModel: ObservableObject {

    // MARK: Published state (spec)
    @Published var selectedSubjectId: UUID?             // nil = All Notes
    @Published var selectedNotebookId: UUID?
    @Published var searchText: String = ""
    @Published var sortOrder: NotebookSortOrder = .lastModified
    @Published var isSelecting: Bool = false
    @Published var selectedNotebookIds: Set<UUID> = []

    // MARK: Additional published state
    @Published private(set) var subjects:         [Subject] = []
    @Published private(set) var folders:          [Folder] = []
    @Published private(set) var notebooks:        [Notebook] = []
    @Published private(set) var pinnedNotebooks:  [Notebook] = []

    /// Files-style folder navigation. Empty = at the subject's root.
    /// Top of the stack = current folder. Stack is reset whenever the
    /// selected subject changes.
    @Published var folderPath: [Folder] = []

    /// Drives inline rename in the browser.
    @Published var renamingFolderId:   UUID?
    @Published private(set) var searchResults:    GroupedSearchResults?
    @Published private(set) var duplicatingIds:   Set<UUID> = []
    @Published var isSearchActive: Bool = false
    @Published var renamingSubjectId: UUID?     // drives inline rename in sidebar

    /// Structured user-visible error from any failed storage mutation.
    /// Surfaced via `MediaErrorBanner` in `LibraryView`.
    @Published var error: AppError?

    /// Pushes a structured error to the banner.
    func showError(_ appError: AppError) {
        self.error = appError
    }

    // MARK: Internals
    private let storage: StorageService
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init
    init(storage: StorageService = .shared) {
        self.storage = storage
        refresh()

        $searchText
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] text in self?.performSearch(text) }
            .store(in: &cancellables)

        // Clear selection mode AND reset the folder browser path when the
        // subject changes — every subject opens at its own root.
        $selectedSubjectId
            .dropFirst()
            .sink { [weak self] _ in
                self?.isSelecting = false
                self?.selectedNotebookIds = []
                self?.folderPath = []
                self?.refresh()
            }
            .store(in: &cancellables)

        $sortOrder
            .dropFirst()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    // MARK: Derived

    var selectedSubjectName: String {
        if let id = selectedSubjectId,
           let subject = subjects.first(where: { $0.id == id }) {
            return subject.name
        }
        return "All Notes"
    }

    var totalNotebookCount: Int {
        storage.fetchAllNotebooks().count
    }

    // MARK: Refresh

    func refresh() {
        subjects        = storage.fetchSubjects()
        folders         = storage.fetchAllFolders()
        let raw: [Notebook]
        if let id = selectedSubjectId {
            raw = storage.fetchNotebooks(subjectId: id)
        } else {
            raw = storage.fetchAllNotebooks()
        }
        notebooks       = sorted(raw)
        pinnedNotebooks = notebooks.filter(\.isPinned)
    }

    // MARK: Browser helpers (Files-style nesting)

    /// Folder the user is currently inside. Nil = at the subject root.
    var currentFolder: Folder? { folderPath.last }

    /// Folders to render at the current browser level (subject root or
    /// inside the current folder).
    var foldersAtCurrentLevel: [Folder] {
        if let current = currentFolder {
            return folders.filter { $0.parentFolderId == current.id }
        } else if let subjectId = selectedSubjectId {
            return folders.filter {
                $0.parentSubjectId == subjectId && $0.parentFolderId == nil
            }
        } else {
            // "All Notes" view doesn't surface folders — too noisy across subjects.
            return []
        }
    }

    /// Notebooks to render at the current browser level.
    var notebooksAtCurrentLevel: [Notebook] {
        if let current = currentFolder {
            return notebooks.filter { $0.folderId == current.id }
        } else if let subjectId = selectedSubjectId {
            return notebooks.filter {
                $0.subjectId == subjectId && $0.folderId == nil
            }
        } else {
            // "All Notes" — show every non-deleted notebook regardless of folder.
            return notebooks
        }
    }

    /// Total count of items inside `folder` (notebooks + subfolders), used
    /// for the badge on the folder card. Computed client-side from cached
    /// arrays; cheap.
    /// Top-level folders (no parent folder) inside a given subject. Used by
    /// the notebook card's "Move to Folder…" submenu so the user can drop
    /// directly into a root folder of the subject.
    func topLevelFolders(in subjectId: UUID) -> [Folder] {
        folders.filter { $0.parentSubjectId == subjectId && $0.parentFolderId == nil }
    }

    func itemCount(in folder: Folder) -> Int {
        let nbs    = notebooks.filter { $0.folderId == folder.id }.count
        let subs   = folders.filter   { $0.parentFolderId == folder.id }.count
        return nbs + subs
    }

    // MARK: Browser navigation

    func navigate(into folder: Folder) {
        folderPath.append(folder)
    }

    func navigateUp() {
        guard !folderPath.isEmpty else { return }
        folderPath.removeLast()
    }

    /// Pop the path back to the breadcrumb segment at `index`. Index 0 =
    /// "back to subject root"; index N pops to the Nth folder.
    func navigateToBreadcrumb(index: Int) {
        guard index >= 0 && index < folderPath.count else { return }
        folderPath = Array(folderPath.prefix(index))
    }

    func navigateToSubjectRoot() {
        folderPath.removeAll()
    }

    private func sorted(_ notebooks: [Notebook]) -> [Notebook] {
        switch sortOrder {
        case .lastModified:  return notebooks.sorted { $0.updatedAt > $1.updatedAt }
        case .created:       return notebooks.sorted { $0.createdAt < $1.createdAt }
        case .alphabetical:  return notebooks.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        case .manual:        return notebooks.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.sortOrder < $1.sortOrder
        }
        }
    }

    // MARK: - Subjects

    func createSubject() {
        guard let subject = try? storage.createSubject(
            name: "New Subject",
            colorHex: InkColorPresets.subjectColors[6]
        ) else { return }
        refresh()
        renamingSubjectId = subject.id
        selectedSubjectId = subject.id
    }

    func renameSubject(_ subject: Subject, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? storage.updateSubject(subject, name: trimmed, colorHex: nil)
        refresh()
    }

    func recolourSubject(_ subject: Subject, hex: String) {
        try? storage.updateSubject(subject, name: nil, colorHex: hex)
        refresh()
    }

    func deleteSubject(_ subject: Subject) {
        try? storage.deleteSubject(subject)
        if selectedSubjectId == subject.id { selectedSubjectId = nil }
        refresh()
    }

    func reorderSubjects(from source: IndexSet, to destination: Int) {
        var ordered = subjects
        ordered.move(fromOffsets: source, toOffset: destination)
        try? storage.reorderSubjects(ordered)
        refresh()
    }

    // MARK: - Folders

    /// Creates a folder at the **current** browser location:
    ///   • If `currentFolder == nil` → the subject's root.
    ///   • Otherwise → inside `currentFolder` (nested).
    func createFolderAtCurrentLevel() {
        guard let subjectId = selectedSubjectId,
              let subject = subjects.first(where: { $0.id == subjectId })
        else { return }
        guard let folder = try? storage.createFolder(
            name: "New Folder",
            in: subject,
            parentFolderId: currentFolder?.id
        ) else { return }
        renamingFolderId = folder.id
        refresh()
    }

    /// Legacy single-arg overload kept for any sidebar/test call sites that
    /// pass a subject directly.
    func createFolder(in subject: Subject) {
        guard let folder = try? storage.createFolder(name: "New Folder", in: subject) else { return }
        renamingFolderId = folder.id
        refresh()
    }

    func renameFolder(_ folder: Folder, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try storage.updateFolder(folder, name: trimmed)
        } catch {
            showError(.storageFailed(action: "rename folder", underlying: error))
        }
        refresh()
    }

    /// Soft-deletes the folder, promoting its direct children one level up.
    /// Notebooks and subfolders survive. Used for "Move and Delete Folder".
    func deleteFolder(_ folder: Folder) {
        do {
            try storage.deleteFolder(folder)
        } catch {
            showError(.storageFailed(action: "delete folder", underlying: error))
        }
        // If the user was inside (or below) the deleted folder, pop out so
        // the breadcrumb doesn't dangle on a tombstoned segment.
        if folderPath.contains(where: { $0.id == folder.id }) {
            if let idx = folderPath.firstIndex(where: { $0.id == folder.id }) {
                folderPath = Array(folderPath.prefix(idx))
            }
        }
        refresh()
    }

    /// Soft-deletes the folder and recursively soft-deletes every notebook
    /// and subfolder underneath it. Used for "Delete Folder and All Contents".
    func deleteFolderAndContents(_ folder: Folder) {
        do {
            try storage.deleteFolderAndContents(folder)
        } catch {
            showError(.storageFailed(action: "delete folder", underlying: error))
        }
        if let idx = folderPath.firstIndex(where: { $0.id == folder.id }) {
            folderPath = Array(folderPath.prefix(idx))
        }
        refresh()
    }

    /// Move a notebook into / out of a folder. `folderId == nil` means
    /// "directly under the subject (no folder)". Used by drag-and-drop and
    /// the context menu's "Move to folder…" option.
    func moveNotebook(_ notebook: Notebook, toFolder folderId: UUID?) {
        do {
            try storage.moveNotebook(notebook, toFolder: folderId)
        } catch {
            showError(.storageFailed(action: "move notebook", underlying: error))
        }
        refresh()
    }

    // MARK: - Notebooks

    func createNotebook(
        title: String,
        subjectId: UUID?,
        coverColorHex: String,
        coverTexture: CoverTexture,
        pageSize: PageSize,
        template: PageTemplate,
        folderId: UUID? = nil
    ) {
        guard let nb = try? storage.createNotebook(
            title: title,
            subjectId: subjectId,
            coverColorHex: coverColorHex,
            coverTexture: coverTexture,
            pageSize: pageSize,
            template: template
        ) else { return }
        // Place the new notebook inside the active browser folder, if any.
        if let folderId {
            try? storage.moveNotebook(nb, toFolder: folderId)
        }
        refresh()
        // Scroll-to is communicated via selectedNotebookId
        withAnimation(.inkSpring(InkSpring.smooth)) {
            selectedNotebookId = nb.id
        }
    }

    /// Returns a playful default name (e.g. "Brain Dump", "Scratch Pad of Doom",
    /// "Coffee-Fueled Ideas") that doesn't collide with existing titles.
    /// Always reads a fresh fetch so rapid successive taps cannot collide.
    func uniqueUntitledName() -> String {
        let titles = Set(storage.fetchAllNotebooks().map(\.title))
        return NotebookNameGenerator.randomName(avoiding: titles)
    }

    /// Creates a notebook instantly with the user's *last-used* cover, page
    /// size, and template — or sensible first-run defaults if those keys
    /// have never been written. Opens directly into the editor; the editor
    /// surfaces a floating "Customise" pill so the user can tweak covers,
    /// page size, and template post-creation.
    ///
    /// Persistence: `lastUsed*` keys are *only* written when the user
    /// explicitly picks something via the Customise panel. The panel's
    /// model layer owns those writes; this method just reads them.
    func createUntitledNotebookAndOpen() {
        HapticManager.shared.notebookCreated()

        let cover    = NotebookCover.from(rawValue: UserDefaults.standard.string(forKey: "ink.lastUsed.cover"))
        let pageSize: PageSize = {
            // Backwards-compat: also honour the legacy "ink.newpage.size" key
            // that the Settings → New Pages screen still writes to.
            if let raw = UserDefaults.standard.string(forKey: "ink.lastUsed.pageSize")
                ?? UserDefaults.standard.string(forKey: "ink.newpage.size"),
               let v = PageSize(rawValue: raw) { return v }
            return .a4
        }()
        let template: PageTemplate = {
            let raw = UserDefaults.standard.string(forKey: "ink.lastUsed.template")
                ?? UserDefaults.standard.string(forKey: "ink.newpage.template")
            if let raw,
               let data = raw.data(using: .utf8),
               let t    = try? JSONDecoder().decode(PageTemplate.self, from: data) { return t }
            return .blank
        }()

        createNotebook(
            title:         uniqueUntitledName(),
            subjectId:     selectedSubjectId,
            coverColorHex: cover.colorHex,
            coverTexture:  cover.texture,
            pageSize:      pageSize,
            template:      template,
            folderId:      currentFolder?.id
        )
    }

    func renameNotebook(_ notebook: Notebook, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try storage.updateNotebook(notebook, title: trimmed, coverColorHex: nil, isPinned: nil, tags: nil)
        } catch {
            showError(.storageFailed(action: "rename notebook", underlying: error))
        }
        refresh()
    }

    func deleteNotebook(_ notebook: Notebook) {
        withAnimation(.inkSpring(InkSpring.smooth)) {
            do {
                try storage.deleteNotebook(notebook)
                notebooks.removeAll     { $0.id == notebook.id }
                pinnedNotebooks.removeAll { $0.id == notebook.id }
            } catch {
                showError(.storageFailed(action: "delete notebook", underlying: error))
            }
        }
    }

    func deleteSelectedNotebooks() {
        let ids = selectedNotebookIds
        var firstError: Error?
        for nb in storage.fetchAllNotebooks() where ids.contains(nb.id) {
            do {
                try storage.deleteNotebook(nb)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        // Animate the model side only after the storage round; on failure the
        // refresh() at end will reconcile any rows that didn't actually delete.
        withAnimation(.inkSpring(InkSpring.smooth)) {
            notebooks.removeAll     { ids.contains($0.id) }
            pinnedNotebooks.removeAll { ids.contains($0.id) }
        }
        if let firstError {
            showError(.storageFailed(action: "delete notebooks", underlying: firstError))
            refresh()
        }
        isSelecting = false
        selectedNotebookIds = []
    }

    func duplicateNotebook(_ notebook: Notebook) {
        duplicatingIds.insert(notebook.id)
        Task {
            _ = try? await storage.duplicateNotebook(notebook)
            duplicatingIds.remove(notebook.id)
            refresh()
        }
    }

    func togglePin(_ notebook: Notebook) {
        do {
            try storage.updateNotebook(notebook, title: nil, coverColorHex: nil,
                                       isPinned: !notebook.isPinned, tags: nil)
        } catch {
            showError(.storageFailed(action: "update notebook", underlying: error))
        }
        refresh()
    }

    /// Triggers the "Share as PDF…" flow from the Library context menu.
    /// Sets the pending-export flag, then routes through DeepLinkRouter so the
    /// editor opens and immediately presents `ExportOptionsView` on appear.
    /// Wired in `LibraryView` via the `DeepLinkRouter` env object.
    @Published var pendingExportNotebookId: UUID?

    func requestExport(for notebook: Notebook) {
        pendingExportNotebookId = notebook.id
    }

    func moveNotebook(_ notebook: Notebook, to subjectId: UUID?) {
        try? storage.moveNotebook(notebook, to: subjectId)
        refresh()
    }

    func moveNotebooks(ids: Set<UUID>, to subjectId: UUID?) {
        for nb in storage.fetchAllNotebooks() where ids.contains(nb.id) {
            try? storage.moveNotebook(nb, to: subjectId)
        }
        isSelecting = false
        selectedNotebookIds = []
        refresh()
    }

    func moveNotebook(id: UUID, to subjectId: UUID?) {
        guard let nb = storage.fetchAllNotebooks().first(where: { $0.id == id }) else { return }
        moveNotebook(nb, to: subjectId)
    }

    func reorderNotebooks(_ notebooks: [Notebook]) {
        try? storage.reorderNotebooks(notebooks, in: selectedSubjectId)
        refresh()
    }

    // MARK: Multi-select

    func toggleSelection(_ notebook: Notebook) {
        if selectedNotebookIds.contains(notebook.id) {
            selectedNotebookIds.remove(notebook.id)
        } else {
            selectedNotebookIds.insert(notebook.id)
        }
    }

    func enterSelectMode(selecting notebook: Notebook) {
        isSelecting = true
        selectedNotebookIds = [notebook.id]
    }

    // MARK: Search

    func activateSearch() {
        isSearchActive = true
    }

    func deactivateSearch() {
        isSearchActive = false
        searchText = ""
        searchResults = nil
    }

    private func performSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = nil
            return
        }
        let flat = storage.search(query: trimmed)
        var grouped = GroupedSearchResults()
        for r in flat {
            switch r.type {
            case .notebookTitle:  grouped.notebookMatches.append(r)
            case .textBlock:      grouped.textBlockMatches.append(r)
            case .transcription:  grouped.transcriptionMatches.append(r)
            }
        }
        searchResults = grouped
    }

    // MARK: Notebook lookup (for search results)

    func notebook(id: UUID) -> Notebook? {
        storage.fetchAllNotebooks().first { $0.id == id }
    }
}
