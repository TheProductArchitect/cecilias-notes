import CoreSpotlight
import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - SpotlightService

/// Indexes notebooks into the system Spotlight index. Indexing is debounced
/// (5s after last save) and runs off the main actor. Soft-deletes remove the
/// index entry immediately.
///
/// Deep-link contract: `uniqueIdentifier == "ceciliasnotes.notebook.{uuid}"`.
/// `CeciliasNotesApp.onContinueUserActivity` parses this and routes to the editor.
actor SpotlightService {

    static let shared = SpotlightService()

    private static let domain = "ceciliasnotes.notebooks"
    private static let prefix = "ceciliasnotes.notebook."

    // Debounce — id → pending task
    private var pending: [UUID: Task<Void, Never>] = [:]

    // MARK: Public API

    /// Index immediately. Use `scheduleIndex(_:)` for debounced calls from save paths.
    func indexNotebook(
        id: UUID,
        title: String,
        subjectName: String?,
        pageCount: Int,
        thumbnailData: Data?,
        createdAt: Date,
        updatedAt: Date,
        tags: [String] = []
    ) async {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.data)
        attrs.title              = title
        attrs.contentDescription = "Notebook — \(pageCount) page\(pageCount == 1 ? "" : "s")"
        attrs.keywords           = tags + [subjectName].compactMap { $0 }
        attrs.thumbnailData      = thumbnailData
        attrs.lastUsedDate       = updatedAt
        attrs.contentCreationDate = createdAt

        let item = CSSearchableItem(
            uniqueIdentifier: Self.identifier(for: id),
            domainIdentifier: Self.domain,
            attributeSet: attrs
        )

        do {
            try await CSSearchableIndex.default().indexSearchableItems([item])
        } catch {
            // Index failures are non-fatal — never propagate to UI
        }
    }

    /// Removes a notebook's Spotlight entry immediately. Called on soft-delete.
    func removeNotebook(id: UUID) async {
        do {
            try await CSSearchableIndex.default()
                .deleteSearchableItems(withIdentifiers: [Self.identifier(for: id)])
        } catch {
            // Same as above — non-fatal.
        }
    }

    /// Removes ALL CeciliasNotes-domain entries (e.g. on account reset, signing out of iCloud).
    func removeAllNotebooks() async {
        try? await CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [Self.domain])
    }

    /// Debounced re-index — coalesces rapid saves into a single index call after 5s of inactivity.
    func scheduleIndex(
        id: UUID,
        title: String,
        subjectName: String?,
        pageCount: Int,
        thumbnailData: Data?,
        createdAt: Date,
        updatedAt: Date,
        tags: [String] = []
    ) {
        pending[id]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.indexNotebook(
                id: id,
                title: title,
                subjectName: subjectName,
                pageCount: pageCount,
                thumbnailData: thumbnailData,
                createdAt: createdAt,
                updatedAt: updatedAt,
                tags: tags
            )
            await self?.clearPending(id: id)
        }
        pending[id] = task
    }

    private func clearPending(id: UUID) {
        pending[id] = nil
    }

    // MARK: Identifier helpers

    static func identifier(for notebookId: UUID) -> String {
        "\(prefix)\(notebookId.uuidString)"
    }

    /// Parses an identifier produced by `identifier(for:)`. Returns nil if not ours.
    static func notebookId(fromIdentifier id: String) -> UUID? {
        guard id.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(prefix.count)))
    }
}
