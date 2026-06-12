import XCTest
import SwiftData
@testable import CeciliasNotes

/// Pure tests for the importer's `pageWriteStrategy(for:existing:)`
/// decision. These exercise the optimistic-concurrency contract
/// added in inkbook v1.1: `mcp_action` + `base_updated_at`. The full
/// persist round-trip is covered separately; these tests pin down
/// the decision matrix so a future tweak to the back-compat path
/// can't silently regress the "MCP appends after iPad edit"
/// preservation case.
@MainActor
final class InkbookImporterStrategyTests: XCTestCase {

    private let iso = ISO8601DateFormatter()

    // MARK: - Helpers

    private func makeFile(
        action: String?,
        baseUpdatedAt: String?,
        updatedAt: String = "2026-06-10T10:00:00Z",
        pages: [CeciliasNotesFile.PageNode] = []
    ) -> CeciliasNotesFile {
        CeciliasNotesFile(
            schema: nil,
            version: "1",
            id: UUID().uuidString,
            title: "n",
            subject: "s",
            created_at: "2026-06-10T09:00:00Z",
            updated_at: updatedAt,
            cover_tone: nil,
            page_template: nil,
            page_size: nil,
            agent: nil,
            pages: pages,
            mcp_action: action,
            base_updated_at: baseUpdatedAt
        )
    }

    private func makeNotebook(updatedAt: Date) -> Notebook {
        let nb = Notebook(
            title: "n",
            subjectId: nil,
            coverColorHex: "",
            coverTexture: .none,
            pageSize: .a4,
            defaultTemplate: .blank
        )
        nb.updatedAt = updatedAt
        return nb
    }

    // MARK: - Cases

    /// **No existing notebook** — always replace regardless of
    /// action. The MCP could have lost track of state; we accept
    /// what it sends as the authoritative source.
    func test_missingNotebook_alwaysReplace() {
        let importer = CeciliasNotesImporter.shared
        for action in ["create", "append", "replace", "future-verb"] as [String?] + [nil] {
            let file = makeFile(action: action, baseUpdatedAt: "2026-06-10T09:55:00Z")
            XCTAssertEqual(
                importer.pageWriteStrategy(for: file, existing: nil),
                .replace,
                "missing notebook should always replace (action=\(action ?? "nil"))"
            )
        }
    }

    /// **No `mcp_action`** (older MCP / non-MCP writer) — post-v1.2
    /// default is **id-merge**, not wholesale replace. Older
    /// behaviour clobbered iPad-side edits when an MCP wrote with
    /// a stale view of the mirror; id-merge is the safer landing
    /// spot for any writer that doesn't explicitly opt into
    /// overwrite via `mcp_action: "replace"`.
    func test_noAction_mergesByDefault() {
        let importer = CeciliasNotesImporter.shared
        let nb = makeNotebook(updatedAt: iso.date(from: "2026-06-10T10:00:00Z")!)
        let file = makeFile(action: nil, baseUpdatedAt: nil)
        XCTAssertEqual(importer.pageWriteStrategy(for: file, existing: nb), .append)
    }

    /// **`create`** with an existing notebook — wholesale replace.
    func test_create_replaces() {
        let importer = CeciliasNotesImporter.shared
        let nb = makeNotebook(updatedAt: iso.date(from: "2026-06-10T10:00:00Z")!)
        let file = makeFile(action: "create", baseUpdatedAt: nil)
        XCTAssertEqual(importer.pageWriteStrategy(for: file, existing: nb), .replace)
    }

    /// **`replace`** — wholesale replace regardless of base value.
    func test_replace_replacesIgnoringBase() {
        let importer = CeciliasNotesImporter.shared
        let nb = makeNotebook(updatedAt: iso.date(from: "2026-06-10T10:00:00Z")!)
        let stale = makeFile(action: "replace", baseUpdatedAt: "1999-01-01T00:00:00Z")
        XCTAssertEqual(importer.pageWriteStrategy(for: stale, existing: nb), .replace)
    }

    /// **`append` with matching base** — no concurrent iPad edit
    /// since the MCP read; safe to wholesale replace.
    func test_append_matchingBase_replaces() {
        let importer = CeciliasNotesImporter.shared
        let now = iso.date(from: "2026-06-10T10:00:00Z")!
        let nb = makeNotebook(updatedAt: now)
        let file = makeFile(
            action: "append",
            baseUpdatedAt: iso.string(from: now)
        )
        XCTAssertEqual(importer.pageWriteStrategy(for: file, existing: nb), .replace)
    }

    /// **`append` with mismatched base** — iPad has edits the MCP
    /// hasn't seen; merge to preserve them.
    func test_append_mismatchedBase_merges() {
        let importer = CeciliasNotesImporter.shared
        let nb = makeNotebook(updatedAt: iso.date(from: "2026-06-10T10:05:00Z")!)
        let file = makeFile(
            action: "append",
            baseUpdatedAt: "2026-06-10T10:00:00Z"
        )
        XCTAssertEqual(importer.pageWriteStrategy(for: file, existing: nb), .append)
    }

    /// **`append` without any base** — conservative: merge instead
    /// of overwrite so a malformed write doesn't clobber iPad work.
    func test_append_missingBase_merges() {
        let importer = CeciliasNotesImporter.shared
        let nb = makeNotebook(updatedAt: iso.date(from: "2026-06-10T10:00:00Z")!)
        let file = makeFile(action: "append", baseUpdatedAt: nil)
        XCTAssertEqual(importer.pageWriteStrategy(for: file, existing: nb), .append)
    }

    /// **Unknown future verb** — falls through to the unspecified-
    /// action default, which is now id-merge (post-v1.2). A future
    /// MCP shipping a new destructive verb that the app doesn't
    /// recognise yet should not get wholesale replace by accident.
    func test_unknownAction_mergesByDefault() {
        let importer = CeciliasNotesImporter.shared
        let nb = makeNotebook(updatedAt: iso.date(from: "2026-06-10T10:00:00Z")!)
        let file = makeFile(action: "merge-three-way", baseUpdatedAt: "2026-06-10T09:55:00Z")
        XCTAssertEqual(importer.pageWriteStrategy(for: file, existing: nb), .append)
    }
}
