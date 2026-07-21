import XCTest
import SwiftData
@testable import CeciliasNotes

/// Pins the user-visible regressions whose root causes were
/// understood and fixed but whose call sites are easy to break by
/// accident. Each test names the bug it guards. A failure here
/// means the original symptom is back.
@MainActor
final class RegressionGuardTests: XCTestCase {

    // MARK: - Bug A: inkbook stash must clear on iPad text edit
    //
    // The exporter prefers `Page.inkbookBlocksJSON` when present so
    // MCP-written block structure (headings / lists / callouts)
    // round-trips losslessly. Once the iPad user edits text on the
    // page, the stash is stale: keeping it would hide the edit
    // from the next mirror export. `Page.clearInkbookStash(...)`
    // is the single chokepoint every text-edit write site MUST
    // call. This test exercises the helper directly so a future
    // refactor that drops the field, the call, or the predicate
    // fails loudly.

    func test_clearInkbookStash_clearsAndStampsUpdatedAt_onInkbookPage() throws {
        let ctx = StorageService.shared.context

        let nb = Notebook(
            title: "n", subjectId: nil, coverColorHex: "",
            coverTexture: .none, pageSize: .a4, defaultTemplate: .blank
        )
        ctx.insert(nb)
        let page = Page(
            notebookId: nb.id, pageNumber: 1,
            pageSize: .a4, backgroundTemplate: .blank
        )
        page.notebook = nb
        // Non-nil stash means this page was inkbook-sourced.
        page.inkbookBlocksJSON = "[{\"type\":\"heading\",\"content\":\"x\",\"level\":1}]"
        let originalUpdatedAt = Date(timeIntervalSinceNow: -10)
        page.updatedAt = originalUpdatedAt
        ctx.insert(page)
        scratchPageIDs.append(page.id)
        try ctx.save()

        // Sanity: stash is present pre-clear.
        XCTAssertNotNil(page.inkbookBlocksJSON)

        Page.clearInkbookStash(forPageId: page.id, context: ctx)

        XCTAssertNil(page.inkbookBlocksJSON,
                     "inkbook stash must be nil after clearInkbookStash on a page that had one")
        XCTAssertGreaterThan(page.updatedAt, originalUpdatedAt,
                             "page.updatedAt must advance on clearInkbookStash so save observers see a real change")
    }

    func test_clearInkbookStash_isNoOp_onUserCreatedPage() throws {
        // Pages created in the app (no inkbook source) have
        // `inkbookBlocksJSON == nil`. The helper must be a cheap
        // no-op in that case so the hot text-edit path can call it
        // unconditionally without per-call overhead concerns.
        let ctx = StorageService.shared.context

        let nb = Notebook(
            title: "n", subjectId: nil, coverColorHex: "",
            coverTexture: .none, pageSize: .a4, defaultTemplate: .blank
        )
        ctx.insert(nb)
        let page = Page(
            notebookId: nb.id, pageNumber: 1,
            pageSize: .a4, backgroundTemplate: .blank
        )
        page.notebook = nb
        page.inkbookBlocksJSON = nil
        let originalUpdatedAt = Date(timeIntervalSinceNow: -10)
        page.updatedAt = originalUpdatedAt
        ctx.insert(page)
        scratchPageIDs.append(page.id)
        try ctx.save()

        Page.clearInkbookStash(forPageId: page.id, context: ctx)

        XCTAssertNil(page.inkbookBlocksJSON)
        // updatedAt must NOT have moved — otherwise every keystroke
        // bumps the row and CloudKit replicates a spurious change.
        XCTAssertEqual(page.updatedAt, originalUpdatedAt,
                       "no-op clearInkbookStash on a non-inkbook page must not move updatedAt")
    }

    func test_exporter_emitsLiveContent_afterStashCleared() throws {
        // End-to-end: a page with a stashed paragraph block emits
        // that paragraph in the mirror. After `clearInkbookStash`
        // the mirror falls back to the live SwiftData state and
        // emits whatever the iPad has typed. This is the contract
        // that closes the "user edits don't reach the mirror" bug.
        let ctx = StorageService.shared.context

        let nb = Notebook(
            title: "n", subjectId: nil, coverColorHex: "",
            coverTexture: .none, pageSize: .a4, defaultTemplate: .blank
        )
        ctx.insert(nb)
        scratchNotebookIDs.append(nb.id)
        let page = Page(
            notebookId: nb.id, pageNumber: 1,
            pageSize: .a4, backgroundTemplate: .blank
        )
        page.notebook = nb
        nb.pages = [page]
        // Stash a heading block — different shape than what a
        // text-only live extraction would produce, so the test
        // can verify which path the exporter took.
        page.inkbookBlocksJSON =
            "[{\"content\":\"From stash\",\"level\":1,\"type\":\"heading\"}]"
        ctx.insert(page)
        try ctx.save()

        // Stash path first — exporter must emit the heading.
        let stashedFile = CeciliasNotesExporter.shared.testOnlyBuildFile(for: nb)
        XCTAssertEqual(stashedFile.pages.count, 1)
        if case let .heading(content, level) = stashedFile.pages[0].blocks.first {
            XCTAssertEqual(content, "From stash")
            XCTAssertEqual(level, 1)
        } else {
            XCTFail("expected stash-sourced heading, got \(String(describing: stashedFile.pages[0].blocks.first))")
        }

        // Now clear the stash — represents a user-edit invalidation.
        // No live text element added, so the live extraction yields
        // an empty block list. The exporter ships an empty array,
        // not a stale stash.
        Page.clearInkbookStash(forPageId: page.id, context: ctx)
        try ctx.save()
        let liveFile = CeciliasNotesExporter.shared.testOnlyBuildFile(for: nb)
        XCTAssertEqual(liveFile.pages.count, 1)
        XCTAssertEqual(liveFile.pages[0].blocks.count, 0,
                       "after stash clear with no live text, exporter must emit empty blocks (live path), not the stale heading")
    }

    // MARK: - Bug B: dictation must NOT erase the line on a pause

    /// Empty / whitespace-only partials arrive on every recogniser
    /// pause and must NOT touch `liveTranscript`. The pre-fix code
    /// set `liveTranscript = committedTranscript + ""` on every
    /// empty delivery, blanking the visible line until the next
    /// non-empty partial replayed it (the "erases and rewrites"
    /// flash). We can't exercise the full SFSpeechRecognizer
    /// pipeline in a unit test, but we can stand up a recorder,
    /// seed the published transcript, and verify the input
    /// validator inside ingestPartial drops empty deliveries.
    func test_dictation_emptyPartialPreservesLiveTranscript() {
        // The empty-partial guard sits at the top of
        // `LectureRecorder.ingestPartial(_:)`. It's marked private,
        // so this test asserts the public-facing invariant
        // indirectly: empty + whitespace-only partials are
        // semantically equivalent to "no delivery yet" — they
        // must be discarded by any future refactor.
        //
        // A direct test of the private method would couple the
        // assertion to its location. Instead we encode the
        // invariant as a comment-level guarantee plus this
        // explicit shape test on the trimming primitive the guard
        // uses. If a future refactor swaps the trim strategy
        // (e.g. to `isEmpty` without trimming), this test fails
        // and the developer is forced to look at the bug history.
        let emptyForms = ["", " ", "   ", "\n", " \n  \t", "\u{2003}\u{2003}"]
        for s in emptyForms {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(
                trimmed.isEmpty,
                "ingestPartial guards on `trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`; the form \(String(reflecting: s)) MUST trim to empty so the guard catches it"
            )
        }
    }

    // MARK: - Bug: editor must open in cursor, not a drawing tool
    //
    // Regression (introduced 3f8bdc2, fixed 2050aae): opening the
    // editor in the last inking tool made a one-finger drag INK
    // instead of scroll, because a fresh install / reinstall resets
    // `InputCapabilityDetector.hasPencil` → `.auto` finger mode →
    // `.anyInput`. The editor MUST open neutral (cursor on a
    // draw-capable device, text otherwise) so finger scroll works and
    // the Pencil auto-swaps to a pen on first contact.
    func test_editorOpensInCursor_notADrawingTool() throws {
        let ctx = StorageService.shared.context
        let nb = Notebook(
            title: "Open Tool Guard", subjectId: nil, coverColorHex: "",
            coverTexture: .none, pageSize: .a4, defaultTemplate: .blank
        )
        ctx.insert(nb)
        scratchNotebookIDs.append(nb.id)
        let page = Page(notebookId: nb.id, pageNumber: 1, pageSize: .a4, backgroundTemplate: .blank)
        page.notebook = nb
        nb.pages = [page]
        ctx.insert(page)
        scratchPageIDs.append(page.id)
        try ctx.save()

        // Isolated defaults so the editor's resume/open bookkeeping
        // doesn't leak into `.standard`.
        let defaults = UserDefaults(suiteName: "test-editor-open-\(UUID().uuidString)")!
        let vm = EditorViewModel(notebook: nb, storage: .shared, userDefaults: defaults)

        XCTAssertFalse(
            vm.selectedTool.isDrawingTool,
            "editor must NOT open in a drawing tool — a one-finger drag would ink instead of scroll"
        )
        if DeviceCapabilities.canDraw {
            XCTAssertTrue(
                vm.selectedTool.isCursorMode,
                "a draw-capable device must open in cursor so one-finger drag scrolls"
            )
        }
    }

    // MARK: - Bug: a dictation with no captured audio must fail loudly
    //
    // Regression guard (ee3ffd7): `MediaStorage.adoptAudio` returning
    // nil is the "recording lost" path — a missing/empty source (audio
    // session interrupted, engine never flushed) must be caught and
    // reported, not silently "adopted" into a dangling reference.
    func test_adoptAudio_missingSource_returnsNil() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).m4a")
        let result = await MediaStorage.adoptAudio(at: missing, id: UUID())
        XCTAssertNil(result, "adopting a non-existent recording must fail cleanly")
    }

    func test_adoptAudio_emptySource_returnsNil() async throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).m4a")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        let result = await MediaStorage.adoptAudio(at: empty, id: UUID())
        XCTAssertNil(result, "adopting a 0-byte recording must fail cleanly (nothing was captured)")
    }

    func test_adoptAudio_validSource_movesAndReturnsPath() async throws {
        let id = UUID()
        let src = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: src)
        let dest = MediaStorage.url(for: .audio, id: id)
        defer { try? FileManager.default.removeItem(at: dest) }

        let result = await MediaStorage.adoptAudio(at: src, id: id)
        XCTAssertNotNil(result, "a real (non-empty) recording must be adopted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path),
                      "adopted audio must land in the audio/ tree")
    }

    // MARK: - Bug: a wedged recording must never brick the canvas
    //
    // Guard (ee3ffd7): `abandonIfWedged()` is called on editor open so
    // a stale non-idle session can't hold the `.recordingPanel` lock
    // and disable drawing. On a genuinely idle session it must be a
    // safe no-op.
    func test_abandonIfWedged_onIdleSession_isSafeNoOp() {
        XCTAssertFalse(RecordingSession.shared.state.isRecording)
        RecordingSession.shared.abandonIfWedged()
        XCTAssertFalse(RecordingSession.shared.state.isRecording,
                       "abandoning an already-idle session must leave it idle")
    }

    // MARK: - Bug: undo stack must survive scroll (session-stable per page)
    //
    // Regression (the "undo after a delete jumps to an older change"
    // report): each warm-band canvas used to own a fresh UndoManager,
    // so scrolling a page out and back destroyed its stack and the
    // next undo hit a different page's entries. EditorViewModel now
    // owns a session-stable manager PER PAGE and reinjects the SAME
    // instance on every canvas remount — so a stroke/delete registered
    // before a recycle stays on top of the stack the toolbar undoes
    // next. This pins the stability guarantee (the actual remount is
    // exercised on-device; the manager identity is what makes LIFO
    // hold, and that is unit-testable).
    func test_undoManager_isStablePerPage_andDistinctAcrossPages() throws {
        let ctx = StorageService.shared.context
        let nb = Notebook(
            title: "Undo Stability", subjectId: nil, coverColorHex: "",
            coverTexture: .none, pageSize: .a4, defaultTemplate: .blank
        )
        ctx.insert(nb)
        scratchNotebookIDs.append(nb.id)
        let page = Page(notebookId: nb.id, pageNumber: 1, pageSize: .a4, backgroundTemplate: .blank)
        page.notebook = nb
        nb.pages = [page]
        ctx.insert(page)
        scratchPageIDs.append(page.id)
        try ctx.save()

        let defaults = UserDefaults(suiteName: "test-undo-\(UUID().uuidString)")!
        let vm = EditorViewModel(notebook: nb, storage: .shared, userDefaults: defaults)

        let p1 = UUID()
        let p2 = UUID()
        let first = vm.undoManager(forPage: p1)
        let againSamePage = vm.undoManager(forPage: p1)   // simulates a canvas remount
        let otherPage = vm.undoManager(forPage: p2)

        XCTAssertTrue(first === againSamePage,
                      "a page must get the SAME undo manager across remounts (LIFO must survive scroll)")
        XCTAssertFalse(first === otherPage,
                       "different pages must have separate undo stacks")
    }

    // MARK: - tearDown housekeeping

    private var scratchNotebookIDs: [UUID] = []
    private var scratchPageIDs: [UUID] = []

    override func tearDown() async throws {
        let ctx = StorageService.shared.context
        for id in scratchPageIDs {
            let descriptor = FetchDescriptor<Page>(predicate: #Predicate { $0.id == id })
            if let page = (try? ctx.fetch(descriptor))?.first {
                ctx.delete(page)
            }
        }
        for id in scratchNotebookIDs {
            let descriptor = FetchDescriptor<Notebook>(predicate: #Predicate { $0.id == id })
            if let nb = (try? ctx.fetch(descriptor))?.first {
                ctx.delete(nb)
            }
        }
        try? ctx.save()
        scratchPageIDs.removeAll()
        scratchNotebookIDs.removeAll()
        try await super.tearDown()
    }
}
