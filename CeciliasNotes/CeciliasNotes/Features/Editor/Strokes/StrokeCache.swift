import Foundation
import PencilKit
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// In-memory LRU cache of decoded `PKDrawing` instances, keyed by
/// `pageId`. Step 8 — Tier 1 of the three-tier caching subsystem.
///
/// **Why it exists.** Decoding a `PKDrawing` from `Data` takes
/// ~5–20ms for a moderately-drawn page on current iPad hardware.
/// Page swipes through a notebook would hitch on every transition
/// if every navigation re-decoded from SwiftData. The cache holds
/// the N most-recently-viewed pages' drawings in memory so swipes
/// land on already-decoded instances.
///
/// **What it isn't.** A render cache. PKCanvasView still owns the
/// rendering; this cache only deals with the decoded `PKDrawing`
/// value. Stroke render cost (PencilKit's own pipeline) is
/// PencilKit's problem.
///
/// **Cache invariants.**
///   • Capacity: `maxEntries` pages (default 20). LRU on insert.
///   • Write-through: `cache(_:forPage:)` overwrites any existing
///     entry and stamps it as most-recently-used.
///   • Invalidation: `invalidate(pageId:)` removes an entry; called
///     from the storage layer after a soft-delete or a wipe.
///   • Memory pressure: `UIApplication.didReceiveMemoryWarningNotification`
///     evicts half the cache (LRU half).
///
/// **What pre-warm does.** Tier 2 (`prewarmNotebook`) decodes the
/// first few pages of a notebook in the background when the editor
/// opens. Tier 3 (`prewarmSubject`) decodes the first page of the
/// most-recently-updated notebook in a subject when the library
/// surfaces it. Both insert into the cache *without* bumping the
/// LRU timestamp past whatever the user is actually looking at, so
/// the user's active page can't be evicted by a background warm.
@MainActor
final class StrokeCache {

    static let shared = StrokeCache()

    private struct Entry {
        let drawing: PKDrawing
        var lastAccessed: Date
    }

    private var entries: [UUID: Entry] = [:]
    private let maxEntries: Int = 20
    private nonisolated(unsafe) var memoryWarningObserver: NSObjectProtocol?

    private init() {
#if os(iOS)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evictHalf() }
        }
#endif
    }

    deinit {
        if let token = memoryWarningObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Read

    /// Cached `PKDrawing` for the given page, or `nil` if not in
    /// the cache. Touches the LRU timestamp on hit.
    func drawing(forPage pageId: UUID) -> PKDrawing? {
        guard var entry = entries[pageId] else { return nil }
        entry.lastAccessed = Date()
        entries[pageId] = entry
        return entry.drawing
    }

    // MARK: - Write

    /// Insert or overwrite the cache entry for `pageId` and stamp
    /// it as most-recently-used. Evicts LRU entries past capacity.
    func cache(_ drawing: PKDrawing, forPage pageId: UUID) {
        entries[pageId] = Entry(drawing: drawing, lastAccessed: Date())
        evictIfNeeded()
    }

    /// Drop the cache entry for `pageId`. No-op if not present.
    func invalidate(pageId: UUID) {
        entries.removeValue(forKey: pageId)
    }

    /// Drop every entry. Used by storage-reset paths and tests.
    func invalidateAll() {
        entries.removeAll()
    }

    // MARK: - Pre-warm

    /// Tier 2 — decode and cache the first `pageCount` pages of a
    /// notebook in the background. Skips pages already in the
    /// cache; inserts new entries without touching the LRU
    /// timestamp of any existing entry. Returns immediately;
    /// decoding happens in a detached Task.
    func prewarmNotebook(
        _ notebookId: UUID,
        pageCount: Int = 5
    ) {
        let limit = pageCount
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runPrewarm(notebookId: notebookId, limit: limit)
        }
    }

    /// Tier 3 — decode and cache the first page of the
    /// most-recently-updated notebook in `subjectId`. Lighter touch
    /// than `prewarmNotebook` for a less-likely-to-be-opened
    /// surface (subject browsing in the library).
    func prewarmSubject(_ subjectId: UUID) {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runPrewarmSubject(subjectId: subjectId)
        }
    }

    // MARK: - Internals

    private func evictIfNeeded() {
        guard entries.count > maxEntries else { return }
        // Drop the single oldest entry. Capacity overshoots are
        // always by 1 because every `cache(_:forPage:)` call
        // either fits or pushes over by exactly one.
        if let oldestId = entries.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })?.key {
            entries.removeValue(forKey: oldestId)
        }
    }

    /// Memory-pressure handler — evicts ~half the cache (the older
    /// half) so the app frees memory without losing the very
    /// most-recently-viewed pages.
    private func evictHalf() {
        guard !entries.isEmpty else { return }
        let sorted = entries.sorted { $0.value.lastAccessed < $1.value.lastAccessed }
        let dropCount = sorted.count / 2
        for (id, _) in sorted.prefix(dropCount) {
            entries.removeValue(forKey: id)
        }
    }

    private func runPrewarm(notebookId: UUID, limit: Int) async {
        // MainActor hop to read SwiftData safely. Decoded drawings
        // get inserted via `cacheWithoutTouchingLRU` so a
        // background warm can't push the user's current page out.
        await MainActor.run {
            let context = StorageService.shared.context
            let descriptor = FetchDescriptor<Page>(
                predicate: #Predicate { $0.notebookId == notebookId && $0.isDeleted == false },
                sortBy: [SortDescriptor(\.pageNumber)]
            )
            guard let pages = try? context.fetch(descriptor) else { return }
            for page in pages.prefix(limit) {
                if entries[page.id] != nil { continue }
                let data = StorageService.shared.strokeData(for: page) ?? Data()
                guard !data.isEmpty, let drawing = try? PKDrawing(data: data) else { continue }
                cacheWithoutTouchingLRU(drawing, forPage: page.id)
            }
        }
    }

    private func runPrewarmSubject(subjectId: UUID) async {
        await MainActor.run {
            let context = StorageService.shared.context
            let nbDesc = FetchDescriptor<Notebook>(
                predicate: #Predicate { $0.subjectId == subjectId && $0.isDeleted == false },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            guard let notebooks = try? context.fetch(nbDesc),
                  let topNotebook = notebooks.first else { return }
            let nbId = topNotebook.id
            let pageDesc = FetchDescriptor<Page>(
                predicate: #Predicate { $0.notebookId == nbId && $0.isDeleted == false },
                sortBy: [SortDescriptor(\.pageNumber)]
            )
            guard let pages = try? context.fetch(pageDesc),
                  let firstPage = pages.first,
                  entries[firstPage.id] == nil else { return }
            let data = StorageService.shared.strokeData(for: firstPage) ?? Data()
            guard !data.isEmpty, let drawing = try? PKDrawing(data: data) else { return }
            cacheWithoutTouchingLRU(drawing, forPage: firstPage.id)
        }
    }

    /// Insert without bumping the LRU timestamp past existing
    /// entries — used by the background pre-warm so the user's
    /// active page can't be evicted by a warm pass. Stamps the new
    /// entry as *older* than every existing entry by 1 second.
    private func cacheWithoutTouchingLRU(_ drawing: PKDrawing, forPage pageId: UUID) {
        let backstamp = (entries.values.map(\.lastAccessed).min() ?? Date())
            .addingTimeInterval(-1)
        entries[pageId] = Entry(drawing: drawing, lastAccessed: backstamp)
        evictIfNeeded()
    }
}
