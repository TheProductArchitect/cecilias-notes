import XCTest
import PencilKit
@testable import Ink

/// Verifies the InkTool model: `.withColour` preserves width/opacity,
/// `.hasWidth` reports correctly per case, and `.makePKTool()` returns
/// the right `PKTool` subclass for each case.
final class InkToolTests: XCTestCase {

    // MARK: withColour preserves other dimensions

    func test_pen_withColour_preservesWidthAndOpacity() {
        let original: InkTool = .pen(colour: .red, width: 4, opacity: 0.7)
        let updated = original.withColour(.blue)
        XCTAssertEqual(updated.currentColour.hexString, UIColor.blue.hexString)
        XCTAssertEqual(updated.currentWidth, 4)
        XCTAssertEqual(updated.currentOpacity, 0.7, accuracy: 0.001)
    }

    func test_marker_withColour_preservesWidth() {
        let original: InkTool = .marker(colour: .red, width: 12)
        let updated = original.withColour(.green)
        XCTAssertEqual(updated.currentColour.hexString, UIColor.green.hexString)
        XCTAssertEqual(updated.currentWidth, 12)
    }

    func test_eraser_withColour_isNoOp() {
        let original: InkTool = .eraser(mode: .pixel)
        let updated = original.withColour(.red)
        // Eraser doesn't carry a colour — withColour must return the same case.
        XCTAssertEqual(original, updated)
    }

    // MARK: hasWidth

    func test_pen_hasWidth_isTrue() {
        XCTAssertTrue(InkTool.pen(colour: .black, width: 2, opacity: 1).hasWidth)
    }

    func test_pixelEraser_hasWidth_isTrue() {
        XCTAssertTrue(InkTool.eraser(mode: .pixel).hasWidth)
    }

    func test_wholeStrokeEraser_hasWidth_isFalse() {
        XCTAssertFalse(InkTool.eraser(mode: .wholeStroke).hasWidth)
    }

    func test_lasso_hasWidth_isFalse() {
        XCTAssertFalse(InkTool.lasso.hasWidth)
    }

    // MARK: makePKTool — verify subclass + colour round-trips

    func test_pen_makesPKInkingTool_pen() {
        let tool: InkTool = .pen(colour: .red, width: 5, opacity: 1)
        let pk = tool.makePKTool()
        guard let inking = pk as? PKInkingTool else {
            XCTFail("Expected PKInkingTool, got \(type(of: pk))"); return
        }
        XCTAssertEqual(inking.inkType, .pen)
        XCTAssertEqual(inking.width, 5)
    }

    func test_marker_makesPKInkingTool_marker() {
        let tool: InkTool = .marker(colour: .blue, width: 14)
        let pk = tool.makePKTool()
        guard let inking = pk as? PKInkingTool else {
            XCTFail("Expected PKInkingTool, got \(type(of: pk))"); return
        }
        XCTAssertEqual(inking.inkType, .marker)
    }

    func test_pixelEraser_makesPKEraserTool_bitmap() {
        let pk = InkTool.eraser(mode: .pixel).makePKTool()
        guard let eraser = pk as? PKEraserTool else {
            XCTFail("Expected PKEraserTool, got \(type(of: pk))"); return
        }
        // iOS 16.4 renamed `.bitmap` → `.fixedWidthBitmap`. PencilKit
        // accepts the old enum case but reports the new one back. Assert
        // "any non-vector eraser" rather than a specific case so the
        // test survives Apple's continued renames.
        XCTAssertNotEqual(
            eraser.eraserType,
            .vector,
            "Expected a bitmap-class eraser (got \(eraser.eraserType))"
        )
    }

    func test_wholeStrokeEraser_makesPKEraserTool_vector() {
        let pk = InkTool.eraser(mode: .wholeStroke).makePKTool()
        guard let eraser = pk as? PKEraserTool else {
            XCTFail("Expected PKEraserTool, got \(type(of: pk))"); return
        }
        XCTAssertEqual(eraser.eraserType, .vector)
    }

    func test_lasso_makesPKLassoTool() {
        let pk = InkTool.lasso.makePKTool()
        XCTAssertTrue(pk is PKLassoTool, "Expected PKLassoTool, got \(type(of: pk))")
    }
}
