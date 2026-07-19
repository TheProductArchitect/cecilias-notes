import XCTest
@testable import CeciliasNotes

/// Locks in the strengthened `TranscriptStructurer.isFaithful` check.
/// The original letters-only length comparison passed nearly any
/// rewrite (the model ADDS headings, so length rarely fell below the
/// 92% floor) — a device session showed a short dictation coming back
/// visibly reworded. The check now requires every original word,
/// verbatim and in order, with only bounded additions.
@MainActor
final class TranscriptStructurerTests: XCTestCase {

    private let transcript =
        "Hello my name is Vinod. I'm trying to see if this is going to work. " +
        "Now I'm going to take a pause for two seconds. It should start in a new line."

    func testVerbatimReflowPasses() {
        let structured = transcript.replacingOccurrences(of: ". ", with: ".\n\n")
        XCTAssertTrue(TranscriptStructurer.isFaithful(
            original: transcript, structured: structured
        ))
    }

    func testAddedHeadingAndSpeakerLabelPass() {
        let structured = "INTRO\n\nVinod: " + transcript
        XCTAssertTrue(TranscriptStructurer.isFaithful(
            original: transcript, structured: structured
        ))
    }

    func testRewordedOutputFails() {
        let structured = transcript.replacingOccurrences(
            of: "trying to see if this is going to work",
            with: "testing whether this works"
        )
        XCTAssertFalse(TranscriptStructurer.isFaithful(
            original: transcript, structured: structured
        ))
    }

    func testDroppedSentenceFails() {
        let structured = transcript.replacingOccurrences(
            of: " It should start in a new line.", with: ""
        )
        XCTAssertFalse(TranscriptStructurer.isFaithful(
            original: transcript, structured: structured
        ))
    }

    func testReorderedWordsFail() {
        XCTAssertFalse(TranscriptStructurer.isFaithful(
            original: "alpha beta gamma", structured: "beta alpha gamma"
        ))
    }

    func testExcessiveInventedTextFails() {
        let invented = Array(repeating: "totally new invented words", count: 10)
            .joined(separator: " ")
        XCTAssertFalse(TranscriptStructurer.isFaithful(
            original: transcript, structured: transcript + " " + invented
        ))
    }

    func testEmptyOriginalFails() {
        XCTAssertFalse(TranscriptStructurer.isFaithful(
            original: "  ", structured: "anything"
        ))
    }
}
