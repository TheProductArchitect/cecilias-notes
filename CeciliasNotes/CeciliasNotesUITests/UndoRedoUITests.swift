import XCTest

/// End-to-end undo/redo: draw real strokes with finger drags on the
/// canvas, then drive the toolbar undo/redo buttons and assert their
/// enabled state transitions. The buttons poll
/// `canvasView.undoManager` every 200ms, so enabled-state is a
/// faithful proxy for whether the undo stack actually works.
final class UndoRedoUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        return app
    }

    @MainActor
    private func completeOnboarding(name: String, in app: XCUIApplication) {
        let nameField = app.textFields["Your name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText(name)
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.tap()
        for label in ["OK", "Allow", "Continue", "Don't Allow"] {
            let button = app.alerts.buttons[label].firstMatch
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }
    }

    /// Draw a short diagonal stroke on the canvas with a finger drag.
    /// Finger drawing is enabled by default in the simulator (no
    /// Pencil → `.auto` mode resolves to finger-draws), and the
    /// scroll view requires two fingers while a drawing tool is
    /// active, so a single-finger drag becomes a PencilKit stroke.
    @MainActor
    private func drawStroke(in app: XCUIApplication, offset: CGVector) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.35 + offset.dx, dy: 0.40 + offset.dy))
        let end = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.55 + offset.dx, dy: 0.55 + offset.dy))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    func test_undoRedo_strokes() throws {
        let app = makeApp()
        app.launch()

        completeOnboarding(name: "Undo", in: app)

        let newSubjectCTA = app.buttons["+ new subject"].firstMatch
        XCTAssertTrue(newSubjectCTA.waitForExistence(timeout: 8))
        newSubjectCTA.tap()
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            app.typeText("\n")
        }
        let newNotebookCTA = app.buttons["+ new notebook"].firstMatch
        XCTAssertTrue(newNotebookCTA.waitForExistence(timeout: 8))
        newNotebookCTA.tap()

        let editorToolbar = app.toolbars["Toolbar"]
        XCTAssertTrue(editorToolbar.waitForExistence(timeout: 10),
                      "Editor should open after creating a notebook")

        // A brand-new notebook opens with the customise sheet
        // (name / cover / template) covering the canvas, with the
        // title field in edit mode. Commit the title with Return,
        // then dismiss the sheet via its floating Done button —
        // tapped by coordinate because the AX scroll-to-visible
        // action fails on the sheet's overlay buttons.
        Thread.sleep(forTimeInterval: 1.0)
        if app.keyboards.firstMatch.exists {
            app.typeText("\n")
            Thread.sleep(forTimeInterval: 0.5)
        }
        let doneButtons = app.buttons.matching(
            NSPredicate(format: "label ==[c] 'done'")
        )
        for i in 0..<doneButtons.count {
            let b = doneButtons.element(boundBy: i)
            if b.exists && b.isHittable {
                b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                break
            }
        }
        // Give the sheet dismissal animation a beat.
        Thread.sleep(forTimeInterval: 1.0)

        // New notebooks open in cursor mode — the canvas ignores
        // drags until a drawing tool is active. Select the pen.
        let penMatches = app.buttons.matching(
            NSPredicate(format: "label == 'Pen' OR label == 'Pen, selected'")
        )
        XCTAssertTrue(penMatches.firstMatch.waitForExistence(timeout: 8),
                      "Pen tool should be present in the tool palette")
        var tappedPen = false
        for i in 0..<penMatches.count {
            let b = penMatches.element(boundBy: i)
            // The palette exposes both the category button and its
            // collapsed flyout variant under the same label; the
            // flyout one has a zero frame. Tap the visible one.
            if b.exists && b.isHittable && b.frame.width > 1 {
                b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                tappedPen = true
                break
            }
        }
        XCTAssertTrue(tappedPen, "Should find a hittable Pen tool button")
        Thread.sleep(forTimeInterval: 0.5)

        let undoButton = app.buttons["arrow.uturn.backward"].firstMatch
        let redoButton = app.buttons["arrow.uturn.forward"].firstMatch
        XCTAssertTrue(undoButton.waitForExistence(timeout: 8),
                      "Undo button should be present in the editor toolbar")
        XCTAssertTrue(redoButton.exists,
                      "Redo button should be present in the editor toolbar")

        XCTAssertFalse(undoButton.isEnabled,
                       "Undo should start disabled on a fresh notebook")
        XCTAssertFalse(redoButton.isEnabled,
                       "Redo should start disabled on a fresh notebook")

        // Draw two strokes.
        drawStroke(in: app, offset: CGVector(dx: 0, dy: 0))
        drawStroke(in: app, offset: CGVector(dx: 0.05, dy: 0.08))

        XCTAssertTrue(
            waitFor(undoButton, enabled: true, timeout: 5),
            "Undo should be enabled after drawing strokes"
        )

        // Undo both strokes.
        undoButton.tap()
        XCTAssertTrue(
            waitFor(redoButton, enabled: true, timeout: 5),
            "Redo should be enabled after an undo"
        )
        undoButton.tap()
        XCTAssertTrue(
            waitFor(undoButton, enabled: false, timeout: 5),
            "Undo should be disabled once both strokes are undone"
        )
        XCTAssertTrue(redoButton.isEnabled,
                      "Redo should still be enabled with two undone strokes")

        // Redo both.
        redoButton.tap()
        redoButton.tap()
        XCTAssertTrue(
            waitFor(redoButton, enabled: false, timeout: 5),
            "Redo should be disabled after redoing everything"
        )
        XCTAssertTrue(undoButton.isEnabled,
                      "Undo should be enabled again after redo")
    }

    /// Poll an element's isEnabled until it matches or times out.
    @MainActor
    private func waitFor(
        _ element: XCUIElement,
        enabled: Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isEnabled == enabled { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return element.isEnabled == enabled
    }
}
