import XCTest
@testable import Ink

final class CoverToneAssignerTests: XCTestCase {

    func test_rotation_neverPicksInkBlack() {
        XCTAssertFalse(CoverToneAssigner.rotation.contains(.inkBlack))
        XCTAssertEqual(CoverToneAssigner.rotation.count, 7)
    }

    func test_seedIsLaunchStable() {
        // The same seed should always start at the same rotation index
        // — `String.hashValue` is salted per process and is the wrong
        // primitive for this; this test guards against a regression.
        let first  = CoverToneAssigner.tone(forSeed: "Maths", existingNotebooks: [])
        let second = CoverToneAssigner.tone(forSeed: "Maths", existingNotebooks: [])
        XCTAssertEqual(first, second)
    }

    func test_differentSeedsCanProduceDifferentStarts() {
        // Not a strict guarantee — two seeds can collide modulo 7 — but
        // a sanity check that we're not always returning the same tone.
        let seeds = ["Maths", "Physics", "History", "Biology", "Art", "Music", "PE", "Lit"]
        let tones = Set(seeds.map {
            CoverToneAssigner.tone(forSeed: $0, existingNotebooks: [])
        })
        XCTAssertGreaterThan(tones.count, 1, "Expected at least two distinct starts across 8 seeds")
    }

    func test_positionAdvancesThroughRotation() {
        // With zero existing notebooks we get rotation[start]. After
        // adding a non-deleted dummy, position becomes 1 → next tone.
        let nb1 = makeNotebook(deleted: false)
        let firstNoExisting = CoverToneAssigner.tone(
            forSeed: "Maths",
            existingNotebooks: []
        )
        let secondAfterOne = CoverToneAssigner.tone(
            forSeed: "Maths",
            existingNotebooks: [nb1]
        )
        XCTAssertNotEqual(firstNoExisting, secondAfterOne)
    }

    func test_softDeletedNotebooksAreIgnored() {
        // Deleted notebooks shouldn't bump the position — otherwise
        // deleting a notebook would silently reshuffle cover tones for
        // everything that comes after.
        let live    = makeNotebook(deleted: false)
        let deleted = makeNotebook(deleted: true)
        let withDeleted = CoverToneAssigner.tone(
            forSeed: "Maths",
            existingNotebooks: [live, deleted]
        )
        let liveOnly = CoverToneAssigner.tone(
            forSeed: "Maths",
            existingNotebooks: [live]
        )
        XCTAssertEqual(withDeleted, liveOnly)
    }

    // MARK: Helpers

    private func makeNotebook(deleted: Bool) -> Notebook {
        let nb = Notebook(
            title: "Test",
            subjectId: nil,
            coverColorHex: "#FFFFFF"
        )
        nb.isDeleted = deleted
        return nb
    }
}
