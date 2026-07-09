import AppKit
import XCTest
import SwiftData
@testable import CeciliasNotesMac

/// Mac doc-mode capture coverage: format toolbar mutations, overflow
/// splits, dictation commits, and audio helpers.
@MainActor
final class MacEditorCapturePipelineTests: XCTestCase {

    var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer.ceciliasNotesTestContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    // MARK: - Rich text toolbar

    func test_macRichTextController_toggleUnderline_appliesToSelection() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let body = NSAttributedString(
            string: "mac format",
            attributes: MacRichTextCodec.defaultTypingAttributes()
        )
        textView.textStorage?.setAttributedString(body)
        textView.setSelectedRange(NSRange(location: 0, length: body.length))

        let controller = MacRichTextController()
        controller.attach(textView)
        controller.toggleUnderline()
        // Toolbar mutations refresh `currentAttributes` on the next tick.
        controller.refresh()

        XCTAssertTrue(controller.currentAttributes.isUnderline)
        let style = textView.attributedString().attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(style ?? 0, NSUnderlineStyle.single.rawValue)
    }

    func test_macRichTextController_notifyDidChange_invokesDelegate() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "persist",
            attributes: MacRichTextCodec.defaultTypingAttributes()
        ))
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.count))

        let controller = MacRichTextController()
        let delegate = RecordingDelegate()
        textView.delegate = delegate
        controller.attach(textView)
        controller.toggleUnderline()

        XCTAssertTrue(delegate.didChange, "Toolbar mutation must reach NSTextViewDelegate")
    }

    // MARK: - Overflow split

    func test_macTextElementSplitter_movesOverflowToNextPage() throws {
        let storage = StorageService.shared
        let notebook = try storage.createNotebook(
            title: "Mac Overflow",
            subjectId: nil,
            coverColorHex: "#000000",
            coverTexture: .linen,
            pageSize: .a4,
            template: .blank
        )
        let page = try XCTUnwrap(storage.fetchPages(in: notebook).first)
        let pageSize = page.pageSize.pointSize

        let longBody = Array(repeating: "Dictated words that must wrap past the Mac page boundary. ", count: 100)
            .joined()
        let element = PageElement(
            pageId: page.id,
            notebookId: notebook.id,
            kind: .text,
            normalizedX: MacDocPageLayout.normalizedHorizontalMargin(pageWidth: pageSize.width),
            normalizedY: MacDocPageLayout.normalizedTopMargin(pageHeight: pageSize.height),
            normalizedWidth: MacDocPageLayout.normalizedContentWidth(pageWidth: pageSize.width),
            normalizedHeight: 0.5,
            zIndex: 1
        )
        let content = TextContent(text: longBody, source: .dictated, size: .body)
        content.attributedTextData = MacRichTextCodec.encode(
            NSAttributedString(string: longBody, attributes: MacRichTextCodec.defaultTypingAttributes())
        )
        element.textContent = content
        storage.context.insert(element)
        try storage.context.save()

        let originY = MacPageElementReflow.stackOriginPoints(
            elementId: element.id,
            pageId: page.id
        )
        let split = MacTextElementSplitter.splitIfNeeded(
            element: element,
            content: content,
            pageSize: pageSize,
            originY: originY
        )
        XCTAssertNotNil(split, "Mac overflow split should produce a continuation block")

        let pages = storage.fetchPages(in: notebook)
        XCTAssertGreaterThanOrEqual(pages.count, 2)
    }

    func test_macPageElementReflow_stackOrigin_tracksPackedLayout() throws {
        let storage = StorageService.shared
        let notebook = try storage.createNotebook(
            title: "Reflow",
            subjectId: nil,
            coverColorHex: "#000000",
            coverTexture: .linen,
            pageSize: .a4,
            template: .blank
        )
        let page = try XCTUnwrap(storage.fetchPages(in: notebook).first)

        let element = PageElement(
            pageId: page.id,
            notebookId: notebook.id,
            kind: .text,
            normalizedX: 0.1,
            normalizedY: 0.5,
            normalizedWidth: 0.8,
            normalizedHeight: 0.1,
            zIndex: 1
        )
        element.textContent = TextContent(text: "block one", source: .typed, size: .body)
        storage.context.insert(element)
        try storage.context.save()

        MacPageElementReflow.packVerticalLayout(pageId: page.id)
        let origin = MacPageElementReflow.stackOriginPoints(
            elementId: element.id,
            pageId: page.id
        )
        XCTAssertEqual(origin, MacDocPageLayout.topMargin, accuracy: 2)
    }

    // MARK: - Dictation + audio

    func test_macDictationFlowCommit_applyTextUpdate_writesTail() throws {
        let pageId = UUID()
        let notebookId = UUID()
        let elementId = MacDictationFlowCommit.createInitialTextElement(
            pageId: pageId,
            notebookId: notebookId,
            pageSize: CGSize(width: 595, height: 842)
        )

        MacDictationFlowCommit.applyTextUpdate(elementId: elementId, text: "mac live tail")

        let ctx = StorageService.shared.context
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == elementId }
        )
        let fetched = try XCTUnwrap(try ctx.fetch(descriptor).first)
        XCTAssertEqual(fetched.textContent?.text, "mac live tail")
        XCTAssertNotNil(fetched.textContent?.attributedTextData)
    }

    func test_macRecordingSession_initialMode_isIdle() {
        XCTAssertFalse(MacRecordingSession.shared.mode.isTranscribing)
        XCTAssertFalse(MacRecordingSession.shared.mode.isActive)
    }
}

@MainActor
private final class RecordingDelegate: NSObject, NSTextViewDelegate {
    var didChange = false
    func textDidChange(_ notification: Notification) {
        didChange = true
    }
}
