import XCTest
@testable import Ink

/// Verifies the playful-name picker's collision suffix logic. Random
/// picking is non-deterministic by design, so we test *properties* of
/// the result rather than asserting on specific names: with the right
/// `existingTitles` shape, the suffix `" 2"` / `" 3"` must appear.
final class NotebookNameGeneratorTests: XCTestCase {

    func test_returnsNonEmptyName_withEmptyAvoidSet() {
        let result = NotebookNameGenerator.randomName(avoiding: [])
        XCTAssertFalse(result.isEmpty)
    }

    func test_returnsNameFromCuratedList_withEmptyAvoidSet() {
        // Run 50 times so a flaky picker would be exposed.
        for _ in 0..<50 {
            let result = NotebookNameGenerator.randomName(avoiding: [])
            XCTAssertTrue(
                NotebookNameGenerator.names.contains(result),
                "Expected \(result) to be one of the curated names"
            )
        }
    }

    func test_collisionAddsTwoSuffix_whenAllBaseNamesAreTaken() {
        // Force collision: every base name in the curated list is
        // already taken. The generator must pick *some* base and append
        // " 2".
        let existing = Set(NotebookNameGenerator.names)
        let result = NotebookNameGenerator.randomName(avoiding: existing)
        XCTAssertTrue(
            result.hasSuffix(" 2"),
            "Expected '\(result)' to end with ' 2' when every base name is taken"
        )
        // The base must still be one of the curated names.
        let base = String(result.dropLast(2)) // strip " 2"
        XCTAssertTrue(
            NotebookNameGenerator.names.contains(base),
            "Expected base '\(base)' to be from the curated list"
        )
    }

    func test_collisionAddsThreeSuffix_whenBaseAndTwoSuffixTaken() {
        // Every base + every "X 2" already taken → must produce " 3".
        let baseTitles    = Set(NotebookNameGenerator.names)
        let twoSuffixed   = Set(NotebookNameGenerator.names.map { "\($0) 2" })
        let existing      = baseTitles.union(twoSuffixed)
        let result = NotebookNameGenerator.randomName(avoiding: existing)
        XCTAssertTrue(
            result.hasSuffix(" 3"),
            "Expected '\(result)' to end with ' 3' when bases and ' 2' variants are taken"
        )
    }
}
