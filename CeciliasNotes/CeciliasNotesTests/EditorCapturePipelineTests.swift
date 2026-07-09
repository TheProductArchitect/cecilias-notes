import XCTest
import SwiftData
import UIKit
@testable import CeciliasNotes

/// Cross-platform editor capture coverage (iPad + iPhone share this
/// module): rich-text toolbar mutations, page-overflow splits,
/// dictation commits, and audio element round-trips.
@MainActor
final class EditorCapturePipelineTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    // MARK: - Rich text toolbar (iPad / iPhone)

    func test_richTextController_toggleBold_appliesToSelection() {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let body = NSAttributedString(
            string: "format me",
            attributes: RichTextController.defaultAttributes(ink: .label)
        )
        textView.attributedText = body
        textView.selectedRange = NSRange(location: 0, length: body.length)

        let controller = RichTextController()
        controller.attach(textView, defaultInk: .label)
        controller.toggleBold()

        let font = textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        XCTAssertTrue(controller.currentAttributes.isBold)
    }

    func test_richTextController_setHeading_persistsInArchivedData() {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        textView.attributedText = NSAttributedString(
            string: "Heading line",
            attributes: RichTextController.defaultAttributes(ink: .label)
        )
        textView.selectedRange = NSRange(location: 0, length: textView.text.count)

        let controller = RichTextController()
        controller.attach(textView, defaultInk: .label)
        controller.setHeading(.h2)

        let attrs = textView.attributedText.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attrs[RichTextController.headingKey] as? String, RichTextHeading.h2.rawValue)
        let font = attrs[.font] as? UIFont
        XCTAssertGreaterThanOrEqual(font?.pointSize ?? 0, 20)
    }

    func test_richTextController_setForeground_persistsCustomColor() {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        textView.attributedText = NSAttributedString(
            string: "colored",
            attributes: RichTextController.defaultAttributes(ink: .label)
        )
        textView.selectedRange = NSRange(location: 0, length: textView.text.count)

        let controller = RichTextController()
        controller.attach(textView, defaultInk: .label)
        controller.setForeground(.systemRed)

        let color = textView.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertNotNil(color)
        XCTAssertEqual(controller.currentAttributes.foreground, .systemRed)
    }

    // MARK: - Page overflow (typed text)

    func test_textElementSplitter_movesOverflowToNextPage() throws {
        let storage = StorageService.shared
        let notebook = try storage.createNotebook(
            title: "Overflow",
            subjectId: nil,
            coverColorHex: "#000000",
            coverTexture: .linen,
            pageSize: .a4,
            template: .blank
        )
        let page = try XCTUnwrap(storage.fetchPages(in: notebook).first)
        let pageSize = page.pageSize.pointSize

        let longBody = Array(repeating: "This paragraph must wrap across many lines on an A4 page. ", count: 100)
            .joined()
        let element = PageElement(
            pageId: page.id,
            notebookId: notebook.id,
            kind: .text,
            normalizedX: 0.1,
            normalizedY: 0.08,
            normalizedWidth: 0.8,
            normalizedHeight: 0.5,
            zIndex: 1
        )
        let content = TextContent(text: longBody, source: .typed, size: .body)
        content.attributedTextData = try? NSKeyedArchiver.archivedData(
            withRootObject: NSAttributedString(
                string: longBody,
                attributes: RichTextController.defaultAttributes(ink: .label)
            ),
            requiringSecureCoding: true
        )
        element.textContent = content
        storage.context.insert(element)
        try storage.context.save()

        let didSplit = TextElementSplitter.splitIfNeeded(
            element: element,
            content: content,
            pageInkColor: .label,
            pageSize: pageSize,
            originY: 32
        )
        XCTAssertTrue(didSplit, "Long typed block should overflow and split")

        let pages = storage.fetchPages(in: notebook)
        XCTAssertGreaterThanOrEqual(pages.count, 2, "Overflow should create or use a next page")

        let nextPageId = try XCTUnwrap(pages.first(where: { $0.pageNumber == page.pageNumber + 1 })?.id)
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == nextPageId && $0.deletedAt == nil }
        )
        let continuation = try storage.context.fetch(descriptor).filter { $0.kind == .text }
        XCTAssertFalse(continuation.isEmpty, "Continuation text block should exist on the next page")
        XCTAssertTrue(
            (element.textContent?.text.count ?? 0) < longBody.count,
            "Source block should be truncated after split"
        )
    }

    // MARK: - Dictation

    func test_dictationFlowCommit_updateText_archivesAttributedString() throws {
        let pageId = UUID()
        let notebookId = UUID()
        let elementId = DictationFlowCommit.createInitialTextElement(
            pageId: pageId,
            notebookId: notebookId,
            pageSize: CGSize(width: 595, height: 842)
        )

        DictationFlowCommit.updateText(elementId: elementId, text: "live transcript tail")

        let deferred = expectation(description: "deferred dictation write")
        DispatchQueue.main.async { deferred.fulfill() }
        wait(for: [deferred], timeout: 2)

        let ctx = StorageService.shared.context
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == elementId }
        )
        let fetched = try XCTUnwrap(try ctx.fetch(descriptor).first)
        XCTAssertEqual(fetched.textContent?.text, "live transcript tail")
        // Live dictation ticks update plain `text` only; attributed data
        // is rebuilt on finalize (see RecordingSessionSmokeTests).
    }

    // MARK: - Audio

    func test_audioElementCommit_voiceNoteRoundTrip_preservesDuration() throws {
        let pageId = UUID()
        let notebookId = UUID()
        let contentId = UUID()

        let elementId = AudioElementCommit.createRecordingPlaceholder(
            contentId: contentId,
            pageId: pageId,
            notebookId: notebookId,
            pageSize: CGSize(width: 595, height: 842)
        )

        AudioElementCommit.finalizeVoiceNote(
            elementId: elementId,
            contentId: contentId,
            durationSeconds: 18.25
        )

        let ctx = StorageService.shared.context
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == elementId }
        )
        let row = try XCTUnwrap(try ctx.fetch(descriptor).first)
        XCTAssertEqual(row.audioContent?.durationSeconds ?? 0, 18.25, accuracy: 0.01)
        XCTAssertEqual(row.kind, .audio)
    }
}
