import Combine
import Foundation
import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Supporting types

enum NotebookSortOrder: String, CaseIterable, Identifiable {
    case lastModified  = "Last Modified"
    case created       = "Date Created"
    case alphabeticalAZ = "Name A–Z"
    case alphabeticalZA = "Name Z–A"
    case manual        = "Manual Order"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .lastModified:    return "clock"
        case .created:         return "calendar"
        case .alphabeticalAZ:  return "textformat.abc"
        case .alphabeticalZA:  return "textformat.abc"
        case .manual:          return "hand.draw"
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

/// Distinct payload for subject drag-reorder. Uses a different JSON
/// key (`subjectId`) than `NotebookTransferID` (`id`) so a row's
/// single Data-typed drop destination can disambiguate by trying
/// each decode in turn — neither type accidentally decodes the
/// other's payload (Codable requires every declared key to be
/// present).
struct SubjectTransferID: Transferable, Codable {
    let subjectId: UUID
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
    @Published var selectedContext: LibraryContext = .recent {
        didSet {
            // Any context switch leaves the Trash surface. The
            // sidebar's other rows assign to `selectedContext`, so
            // this didSet is the single chokepoint for that exit.
            if isShowingTrash { isShowingTrash = false }
            // A subject/recent/all selection also leaves a selected
            // quiz — the grid and the quiz detail are mutually
            // exclusive surfaces.
            if selectedQuizID != nil { selectedQuizID = nil }
        }
    }

    /// The quiz selected in the sidebar's Quizzes section, or `nil`.
    /// When non-nil, `LibraryView` shows `QuizDetailView` instead of
    /// the notebook grid. Selecting a quiz leaves the Trash surface;
    /// selecting a context/trash row clears this (see `selectedContext`
    /// didSet and the quiz row's tap handler).
    @Published var selectedQuizID: UUID? {
        didSet {
            if selectedQuizID != nil && isShowingTrash { isShowingTrash = false }
        }
    }

    /// Drives the quiz builder sheet, presented by `LibraryView` and
    /// raised by the sidebar's "+ new quiz" button.
    @Published var isShowingQuizBuilder: Bool = false
    /// When set, the quiz builder opens scoped to this notebook.
    @Published var quizBuilderPreselectedNotebookID: UUID?

    /// True when the library is showing the Trash surface instead
    /// of the notebook grid. Toggled by the sidebar's "trash" row.
    /// Not persisted — relaunching always lands on the notebook grid.
    @Published var isShowingTrash: Bool = false {
        didSet {
            // Entering Trash leaves any selected quiz behind — the
            // sidebar's "trash" row is the active surface and only
            // one row should read as selected at a time. Mirrors
            // the `selectedContext` didSet's mutually-exclusive
            // discipline; without it, a previously-selected quiz
            // row stays bolded while the user is viewing Trash.
            if isShowingTrash, selectedQuizID != nil {
                selectedQuizID = nil
            }
        }
    }

    /// Live count of soft-deleted records across every entity type.
    /// Drives the sidebar's "trash (N)" badge. Refreshed by
    /// `refresh()` and by `TrashView` after every mutation.
    @Published private(set) var trashCount: Int = 0

    func refreshTrashCount() {
        trashCount = TrashService.shared.itemCount()
    }

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
#if os(macOS)
    /// Notebook open in the main library window (default navigation).
    @Published var macInlineNotebookId: UUID?
    /// Opens a dedicated editor window (context menu / ⌘-click).
    @Published var macOpenInNewWindowId: UUID?
#endif
    /// macOS grid keyboard focus for Space quick-look (Finder idiom).
    @Published var macGridFocusedNotebookId: UUID?
    @Published var isMacQuickLookPresented = false
    /// macOS sidebar smart list filter (Today / This week / …).
    @Published var macSmartList: MacSmartList?
    @Published var searchText: String = ""
    @Published var sortOrder: NotebookSortOrder = .lastModified
    @Published var isSelecting: Bool = false
    @Published var selectedNotebookIds: Set<UUID> = []
    /// Selection state for the All Subjects file-system surface.
    /// Parallel to `selectedNotebookIds`; the same top-bar select
    /// chip toggles `isSelecting` for whichever context the user
    /// is in, and the bottom selecting-strip reads the right ID
    /// set based on `selectedContext`.
    @Published var selectedSubjectIds: Set<UUID> = []
    /// Same pattern for the All Quizzes surface.
    @Published var selectedQuizIds: Set<UUID> = []

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
        guard DeviceCapabilities.canCreateInLibrary else { return }
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
        // No notebook pool for these surfaces — they list subjects
        // / quizzes directly, not notebooks. Tag filter is hidden
        // for both via shouldAllowNotebookCreation guards upstream.
        case .allSubjects:      pool = []
        case .allQuizzes:       pool = []
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
    private static let sortKey    = "library.sort.option"

    /// Image-picker presentation state. Non-nil presents the
    /// picker from the library root via `.sheet(item:)` —
    /// crucially OUTSIDE the editor's `.fullScreenCover` so the
    /// editor's navigation surface is untouched by picker
    /// dismiss/present cycles. Cross-VM communication runs
    /// through the `.imageImportRequested` /
    /// `.imageImportCompleted` / `.imageImportCancelled`
    /// notifications declared in `ImageImportNotifications.swift`.
    @Published var pendingImageImport: PendingImageImport?

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

        // Hydrate the user's last-chosen sort option. Default remains
        // `.lastModified` for first-ever launch (or if the stored
        // value no longer maps to a valid case after an enum change).
        if let rawSort = UserDefaults.standard.string(forKey: Self.sortKey),
           let restoredSort = NotebookSortOrder(rawValue: rawSort) {
            self.sortOrder = restoredSort
        }

        refresh()

        $searchText
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] text in self?.performSearch(text) }
            .store(in: &cancellables)

        // Clear selection state, reset folder browsing, refresh the
        // grid, and persist whenever the context changes — covers
        // both subject swaps and recent/all-notes toggles.
        //
        // CRITICAL: `@Published` emits in `willSet`, so inside this
        // sink `self.selectedContext` still reads the OLD value.
        // `refresh()` switches on `selectedContext` to pick the right
        // fetch path, so calling it synchronously here populates
        // `notebooks` for the *previous* context — the symptom is
        // "tap a subject, see the prior subject's notebooks; tap
        // again, see the correct ones." Deferring with
        // `DispatchQueue.main.async` lands the work after `didSet`,
        // by which point `self.selectedContext` reflects the new
        // value.
        $selectedContext
            .dropFirst()
            .sink { [weak self] context in
                guard let self else { return }
                self.isSelecting = false
                self.selectedNotebookIds = []
                self.folderPath = []
                UserDefaults.standard.set(context.rawString, forKey: Self.contextKey)
                // Subject swap only changes the grid — sidebar
                // caches and the search index are independent of
                // the active context, so this navigation event
                // skips the heavy fetches. See `refresh()` for the
                // full-fat path used on launch / mutations.
                DispatchQueue.main.async {
                    self.refreshNotebooksOnly()
                }
            }
            .store(in: &cancellables)

        #if DEBUG
        // Refresh after the debug "generate N notebooks" / "wipe all"
        // affordances complete — without this, the user sees a
        // freshly-seeded library still rendering the pre-seed state
        // and assumes the seeder hung.
        NotificationCenter.default.publisher(for: .syntheticDataDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        #endif

        // Release-safe full-reset path (Settings → iCloud → Reset
        // all iCloud data). Drop every cached list + reset selection
        // back to .recent so the user lands on a clean grid instead
        // of a stale subject view that no longer exists.
        NotificationCenter.default.publisher(for: .userDataReset)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.selectedContext = .recent
                self.selectedQuizID = nil
                self.selectedSubjectId = nil
                self.selectedNotebookIds = []
                self.selectedSubjectIds = []
                self.selectedQuizIds = []
                self.refresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: MultipeerNotebookHint.changedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        $sortOrder
            .dropFirst()
            .sink { [weak self] order in
                UserDefaults.standard.set(order.rawValue, forKey: Self.sortKey)
                // Defer refresh + seed for the same reason as
                // `$selectedContext` above — `@Published` emits in
                // `willSet`, and refresh fetches/assigns several
                // @Published arrays. Running synchronously here can
                // race the view-update transaction triggered by the
                // sort-picker tap and produce the "Publishing
                // changes from within view updates" warning.
                DispatchQueue.main.async {
                    if order == .manual { self?.seedManualOrderIfNeeded() }
                    // Sort change is grid-only — sidebar caches
                    // don't depend on the sort order.
                    self?.refreshNotebooksOnly()
                }
            }
            .store(in: &cancellables)

        // Image-import signal channel — iOS only (UIKit picker).
#if os(iOS)
        NotificationCenter.default.publisher(for: .imageImportRequested)
            .sink { note in
                let normX = (note.userInfo?[ImageImportUserInfoKey.normalizedX] as? Double) ?? 0.5
                let normY = (note.userInfo?[ImageImportUserInfoKey.normalizedY] as? Double) ?? 0.5
                let sourceRaw = note.userInfo?[ImageImportUserInfoKey.source] as? String
                let source    = sourceRaw.flatMap(ImageImportSource.init(rawValue:)) ?? .photos
                #if DEBUG
                dlog("[ImagePicker] LibraryViewModel observed .imageImportRequested — about to present source=\(source.rawValue) at norm=(\(normX),\(normY))")
                #endif
                if source == .camera {
                    MediaPickerPresenter.presentCamera(
                        completion: { image in
                            NotificationCenter.default.post(
                                name: .imageImportCompleted,
                                object: nil,
                                userInfo: [
                                    ImageImportUserInfoKey.image:       image,
                                    ImageImportUserInfoKey.ext:         "jpg",
                                    ImageImportUserInfoKey.normalizedX: normX,
                                    ImageImportUserInfoKey.normalizedY: normY,
                                ]
                            )
                        },
                        onCancel: {
                            NotificationCenter.default.post(
                                name: .imageImportCancelled,
                                object: nil
                            )
                        }
                    )
                    return
                }
                MediaPickerPresenter.presentPhotoPicker(
                    completion: { images in
                        // No images = user dismissed without picking;
                        // treat as a cancel so any pending UI state
                        // clears.
                        guard let first = images.first else {
                            NotificationCenter.default.post(
                                name: .imageImportCancelled,
                                object: nil
                            )
                            return
                        }
                        // The editor's `imageImportCompleted` observer
                        // takes one image at a time. Surface only the
                        // first picked image — the picker supports
                        // multi-select but the toolbar import lands a
                        // single attachment at the page-centre coords.
                        NotificationCenter.default.post(
                            name: .imageImportCompleted,
                            object: nil,
                            userInfo: [
                                ImageImportUserInfoKey.image:       first,
                                ImageImportUserInfoKey.ext:         "jpg",
                                ImageImportUserInfoKey.normalizedX: normX,
                                ImageImportUserInfoKey.normalizedY: normY,
                            ]
                        )
                    },
                    onCancel: {
                        NotificationCenter.default.post(
                            name: .imageImportCancelled,
                            object: nil
                        )
                    }
                )
            }
            .store(in: &cancellables)
#endif

        // The picker no longer routes through `pendingImageImport`
        // for the toolbar path — UIKit-direct presentation
        // bypasses the SwiftUI sheet entirely. Keep the
        // `pendingImageImport = nil` resets in place anyway so the
        // canvas-tap path (which still uses
        // `LibraryView.sheet(item:)`) continues to work.
#if os(iOS)
        NotificationCenter.default.publisher(for: .imageImportCompleted)
            .sink { [weak self] _ in self?.pendingImageImport = nil }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .imageImportCancelled)
            .sink { [weak self] _ in self?.pendingImageImport = nil }
            .store(in: &cancellables)
#endif
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

    /// Full refresh — sidebar + notebooks + search index. Use this
    /// for entry points where every cache may be stale (app launch,
    /// mutation completion, sync-applied changes). For navigation
    /// events where only the active grid changes (subject swap,
    /// sort change), call `refreshNotebooksOnly()` instead — that
    /// path skips the sidebar fetches and the search-index walk,
    /// which dominate refresh time at library scale.
    func refresh() {
        #if DEBUG
        let __refreshStart = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - __refreshStart) * 1000
            if ms > 50 {
                dlog("[LibraryVM] refresh slow: \(String(format: "%.0f", ms)) ms ctx=\(selectedContext)")
            }
        }
        #endif
        // Schedule the search-index refresh off the main runloop so
        // it never blocks subject swaps or first paint. `refreshAll`
        // is itself synchronous over SwiftData reads, but at
        // 1000-notebook scale it's hundreds of ms; off-actor work
        // doesn't apply here (the store is main-isolated), but a
        // `DispatchQueue.main.async` lets the navigation paint
        // first and runs the index walk in the next runloop tick.
        DispatchQueue.main.async {
            SearchIndexService.shared.refreshAll()
            SearchIndexService.shared.backfillEmbeddingsIfNeeded()
        }

        refreshSidebar()
        refreshNotebooksOnly()
        refreshTrashCount()
    }

    /// Sidebar caches: subjects, folders, pinned, recents. Used by
    /// the library sidebar and the recents rail — independent of
    /// the active grid context, so navigation events don't need to
    /// pay this cost.
    func refreshSidebar() {
        // CloudKit and SwiftData occasionally surface duplicate
        // rows; ForEach on iOS 26 hard-crashes on dupe IDs, so
        // every collection that reaches the view layer is deduped.
        subjects        = dedupedById(storage.fetchSubjects())
        folders         = dedupedById(storage.fetchAllFolders())
        pinnedNotebooks = dedupedById(storage.fetchPinnedNotebooks())
        recentNotebooks = dedupedById(storage.fetchRecentNotebooks(limit: 6))
    }

    /// Just the active grid — fetches for the current
    /// `selectedContext`. Cheap regardless of total library size
    /// when the context is `.subject` or `.recent` because each
    /// uses a bounded predicate; `.allNotes` still loads every
    /// row because that's its semantics.
    func refreshNotebooksOnly() {
        let raw: [Notebook]
        if let smart = macSmartList {
            let pool = storage.fetchAllNotebooks().filter { !$0.isDeleted }
            let filtered = Self.notebooksMatching(smart, in: pool, storage: storage)
            notebooks = dedupedById(sorted(applyTagFilter(filtered)))
            return
        }
        switch selectedContext {
        case .recent:
            raw = storage.fetchRecentNotebooks(limit: 12)
            notebooks = dedupedById(applyTagFilter(raw))
        case .allNotes:
            raw = storage.fetchAllNotebooks()
            notebooks = dedupedById(sorted(applyTagFilter(raw)))
        case .subject(let id):
            raw = storage.fetchNotebooks(subjectId: id)
            notebooks = dedupedById(sorted(applyTagFilter(raw)))
        // .allSubjects / .allQuizzes don't drive the notebook grid —
        // LibraryView switches to AllSubjectsView / AllQuizzesView
        // instead. Clear the pool so a stale grid doesn't briefly
        // flash during the context transition.
        case .allSubjects, .allQuizzes:
            notebooks = []
        }
    }

    func selectMacSmartList(_ list: MacSmartList) {
        macSmartList = list
        selectedContext = .allNotes
        selectedQuizID = nil
        isShowingTrash = false
        refreshNotebooksOnly()
    }

    func clearMacSmartList() {
        guard macSmartList != nil else { return }
        macSmartList = nil
        refreshNotebooksOnly()
    }

    private static func notebooksMatching(
        _ list: MacSmartList,
        in pool: [Notebook],
        storage: StorageService
    ) -> [Notebook] {
        let calendar = Calendar.current
        switch list {
        case .today:
            return pool.filter {
                calendar.isDateInToday($0.updatedAt)
                    || (RecentNotebooksTracker.lastOpened($0.id).map { calendar.isDateInToday($0) } ?? false)
            }
        case .thisWeek:
            guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) else { return pool }
            return pool.filter { $0.updatedAt >= weekAgo }
        case .untagged:
            return pool.filter(\.tags.isEmpty)
        case .recording:
            let ids = storage.notebookIdsContainingAudio()
            return pool.filter { ids.contains($0.id) }
        }
    }

    private func dedupedById<T: Identifiable>(_ items: [T]) -> [T] where T.ID: Hashable {
        var seen: Set<T.ID> = []
        var out: [T] = []
        out.reserveCapacity(items.count)
        for item in items where seen.insert(item.id).inserted {
            out.append(item)
        }
        return out
    }

    /// Apply the active tag filter to a notebook pool. Returns
    /// `pool` unchanged when no filter is active.
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
        let pinned = notebooks.filter(\.isPinned)
        let unpinned = notebooks.filter { !$0.isPinned }
        return sortWithinGroup(pinned) + sortWithinGroup(unpinned)
    }

    private func sortWithinGroup(_ notebooks: [Notebook]) -> [Notebook] {
        switch sortOrder {
        case .lastModified:    return notebooks.sorted { $0.updatedAt > $1.updatedAt }
        case .created:         return notebooks.sorted { $0.createdAt > $1.createdAt }
        case .alphabeticalAZ:  return notebooks.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        case .alphabeticalZA:  return notebooks.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending
        }
        case .manual:          return notebooks.sorted { $0.sortOrder < $1.sortOrder }
        }
    }

    // MARK: - Subjects

    func createSubject() {
        guard DeviceCapabilities.canCreateInLibrary else { return }
        guard let subject = try? storage.createSubject(
            name: "New Subject",
            colorHex: CeciliasNotesColorPresets.subjectColors[6]
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

    func deleteSubject(_ subject: Subject, moveNotebooksToUnfiled: Bool = false) {
        do {
            try storage.deleteSubject(subject, moveNotebooksToUnfiled: moveNotebooksToUnfiled)
        } catch {
            showError(.storageFailed(action: "delete subject", underlying: error))
            refresh()
            return
        }
        if selectedSubjectId == subject.id { selectedSubjectId = nil }
        refresh()
    }

    /// Toggle a subject's pinned state. Pinned subjects float to the
    /// top of the sidebar above unpinned subjects, separated by a
    /// hairline. Order within each group is `Subject.sortOrder`.
    func togglePinSubject(_ subject: Subject) {
        try? storage.setSubjectPinned(subject, isPinned: !subject.isPinned)
        refresh()
    }

    func reorderSubjects(from source: IndexSet, to destination: Int) {
        var ordered = subjects
        ordered.move(fromOffsets: source, toOffset: destination)
        try? storage.reorderSubjects(ordered)
        refresh()
    }

    /// Reorder subjects by moving `sourceId` so it lands just BEFORE
    /// `targetId`. Pinning is preserved — pinned and unpinned groups
    /// only reorder within themselves (a drag across the hairline is
    /// a no-op). Called from the sidebar's drag-handle drop target.
    func reorderSubject(movedId sourceId: UUID, before targetId: UUID) {
        guard sourceId != targetId else { return }
        guard let source = subjects.first(where: { $0.id == sourceId }),
              let target = subjects.first(where: { $0.id == targetId })
        else { return }
        // A drag from pinned → unpinned (or vice versa) is ignored.
        // To move between groups the user must pin/unpin first.
        guard source.isPinned == target.isPinned else { return }
        var group = subjects.filter { $0.isPinned == source.isPinned }
        guard let from = group.firstIndex(where: { $0.id == sourceId }),
              let to   = group.firstIndex(where: { $0.id == targetId })
        else { return }
        let moved = group.remove(at: from)
        let insertAt = to > from ? to - 1 : to
        group.insert(moved, at: insertAt)
        try? storage.reorderSubjects(group)
        refresh()
    }

    // MARK: - Notebook manual ordering

    /// One-shot seeding when the user switches sort to manual for
    /// the first time within the current context. If every visible
    /// notebook still has the additive default (`sortOrder == 0`),
    /// assign sequential values matching the current display order
    /// so the grid stays put when manual mode lights up.
    fileprivate func seedManualOrderIfNeeded() {
        let visible = notebooksAtCurrentLevel
        guard !visible.isEmpty else { return }
        let needsSeed = visible.allSatisfy { $0.sortOrder == 0 }
        guard needsSeed else { return }
        try? storage.reorderNotebooks(visible)
    }

    /// Move `sourceId` so it lands immediately before `targetId` in
    /// the current display slice. Persists the new `sortOrder` for
    /// every affected notebook in a single batch write. A drop on
    /// the source itself is a no-op.
    func reorderNotebook(movedId sourceId: UUID, before targetId: UUID) {
        guard sourceId != targetId else { return }
        var slice = notebooksAtCurrentLevel
        guard let from = slice.firstIndex(where: { $0.id == sourceId }),
              let to   = slice.firstIndex(where: { $0.id == targetId })
        else { return }
        let moved = slice.remove(at: from)
        let insertAt = to > from ? to - 1 : to
        slice.insert(moved, at: insertAt)
        try? storage.reorderNotebooks(slice)
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
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
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

        let cover    = NotebookCover.from(rawValue: UserDefaults.standard.string(forKey: "ceciliasnotes.lastUsed.cover"))
        let pageSize: PageSize = {
            if let raw = UserDefaults.standard.string(forKey: "ceciliasnotes.lastUsed.pageSize"),
               let v = PageSize(rawValue: raw) { return v }
            return .a4
        }()
        // New notebooks always start at `.blank`. The "set as default
        // for future pages" toggle inside an existing notebook's Add
        // Page picker pins ONLY that notebook's `defaultTemplate` —
        // it must not leak into freshly-created notebooks. The legacy
        // `ceciliasnotes.lastUsed.template` global key is no longer
        // written; the read here is intentionally removed.
        let template: PageTemplate = .blank

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
    /// page's source-PDF index via a per-page
    /// `PageElement(kind: .pdfPage)` row that fills the page at
    /// zIndex 0. The notebook's `pageSize` follows the user's
    /// last-used default; PDF pages render at the source PDF's
    /// native bounds via `PDFPageElementView`, scaled to fit
    /// inside the canvas page.
    ///
    /// Step 5.5: rewired off `PDFBackingStore` /
    /// `StorageService.sourcePDFURL` onto the unified element
    /// model. The PDF file lands in
    /// `MediaStorage.pdfs/<pdfDocumentId>.pdf` (shared, hash-
    /// deduped — re-importing the same PDF reuses the file).
    private func importSinglePDF(at url: URL, subjectId: UUID) async -> Notebook? {
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

        guard let pdfData = try? Data(contentsOf: url),
              let pdf = PDFDocument(url: url) else { return nil }
        let pageCount = pdf.pageCount
        guard pageCount > 0 else { return nil }

        // Hash + dedup the file into MediaStorage. Re-imports of
        // the same PDF resolve to the same `pdfDocumentId` so
        // every PDFPageContent created below shares one file.
        let pdfHash = MediaStorage.sha256Hex(of: pdfData)
        let pdfDocumentId = MediaStorage.writePDF(from: pdfData, hash: pdfHash)

        let rawName = url.deletingPathExtension().lastPathComponent
        let cleanTitle = rawName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTitle = cleanTitle.isEmpty ? "Imported PDF" : cleanTitle
        // Disambiguate re-imports of the same PDF with " Copy",
        // " Copy 2", etc. so the library doesn't show multiple
        // entries with identical titles.
        let existingTitles = Set(storage.fetchAllNotebooks().map(\.title))
        let title: String = {
            if !existingTitles.contains(baseTitle) { return baseTitle }
            let copyOne = "\(baseTitle) Copy"
            if !existingTitles.contains(copyOne) { return copyOne }
            var n = 2
            while existingTitles.contains("\(baseTitle) Copy \(n)") { n += 1 }
            return "\(baseTitle) Copy \(n)"
        }()

        let cover = NotebookCover.from(rawValue:
            UserDefaults.standard.string(forKey: "ceciliasnotes.lastUsed.cover"))
        let pageSize: PageSize = {
            if let raw = UserDefaults.standard.string(forKey: "ceciliasnotes.lastUsed.pageSize"),
               let v = PageSize(rawValue: raw) { return v }
            return .a4
        }()

        guard let notebook = try? storage.createNotebook(
            title:         title,
            subjectId:     subjectId,
            coverColorHex: cover.colorHex,
            coverTexture:  cover.texture,
            pageSize:      pageSize,
            template:      .blank
        ) else { return nil }
        // PDF-imported notebooks don't surface the floating Customise
        // pill — the user picked a file, not a cover/template.
        // Guarded because `EditorViewModel` lives in the iOS UI
        // target; Mac's editor is a distinct implementation and
        // doesn't render the floating pill, so the suppression is
        // an iOS-only presentation hint.
        #if canImport(UIKit)
        EditorViewModel.suppressCustomisePill(for: notebook.id)
        #endif

        // Seed page 1's PDFPageContent + PageElement, then create
        // remaining pages and seed each one. The first canvas
        // page already exists (createNotebook seeds it); the
        // rest get created on demand below.
        let context = StorageService.shared.context
        if let firstPage = (notebook.pages ?? []).first,
           let pdfPage = pdf.page(at: 0) {
            attachPDFPageElement(
                to: firstPage,
                notebookId: notebook.id,
                pdfDocumentId: pdfDocumentId,
                pageIndex: 0,
                pdfPage: pdfPage,
                context: context
            )
        }
        for i in 1..<pageCount {
            guard let page = try? storage.createPage(
                in: notebook,
                after: i,
                pageSize: pageSize,
                backgroundTemplate: .blank
            ) else { continue }
            guard let pdfPage = pdf.page(at: i) else { continue }
            attachPDFPageElement(
                to: page,
                notebookId: notebook.id,
                pdfDocumentId: pdfDocumentId,
                pageIndex: i,
                pdfPage: pdfPage,
                context: context
            )
        }
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[LibraryVM] PDF import SAVE FAILED notebookId=\(notebook.id) pageCount=\(pageCount): \(error)")
            #endif
        }
        // `pdfPageElementsChanged` is defined on the iOS
        // `PDFPageElementsOverlayView` (Mac uses a distinct overlay
        // renderer). The notification is a UI-refresh nudge; posting
        // the raw name works cross-platform without pulling the
        // overlay view into the Mac target.
        NotificationCenter.default.post(
            name: Notification.Name("pdfPageElementsChanged"),
            object: nil
        )

        return notebook
    }

    /// Workflow A helper: create one `PageElement(.pdfPage) +
    /// PDFPageContent` at zIndex 0 filling `page` (normalised
    /// bounds (0, 0, 1, 1)). The PDF file is already deduped /
    /// written; this only writes SwiftData metadata + the
    /// preview PNG. Same shape as Workflow B's
    /// `PDFReferenceImporter` but per-Page rather than per-
    /// selected-page.
    private func attachPDFPageElement(
        to page: Page,
        notebookId: UUID,
        pdfDocumentId: UUID,
        pageIndex: Int,
        pdfPage: PDFPage,
        context: ModelContext
    ) {
        let bounds = pdfPage.bounds(for: .mediaBox)
        let preview = pdfPage.thumbnail(of: CGSize(width: 400, height: 520), for: .mediaBox)
        let contentId = UUID()
        let previewName = MediaStorage.writePDFPreview(preview, contentId: contentId)

        let element = PageElement(
            id: UUID(),
            pageId: page.id,
            notebookId: notebookId,
            kind: .pdfPage,
            normalizedX: 0,
            normalizedY: 0,
            normalizedWidth: 1,
            normalizedHeight: 1,
            zIndex: 0
        )
        // Pull the embedded text layer so quiz generation can read
        // the PDF without an OCR pass at runtime. Returns nil for
        // image-only / scanned PDFs — those drop through to the
        // higher tiers.
        let extracted: String? = {
            guard let raw = pdfPage.string else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let content = PDFPageContent(
            id: contentId,
            pdfDocumentId: pdfDocumentId,
            pageIndex: pageIndex,
            originalPageWidth: Double(bounds.width),
            originalPageHeight: Double(bounds.height),
            previewImageFilename: previewName,
            extractedText: extracted
        )
        element.pdfPageContent = content
        context.insert(element)
    }

    func renameNotebook(_ notebook: Notebook, newTitle: String) {
        guard DeviceCapabilities.canMutate else { return }
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
        guard DeviceCapabilities.canMutate else { return }
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
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
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
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

    /// Batch-delete from `selectedSubjectIds`. Used by AllSubjectsView
    /// + the top-bar selecting strip when the user is in
    /// `.allSubjects` context. Cascades through `storage.deleteSubject`
    /// so every notebook owned by each deleted subject is soft-
    /// deleted too (and lands in trash).
    ///
    /// Mirrors `deleteSelectedNotebooks`: explicit error capture (the
    /// previous `try?` silently swallowed save failures, which is the
    /// "multi-select subject delete doesn't work" symptom — under
    /// CloudKit contention the soft-delete write can fail and the
    /// user saw nothing), in-memory cache pruning so the sidebar
    /// updates immediately, and `refresh()` on either path so any
    /// rows that didn't actually delete come back into the list
    /// instead of stranding in the UI.
    func deleteSelectedSubjects() {
        let ids = selectedSubjectIds
        var firstError: Error?
        let targets = storage.fetchSubjects().filter { ids.contains($0.id) }
        for subject in targets {
            do {
                try storage.deleteSubject(subject)
                if selectedSubjectId == subject.id { selectedSubjectId = nil }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
            subjects.removeAll { ids.contains($0.id) }
        }
        isSelecting = false
        selectedSubjectIds = []
        if let firstError {
            showError(.storageFailed(action: "delete subjects", underlying: firstError))
        }
        refresh()
    }

    /// Same shape as `deleteSelectedSubjects` for the quiz surface.
    /// Uses SwiftData's hard delete (matches the existing per-row
    /// `QuizSidebarRow` deletion) so questions + attempts cascade.
    /// Errors are surfaced — the prior `try? ctx.save()` would
    /// silently drop a failed batch save and the user would see
    /// the rows return on the next sidebar refresh.
    func deleteSelectedQuizzes() {
        let ids = selectedQuizIds
        let ctx = storage.context
        let descriptor = FetchDescriptor<Quiz>(
            predicate: #Predicate<Quiz> { quiz in true }
        )
        let all = (try? ctx.fetch(descriptor)) ?? []
        for quiz in all where ids.contains(quiz.id) {
            if selectedQuizID == quiz.id { selectedQuizID = nil }
            ctx.delete(quiz)
        }
        do {
            try ctx.save()
        } catch {
            showError(.storageFailed(action: "delete quizzes", underlying: error))
        }
        isSelecting = false
        selectedQuizIds = []
        refresh()
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
