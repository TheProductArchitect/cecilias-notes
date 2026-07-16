import XCTest
@testable import CeciliasNotes

/// Inline-markdown rendering inside `.inkbook` block content —
/// `**bold**`, `*italic*`, `_italic_`, `` `code` ``. Agents writing
/// through the MCP emit these reflexively; before this pass they
/// landed on the page as literal asterisks/backticks ("MCP can't
/// push text formatting"). These tests pin both directions: markers
/// that MUST style (and disappear), and lookalikes that MUST stay
/// literal.
final class InkbookInlineMarkdownTests: XCTestCase {

    private func render(_ block: CeciliasNotesFile.Block) -> NSAttributedString {
        CeciliasNotesParser.renderBlocks([block])
    }

    private func fonts(in rendered: NSAttributedString) -> [(text: String, font: UIFont)] {
        var runs: [(String, UIFont)] = []
        rendered.enumerateAttribute(
            .font, in: NSRange(location: 0, length: rendered.length)
        ) { value, range, _ in
            guard let font = value as? UIFont else { return }
            runs.append(((rendered.string as NSString).substring(with: range), font))
        }
        return runs
    }

    func test_bold_stripsMarkersAndAppliesBoldTrait() {
        let rendered = render(.paragraph(content: "plain **loud** tail"))
        XCTAssertEqual(rendered.string, "plain loud tail",
                       "The ** markers must not reach the page")
        let boldRun = fonts(in: rendered).first { $0.text == "loud" }
        XCTAssertNotNil(boldRun)
        XCTAssertTrue(boldRun!.font.fontDescriptor.symbolicTraits.contains(.traitBold),
                      "\"loud\" must render bold")
        let plainRun = fonts(in: rendered).first { $0.text.contains("plain ") }
        XCTAssertFalse(plainRun!.font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func test_italic_star_andUnderscore() {
        let starred = render(.paragraph(content: "a *lean* b"))
        XCTAssertEqual(starred.string, "a lean b")
        XCTAssertTrue(fonts(in: starred).first { $0.text == "lean" }!
            .font.fontDescriptor.symbolicTraits.contains(.traitItalic))

        let underscored = render(.paragraph(content: "a _lean_ b"))
        XCTAssertEqual(underscored.string, "a lean b")
        XCTAssertTrue(fonts(in: underscored).first { $0.text == "lean" }!
            .font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    func test_inlineCode_monospacedWithBackground() {
        let rendered = render(.paragraph(content: "run `swift build` now"))
        XCTAssertEqual(rendered.string, "run swift build now")
        let codeRun = fonts(in: rendered).first { $0.text == "swift build" }
        XCTAssertNotNil(codeRun)
        XCTAssertTrue(codeRun!.font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace),
                      "Inline code must render monospaced")
        var hasBackground = false
        rendered.enumerateAttribute(
            .backgroundColor, in: NSRange(location: 0, length: rendered.length)
        ) { value, range, _ in
            if value != nil,
               (rendered.string as NSString).substring(with: range) == "swift build" {
                hasBackground = true
            }
        }
        XCTAssertTrue(hasBackground, "Inline code must carry its chip background")
    }

    func test_lookalikes_stayLiteral() {
        // Multiplication, snake_case, and unbalanced markers must
        // pass through untouched — over-eager styling is worse than
        // none.
        let cases = [
            "2 * 3 * 4",
            "snake_case_identifier stays",
            "unbalanced **still here",
            "lone ` backtick",
            "a * spaced * star",
        ]
        for text in cases {
            let rendered = render(.paragraph(content: text))
            XCTAssertEqual(rendered.string, text, "\"\(text)\" must render verbatim")
        }
    }

    func test_codeBlock_neverParsesInlineMarkers() {
        let literal = "let x = 2 ** 3 // `pow`"
        let rendered = render(.code(content: literal, language: "swift"))
        XCTAssertEqual(rendered.string, literal,
                       "Code blocks are verbatim — no inline pass")
    }

    func test_headingAndCallout_styleInline() {
        let heading = render(.heading(content: "Ship `v2.4` now", level: 1))
        XCTAssertEqual(heading.string, "Ship v2.4 now")

        let callout = render(.callout(content: "Demo is **Friday**", kind: .tip))
        XCTAssertEqual(callout.string, "💡 Demo is Friday")
        XCTAssertTrue(fonts(in: callout).first { $0.text == "Friday" }!
            .font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func test_listItems_styleInlinePerItem() {
        let rendered = render(.list(style: .bullet,
                                    items: ["**urgent** fix", "calm item"]))
        XCTAssertEqual(rendered.string, "•  urgent fix\n•  calm item")
        XCTAssertTrue(fonts(in: rendered).first { $0.text == "urgent" }!
            .font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }
}
