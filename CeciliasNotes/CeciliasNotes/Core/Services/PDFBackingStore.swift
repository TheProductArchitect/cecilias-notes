import Foundation

/// Side-channel store for PDF-backed notebooks.
///
/// Why a side-channel rather than SwiftData columns:
///   This codebase's V3 schema crashes on column adds in place
///   (see `CeciliasNotesSchemas.swift`). The pattern for new per-notebook /
///   per-page state in this app is a UserDefaults-backed store —
///   `CoverToneStore`, `NotebookPreferencesStore`,
///   `RecentNotebooksTracker` — and this store follows that pattern.
///
/// Two responsibilities:
///   • Mark a notebook as "PDF-backed" — the actual PDF lives at
///     `StorageService.notebookDir(id)/source.pdf` once imported; the
///     boolean is just an existence flag.
///   • Map page UUID → source PDF page index. Reordering changes the
///     page's position in the notebook but the PDF page index sticks
///     to the page itself, so a page imported from PDF position 5
///     stays "PDF page 5" even if the user moves it to be page 1.
enum PDFBackingStore {

    private static let storageKey = "app.notebooks.pdfBackedPages.v1"

    // MARK: Per-page index map

    /// Returns the source PDF page index for `pageId`, or `nil` if
    /// this page isn't backed by a PDF page.
    static func pdfPageIndex(
        for pageId: UUID,
        defaults: UserDefaults = .standard
    ) -> Int? {
        readMap(defaults: defaults)[pageId.uuidString]
    }

    /// Set the source PDF page index for `pageId`. Pass `nil` to
    /// clear (e.g. when a page is hard-deleted).
    static func setPDFPageIndex(
        _ index: Int?,
        for pageId: UUID,
        defaults: UserDefaults = .standard
    ) {
        var map = readMap(defaults: defaults)
        if let index {
            map[pageId.uuidString] = index
        } else {
            map.removeValue(forKey: pageId.uuidString)
        }
        writeMap(map, defaults: defaults)
    }

    /// Drop every entry for the given page IDs in one pass — used by
    /// the hard-delete path when a notebook is purged.
    static func forget(
        pageIds: [UUID],
        defaults: UserDefaults = .standard
    ) {
        guard !pageIds.isEmpty else { return }
        var map = readMap(defaults: defaults)
        for id in pageIds { map.removeValue(forKey: id.uuidString) }
        writeMap(map, defaults: defaults)
    }

    private static func readMap(defaults: UserDefaults) -> [String: Int] {
        guard let raw  = defaults.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let map  = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return map
    }

    private static func writeMap(_ map: [String: Int], defaults: UserDefaults) {
        if map.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(json, forKey: storageKey)
    }
}
