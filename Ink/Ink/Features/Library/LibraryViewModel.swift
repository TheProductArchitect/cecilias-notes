import Combine
import Foundation
import PDFKit
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
    var handwritingMatches:  [SearchResult] = []

    var isEmpty: Bool {
        notebookMatches.isEmpty
            && textBlockMatches.isEmpty
            && transcriptionMatches.isEmpty
            && handwritingMatches.isEmpty
    }
    var total: Int {
        notebookMatches.count
            + textBlockMatches.count
            + transcriptionMatches.count
            + handwritingMatches.count
    }
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

    /// Which subset of notebooks the home grid is rendering. Drives
    /// the sidebar's active-row indicator and the grid's content set.
    /// Persisted across launches so a user returns to the same view.
    @Published var selectedContext: LibraryContext = .recent

    /// Convenience surface for call-sites that historically read or
    /// wrote `selectedSubjectId`. Reads return the id when in subject
    /// context, `nil` otherwise. Writes promote a non-nil id to
    /// subject context, and `nil` writes drop back to `.allNotes` if
    /// (and only if) the prior context was a subject — `.recent` and
    /// `.allNotes` writes don't interfere.
    var selectedSubjectId: UUID? {
        get { selectedContext.subjectId }
        set {
            if let id = newValue {
                selectedContext = .subject(id)
            } else if case .subject = selectedContext {
                selectedContext = .allNotes
            }
        }
    }

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

    /// Six most-recently-opened notebooks across all subjects. Driven
    /// by `Notebook.lastAccessedAt`. Empty when the user has never
    /// opened a notebook — the home screen hides the strip in that case.
    @Published private(set) var recentNotebooks:   [Notebook] = []

    /// Id of the single most-recently-opened notebook. Drives the blue
    /// "active" dot top-right of `NotebookCardView`. `nil` when no
    /// notebook has ever been opened.
    var mostRecentNotebookId: UUID? { recentNotebooks.first?.id }

    /// True when at least one subject exists. Notebooks must belong to
    /// a subject — the sidebar's "+ new notebook" button is disabled
    /// while this is false.
    var canCreateNotebook: Bool { !subjects.isEmpty }

    /// Folders only live inside a specific subject — `.recent` and
    /// `.allNotes` contexts can't host them. Drives the disabled
    /// state of the "New Folder" item in the grid toolbar's `+` menu.
    var canCreateFolder: Bool {
        if case .subject = selectedContext { return true }
        return false
    }

    /// Wraps `createUntitledNotebookAndOpen` so it works from any
    /// context. From `.recent` / `.allNotes` we promote the
    /// `inferredSubjectIdForNewNotebook` (most-recent notebook's
    /// subject → first subject) so the new notebook lands somewhere
    /// meaningful and the sidebar visibly switches to that subject.
    /// No-op when no subjects exist.
    func createNotebookWithFallback() {
        guard canCreateNotebook else { return }
        if selectedSubjectId == nil,
           let target = inferredSubjectIdForNewNotebook {
            selectedSubjectId = target
        }
        createUntitledNotebookAndOpen()
    }

    /// Subject the sidebar's "+ new notebook" should land in when the
    /// user isn't already inside a specific subject. Tries, in order:
    /// the currently-selected subject, the subject of the most-recently-
    /// opened notebook, the first subject in the list. Returns `nil`
    /// only when no subjects exist at all.
    var inferredSubjectIdForNewNotebook: UUID? {
        if let selected = selectedSubjectId { return selected }
        if let recentSubject = recentNotebooks.first?.subjectId { return recentSubject }
        return subjects.first?.id
    }

    /// Files-style folder navigation. Empty = at the subject's root.
    /// Top of the stack = current folder. Stack is reset whenever the
    /// selected subject changes.
    @Published var folderPath: [Folder] = []

    /// Drives inline rename in the browser.
    @Published var renamingFolderId:   UUID?
    @Published private(set) var searchResults:    GroupedSearchResults?

    /// Active tag filter. Empty set = no filter (all notebooks pass).
    /// Multiple tags OR-combine: a notebook appears if it has ANY
    /// selected tag. Session-only — never persisted, cleared on
    /// app background.
    @Published var activeTagFilters: Set<String> = []

    var isTagFilterActive: Bool { !activeTagFilters.isEmpty }

    /// Unique, sorted tag list across every (non-deleted) notebook
    /// in the *current context* — driver for the filter sheet's
    /// option list. Recomputed on demand; the library never has
    /// more than a few hundred notebooks so the O(n × k) scan is
    /// cheap.
    func availableTagsInCurrentContext() -> [String] {
        let pool: [Notebook]
        switch selectedContext {
        case .recent:           pool = storage.fetchRecentNotebooks(limit: 200)
        case .allNotes:         pool = storage.fetchAllNotebooks()
        case .subject(let id):  pool = storage.fetchNotebooks(subjectId: id)
        }
        var seen = Set<String>()
        for nb in pool {
            for tag in nb.tags where !tag.isEmpty {
                seen.insert(tag)
            }
        }
        return seen.sorted()
    }

    func toggleTagFilter(_ tag: String) {
        if activeTagFilters.contains(tag) {
            activeTagFilters.remove(tag)
        } else {
            activeTagFilters.insert(tag)
        }
        refresh()
    }

    func clearTagFilters() {
        guard !activeTagFilters.isEmpty else { return }
        activeTagFilters.removeAll()
        refresh()
    }
    /// Set when the user taps a page-scoped search result. Read by
    /// the editor's onAppear and translated into a `pendingScrollPageIndex`
    /// so the editor lands on the matching page.
    @Published var deepLinkPageId:                UUID?
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
    private static let contextKey = "library.lastSelectedContext"

    // MARK: Init
    init(storage: StorageService? = nil) {
        // Default `.shared` is nil-resolved inside the body so the
        // `@MainActor`-isolated singleton is touched on the main actor
        // rather than at the call-site (Swift 6 default-value
        // isolation rules).
        self.storage = storage ?? .shared

        // Hydrate the selected context from UserDefaults. First-ever
        // launch (no key) defaults to `.recent` — the redesign's
        // "default home view" surface.
        if let raw = UserDefaults.standard.string(forKey: Self.contextKey),
           let restored = LibraryContext(rawString: raw) {
            self.selectedContext = restored
        }

        refresh()

        $searchText
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] text in self?.performSearch(text) }
            .store(in: &cancellables)

        // Clear selection state, reset folder browsing, refresh the
        // grid, and persist whenever the context changes — covers
        // both subject swaps and recent/all-notes toggles.
        $selectedContext
            .dropFirst()
            .sink { [weak self] context in
                guard let self else { return }
                self.isSelecting = false
                self.selectedNotebookIds = []
                self.folderPath = []
                UserDefaults.standard.set(context.rawString, forKey: Self.contextKey)
                self.refresh()
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

    /// All non-deleted notebooks under a subject — both root-level
    /// and inside folders. Counts via the storage predicate (which
    /// honours `isDeleted == false`) rather than reading
    /// `Subject.notebooks` directly: the SwiftData relationship array
    /// includes soft-deleted rows, and direct `notebook.isDeleted`
    /// reads collide with NSManagedObject's hidden `isDeleted`
    /// property and silently return false. Predicate fetches don't
    /// have that problem.
    func notebookCount(forSubject subjectId: UUID) -> Int {
        storage.fetchNotebooks(subjectId: subjectId).count
    }

    // MARK: Refresh

    func refresh() {
        // Kick off the search index refresh on every library refresh
        // — it's idempotent and cheap for the synchronous metadata
        // (title / TextBlock / transcript). Handwriting OCR is
        // queued internally and runs on a detached Task, so this
        // call never blocks the main actor for more than a fetch.
        SearchIndexService.shared.refreshAll()
        // Phase 4: one-shot embedding backfill on first launch with
        // AI on. Idempotent — bails fast on subsequent launches via
        // its UserDefaults flag.
        SearchIndexService.shared.backfillEmbeddingsIfNeeded()

        subjects        = storage.fetchSubjects()
        folders         = storage.fetchAllFolders()
        let raw: [Notebook]
        switch selectedContext {
        case .recent:
            // Last 12 opened — order is the tracker's ordering
            // (lastAccessedAt desc); skip the user's sort to preserve
            // recency. The grid uses `notebooks` directly so this is
            // what shows up.
            raw = storage.fetchRecentNotebooks(limit: 12)
            notebooks = applyTagFilter(raw)
        case .allNotes:
            raw = storage.fetchAllNotebooks()
            notebooks = sorted(applyTagFilter(raw))
        case .subject(let id):
            raw = storage.fetchNotebooks(subjectId: id)
            notebooks = sorted(applyTagFilter(raw))
        }
        pinnedNotebooks = storage.fetchPinnedNotebooks()
        recentNotebooks = storage.fetchRecentNotebooks(limit: 6)
    }

    /// Apply the active tag filter to a notebook pool. Returns
    /// `pool` unchanged when no filter is active. Tags are stored
    /// inside `tagsRaw` as a `\u{001F}`-joined string, which
    /// SwiftData's `#Predicate` can't iterate as an array — so the
    /// filter step runs in memory. With a few hundred notebooks
    /// this is sub-millisecond; if the library scale grows past
    /// thousands of notebooks the fix is a sidecar `Tag` model.
    private func applyTagFilter(_ pool: [Notebook]) -> [Notebook] {
        guard !activeTagFilters.isEmpty else { return pool }
        let filters = activeTagFilters
        return pool.filter { nb in
            for tag in nb.tags where filters.contains(tag) { return true }
            return false
        }
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
        // Mark the new notebook for auto-customise on open. The
        // editor consumes the mark inside its `.onAppear` and
        // slides the customise panel down so the user can name +
        // style the notebook without an extra tap.
        NewNotebookCustomiseTrigger.mark(nb.id)
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
            if let raw = UserDefaults.standard.string(forKey: "ink.lastUsed.pageSize"),
               let v = PageSize(rawValue: raw) { return v }
            return .a4
        }()
        let template: PageTemplate = {
            // The flat enum persists as its String raw value via
            // `PageTemplate.jsonString` — no JSON encoding wrapper.
            // Decode by raw value rather than `JSONDecoder`.
            guard let raw = UserDefaults.standard.string(forKey: "ink.lastUsed.template")
            else { return .blank }
            return PageTemplate.from(jsonString: raw)
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

    // MARK: - PDF import

    @Published var isImporting:              Bool = false
    @Published var importProgressCompleted:  Int  = 0
    @Published var importProgressTotal:      Int  = 0

    /// Set when a single-PDF import finishes — the LibraryView reads
    /// this to auto-open the new notebook. For multi-PDF imports we
    /// stay in the library so the user can see the whole batch.
    @Published var pendingOpenAfterImport:   Notebook?

    enum PDFImportError: LocalizedError {
        case noSubject
        case allFailed
        case partial(succeeded: Int, total: Int)
        case tooLarge(filename: String, bytes: Int64)
        var errorDescription: String? {
            switch self {
            case .noSubject:
                return "Create a subject first, then import PDFs into it."
            case .allFailed:
                return "Couldn't open any of the selected PDFs."
            case .partial(let s, let t):
                return "\(s) of \(t) PDFs imported. Some files couldn't be opened."
            case .tooLarge(let name, let bytes):
                let mb = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                return "\"\(name)\" is \(mb) — over the 500MB import limit."
            }
        }
    }

    @Published var importError: PDFImportError?

    /// Import each picked PDF as its own notebook. All land in the
    /// currently-selected subject (or the inferred fallback). For a
    /// single PDF the new notebook is opened automatically; for a
    /// batch we surface progress and stay in the library.
    func importPDFs(at urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard let subjectId = inferredSubjectIdForNewNotebook else {
            await MainActor.run { importError = .noSubject }
            return
        }

        await MainActor.run {
            importProgressTotal = urls.count
            importProgressCompleted = 0
            isImporting = true
            importError = nil
        }

        var firstNotebook: Notebook?
        var successCount = 0

        for (index, url) in urls.enumerated() {
            if let nb = await importSinglePDF(at: url, subjectId: subjectId) {
                successCount += 1
                if firstNotebook == nil { firstNotebook = nb }
            }
            await MainActor.run { importProgressCompleted = index + 1 }
        }

        await MainActor.run {
            isImporting = false
            refresh()

            if successCount == 0 {
                importError = .allFailed
            } else if successCount < urls.count {
                importError = .partial(succeeded: successCount, total: urls.count)
            }

            // Auto-open the single-PDF case. Multi-PDF leaves the
            // user in the library viewing the batch.
            if urls.count == 1, let nb = firstNotebook {
                pendingOpenAfterImport = nb
            }
        }
    }

    /// One PDF → one notebook. Copies the PDF into the notebook's
    /// directory, creates a `Page` per PDF page, and records each
    /// page's source-PDF index via `PDFBackingStore`. The
    /// notebook's `pageSize` follows the user's last-used default;
    /// PDF pages render at the source PDF's native bounds via
    /// `PageRenderer` regardless of `pageSize`.
    private func importSinglePDF(at url: URL, subjectId: UUID) async -> Notebook? {
        // Bail on truly enormous files — anything over 500MB is more
        // likely a user mis-pick than a real notebook.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        if fileSize > 500 * 1024 * 1024 {
            await MainActor.run {
                importError = .tooLarge(filename: url.lastPathComponent, bytes: fileSize)
            }
            return nil
        }

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let pdf = PDFDocument(url: url) else { return nil }
        let pageCount = pdf.pageCount
        guard pageCount > 0 else { return nil }

        let rawName = url.deletingPathExtension().lastPathComponent
        let cleanTitle = rawName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleanTitle.isEmpty ? "Imported PDF" : cleanTitle

        let cover = NotebookCover.from(rawValue:
            UserDefaults.standard.string(forKey: "ink.lastUsed.cover"))
        let pageSize: PageSize = {
            if let raw = UserDefaults.standard.string(forKey: "ink.lastUsed.pageSize"),
               let v = PageSize(rawValue: raw) { return v }
            return .a4
        }()

        // Create the notebook first (this seeds page 1). We'll add
        // additional pages below and re-seed `pdfPageIndex` for every
        // page so the seeded one becomes "PDF page 0".
        guard let notebook = try? storage.createNotebook(
            title:         title,
            subjectId:     subjectId,
            coverColorHex: cover.colorHex,
            coverTexture:  cover.texture,
            pageSize:      pageSize,
            template:      .blank
        ) else { return nil }

        // Copy the source PDF into the notebook's directory.
        let dest = StorageService.shared.sourcePDFURL(notebook.id)
        do {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            try? storage.deleteNotebook(notebook)
            return nil
        }

        // Map the seeded first page to PDF page 0; add the rest.
        if let firstPage = (notebook.pages ?? []).first {
            firstPage.pdfPageIndex = 0
        }
        for i in 1..<pageCount {
            guard let page = try? storage.createPage(
                in: notebook,
                after: i,
                pageSize: pageSize,
                backgroundTemplate: .blank
            ) else { continue }
            page.pdfPageIndex = i
        }

        return notebook
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
        // SearchIndexService is the canonical search path — it
        // covers handwriting OCR + titles + text blocks +
        // transcripts via a single on-device index. Falls back
        // gracefully (returns []) if the index hasn't loaded yet.
        let flat = SearchIndexService.shared.search(query: trimmed)
        var grouped = GroupedSearchResults()
        for r in flat {
            switch r.type {
            case .notebookTitle:      grouped.notebookMatches.append(r)
            case .textBlock:          grouped.textBlockMatches.append(r)
            case .transcription,
                 .lectureTranscript:  grouped.transcriptionMatches.append(r)
            case .handwriting:        grouped.handwritingMatches.append(r)
            }
        }
        searchResults = grouped
    }

    // MARK: Notebook lookup (for search results)

    func notebook(id: UUID) -> Notebook? {
        storage.fetchAllNotebooks().first { $0.id == id }
    }
}
