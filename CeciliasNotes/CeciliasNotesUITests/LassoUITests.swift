import XCTest

/// End-to-end lasso coverage on a non-stroke element: create a text
/// element, lasso-select it, delete via the trash badge, then undo
/// (element returns) and redo (element disappears again).
///
/// The lasso hit-test for non-stroke elements passes when either the
/// element's centre is inside the drawn path or ≥25% of its area
/// overlaps the path's bounding box — so a straight diagonal drag
/// across the element is a valid selection gesture here.
private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

final class LassoUITests: XCTestCase {

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

    /// Create subject + notebook, land in the editor, dismiss the
    /// auto-opened customise sheet.
    @MainActor
    private func openFreshNotebook(in app: XCUIApplication) {
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
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Tap the first hittable palette button with the given tool
    /// label ("Pen", "Lasso", "Text", …). The palette exposes both
    /// the category button and a zero-frame flyout variant under the
    /// same label, so filter to visible ones.
    @MainActor
    private func selectTool(named name: String, in app: XCUIApplication) {
        let matches = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@",
                        name, "\(name), selected")
        )
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 8),
                      "\(name) tool should be present in the palette")
        // No `isHittable` here: asking it on a mid-animation element
        // makes XCTest register "Failed to determine hittability …
        // activation point invalid" as a test failure before the loop
        // can skip the element (the recurring flake on this suite).
        // The frame filter alone drops the zero-frame flyout variant,
        // and coordinate taps don't require hittability.
        for attempt in 0..<3 {
            for i in 0..<matches.count {
                let b = matches.element(boundBy: i)
                guard b.exists else { continue }
                let f = b.frame
                guard f.width > 1, f.height > 1 else { continue }
                b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                Thread.sleep(forTimeInterval: 0.5)
                return
            }
            _ = attempt
            Thread.sleep(forTimeInterval: 0.75)   // palette still settling
        }
        XCTFail("No visible \(name) tool button found")
    }

    /// True while any element in the AX tree carries the marker text.
    @MainActor
    private func textExists(_ text: String, in app: XCUIApplication) -> Bool {
        if app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", text)
        ).firstMatch.exists { return true }
        return app.textViews.matching(
            NSPredicate(format: "value CONTAINS %@", text)
        ).firstMatch.exists
    }

    @MainActor
    private func waitForText(
        _ text: String, present: Bool, timeout: TimeInterval, in app: XCUIApplication
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if textExists(text, in: app) == present { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return textExists(text, in: app) == present
    }

    @MainActor
    func test_lasso_selectDeleteUndoRedo_textElement() throws {
        let app = makeApp()
        app.launch()
        completeOnboarding(name: "Lasso", in: app)
        openFreshNotebook(in: app)

        let marker = "HelloLasso"
        let window = app.windows.firstMatch

        // Create a text element in the middle of the page.
        selectTool(named: "Text", in: app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.42)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "Tapping with the text tool should open the keyboard")
        app.typeText(marker)
        // Exit editing with a tap on empty canvas (first tap only
        // exits edit mode; it does not create a second element).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.22)).tap()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(waitForText(marker, present: true, timeout: 5, in: app),
                      "Typed text element should be visible on the page")

        // Lasso-select it: diagonal drag across the element.
        selectTool(named: "Lasso", in: app)
        let lassoStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.30))
        let lassoEnd   = window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.55))
        lassoStart.press(forDuration: 0.05, thenDragTo: lassoEnd)

        // Selection chrome should surface the trash badge.
        let trashBadge = app.buttons["trash.circle.fill"].firstMatch
        XCTAssertTrue(trashBadge.waitForExistence(timeout: 5),
                      "Lasso selection should show the delete badge for the text element")
        trashBadge.tap()

        XCTAssertTrue(waitForText(marker, present: false, timeout: 5, in: app),
                      "Text element should disappear after lasso delete")

        // Undo restores the element.
        let undoButton = app.buttons["arrow.uturn.backward"].firstMatch
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilEnabled(undoButton, timeout: 5),
                      "Undo should be enabled after a lasso delete")
        undoButton.tap()
        XCTAssertTrue(waitForText(marker, present: true, timeout: 5, in: app),
                      "Undo should restore the lasso-deleted text element")

        // Redo deletes it again.
        let redoButton = app.buttons["arrow.uturn.forward"].firstMatch
        XCTAssertTrue(waitUntilEnabled(redoButton, timeout: 5),
                      "Redo should be enabled after undoing the delete")
        redoButton.tap()
        XCTAssertTrue(waitForText(marker, present: false, timeout: 5, in: app),
                      "Redo should re-delete the text element")
    }

    @MainActor
    private func waitUntilEnabled(
        _ element: XCUIElement, timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return element.exists && element.isEnabled
    }

    /// Drag the lasso diagonally across the given normalized window
    /// region and return whether the selection chrome (trash badge)
    /// appeared.
    @MainActor
    @discardableResult
    private func lassoAcross(
        from: CGVector, to: CGVector, in app: XCUIApplication
    ) -> Bool {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: to))
        let trashBadge = app.buttons["trash.circle.fill"].firstMatch
        return trashBadge.waitForExistence(timeout: 4)
    }

    /// Lasso select + delete of handwriting strokes. Draw two pen
    /// strokes, lasso across them (chrome must appear — strokes ARE
    /// selectable), delete via the badge, then lasso the same area
    /// again and verify nothing is left to select (the delete
    /// actually removed the strokes from the model, not just the
    /// chrome).
    @MainActor
    func test_lasso_selectAndDelete_strokes() throws {
        let app = makeApp()
        app.launch()
        completeOnboarding(name: "Strokes", in: app)
        openFreshNotebook(in: app)

        let window = app.windows.firstMatch

        // Draw two strokes with the pen.
        selectTool(named: "Pen", in: app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.40))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.50)))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.48))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.58)))
        Thread.sleep(forTimeInterval: 0.5)

        // Lasso across the strokes — selection chrome must appear.
        selectTool(named: "Lasso", in: app)
        XCTAssertTrue(
            lassoAcross(from: CGVector(dx: 0.25, dy: 0.32),
                        to: CGVector(dx: 0.68, dy: 0.64), in: app),
            "Lasso across handwriting should select the strokes and show the delete badge"
        )

        // Delete.
        app.buttons["trash.circle.fill"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(app.buttons["trash.circle.fill"].firstMatch.exists,
                       "Selection chrome should clear after delete")

        // Same lasso again — nothing left to select.
        XCTAssertFalse(
            lassoAcross(from: CGVector(dx: 0.25, dy: 0.32),
                        to: CGVector(dx: 0.68, dy: 0.64), in: app),
            "Re-lassoing the same area should find nothing — strokes were deleted from the model"
        )
    }

    /// Lasso transforms on a text element: move (chrome body drag),
    /// resize (corner handle), rotate (knob) — each committed, each
    /// undone. Asserts via the text element's accessibility frame
    /// and the undo button's enabled state.
    @MainActor
    func test_lasso_moveResizeRotate_withUndo() throws {
        let app = makeApp()
        app.launch()
        completeOnboarding(name: "Move", in: app)
        openFreshNotebook(in: app)

        let marker = "MoveMe"
        let window = app.windows.firstMatch

        // Create the text element.
        selectTool(named: "Text", in: app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.42)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText(marker)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.20)).tap()
        Thread.sleep(forTimeInterval: 0.5)

        func markerElement() -> XCUIElement {
            let st = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
            if st.exists { return st }
            return app.textViews.matching(
                NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
        }
        XCTAssertTrue(waitForText(marker, present: true, timeout: 5, in: app))
        let originalFrame = markerElement().frame

        let undoButton = app.buttons["arrow.uturn.backward"].firstMatch
        let trashBadge = app.buttons["trash.circle.fill"].firstMatch

        func lassoSelectMarker() {
            selectTool(named: "Lasso", in: app)
            XCTAssertTrue(
                lassoAcross(from: CGVector(dx: 0.22, dy: 0.30),
                            to: CGVector(dx: 0.72, dy: 0.55), in: app),
                "Lasso should select the text element"
            )
        }

        // ── MOVE ────────────────────────────────────────────────
        // Text-only selections are Y-locked; drag the chrome body
        // straight down from the element's centre.
        lassoSelectMarker()
        let centre = markerElement().frame.center
        let winFrame = window.frame
        let startVec = CGVector(dx: centre.x / winFrame.width,
                                dy: centre.y / winFrame.height)
        let endVec = CGVector(dx: startVec.dx, dy: startVec.dy + 0.12)
        window.coordinate(withNormalizedOffset: startVec)
            .press(forDuration: 0.1,
                   thenDragTo: window.coordinate(withNormalizedOffset: endVec))
        Thread.sleep(forTimeInterval: 1.0)

        let movedFrame = markerElement().frame
        XCTAssertGreaterThan(movedFrame.minY, originalFrame.minY + 40,
                             "Body drag should move the text element down")

        XCTAssertTrue(waitUntilEnabled(undoButton, timeout: 5),
                      "Undo should be enabled after a lasso move")
        undoButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let undoneMoveFrame = markerElement().frame
        XCTAssertEqual(undoneMoveFrame.minY, originalFrame.minY, accuracy: 20,
                       "Undo should restore the element's position")

        // ── RESIZE + ROTATE (on a shape) ────────────────────────
        // Text blocks are full-content-width by design (stored
        // normalizedWidth is ignored at the view layer), so resize
        // is asserted on a shape instead. The trash badge tracks the
        // chrome's bounding box, so its frame is the observable
        // proxy for the selection bounds.
        selection: do {
            // Clear the text selection out of the way.
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
            Thread.sleep(forTimeInterval: 0.5)
        }

        selectTool(named: "Shape", in: app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.60))
            .press(forDuration: 0.1,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.72)))
        Thread.sleep(forTimeInterval: 1.0)

        selectTool(named: "Cursor", in: app)
        let shapeCentre = CGVector(dx: 0.40, dy: 0.64)
        window.coordinate(withNormalizedOffset: shapeCentre).tap()
        XCTAssertTrue(trashBadge.waitForExistence(timeout: 4),
                      "Cursor tap should select the shape")
        let badgeFrame0 = trashBadge.frame

        // All chrome geometry is derived from the badge: its centre
        // sits at (bbox.maxX + 24, bbox.minY - 24). The shape's
        // creation drag can't be trusted for coordinates — finger
        // shape drags also scroll the canvas, displacing the result.
        func chromeTopRight() -> CGPoint {
            let b = trashBadge.frame
            return CGPoint(x: b.midX - 24, y: b.midY + 24)
        }

        // Resize: drag the TOP-RIGHT corner handle outward (right
        // and up — grows both width and height).
        var corner = chromeTopRight()
        window.coordinate(withNormalizedOffset: CGVector(
                dx: corner.x / winFrame.width, dy: corner.y / winFrame.height))
            .press(forDuration: 0.1,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(
                dx: (corner.x + 90) / winFrame.width,
                dy: (corner.y - 60) / winFrame.height)))
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertTrue(trashBadge.exists,
                      "Selection chrome should survive a resize commit")
        let badgeAfterResize = trashBadge.frame
        XCTAssertGreaterThan(badgeAfterResize.minX, badgeFrame0.minX + 20,
                             "Resize should grow the selection bounds (badge tracks the bbox)")

        XCTAssertTrue(waitUntilEnabled(undoButton, timeout: 5),
                      "Undo should be enabled after a lasso resize")
        undoButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
        // Undo restores geometry and clears the selection — re-select
        // and verify the chrome is back at its original bounds.
        window.coordinate(withNormalizedOffset: shapeCentre).tap()
        XCTAssertTrue(trashBadge.waitForExistence(timeout: 4),
                      "Shape should be selectable after resize undo")
        XCTAssertEqual(trashBadge.frame.minX, badgeFrame0.minX, accuracy: 20,
                       "Undo should restore the shape's original size")

        // Rotate: the knob floats 22pt above the bbox top edge,
        // horizontally at the bbox midX. We know maxX/minY from the
        // badge; minX ≈ the shape centre tap minus half the width —
        // estimate midX conservatively between the tap X and maxX.
        let preRotateBadge = trashBadge.frame
        corner = chromeTopRight()
        // The chrome's midX equals the shape-centre tap X: the
        // creation drag ran from 0.30 to 0.50 and vertical scroll
        // during creation preserves X, so the bbox is centred on
        // 0.40 — where we tapped.
        let knobX = shapeCentre.dx * winFrame.width
        let knobY = corner.y - 22
        window.coordinate(withNormalizedOffset: CGVector(
                dx: knobX / winFrame.width, dy: knobY / winFrame.height))
            .press(forDuration: 0.1,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(
                dx: (knobX + 200) / winFrame.width,
                dy: (knobY + 150) / winFrame.height)))
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertTrue(waitUntilEnabled(undoButton, timeout: 5),
                      "Undo should be enabled after a lasso rotate")
        // The rotate commit recomputes the chrome bounds around the
        // rotated shape — the badge should have moved.
        let badgeAfterRotate = trashBadge.frame
        let badgeMoved = abs(badgeAfterRotate.minX - preRotateBadge.minX) > 10
            || abs(badgeAfterRotate.minY - preRotateBadge.minY) > 10
        XCTAssertTrue(badgeMoved,
                      "Rotate commit should recompute the selection bounds around the rotated shape")

        undoButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
        window.coordinate(withNormalizedOffset: shapeCentre).tap()
        XCTAssertTrue(trashBadge.waitForExistence(timeout: 4),
                      "Shape should be selectable after rotate undo")
        XCTAssertEqual(trashBadge.frame.minX, preRotateBadge.minX, accuracy: 20,
                       "Undo should restore the shape's unrotated bounds")
    }

    /// Selection survives a move; only a blank-space tap clears it.
    /// Regression coverage for the device report "lasso gets
    /// deselected automatically after the user moves the element
    /// once (tested with strokes)" — the user expects the selection
    /// box to persist through consecutive moves until they tap
    /// empty canvas.
    @MainActor
    func test_lasso_moveStrokes_keepsSelection_untilBlankTap() throws {
        let app = makeApp()
        app.launch()
        completeOnboarding(name: "Keep", in: app)
        openFreshNotebook(in: app)

        let window = app.windows.firstMatch

        // Draw two strokes with the pen.
        selectTool(named: "Pen", in: app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.40))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.50)))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.48))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.58)))
        Thread.sleep(forTimeInterval: 0.5)

        // Lasso-select the strokes.
        selectTool(named: "Lasso", in: app)
        XCTAssertTrue(
            lassoAcross(from: CGVector(dx: 0.25, dy: 0.32),
                        to: CGVector(dx: 0.68, dy: 0.64), in: app),
            "Lasso across handwriting should select the strokes"
        )
        let trashBadge = app.buttons["trash.circle.fill"].firstMatch

        // Move the selection by dragging the chrome body (centre of
        // the selection), then verify the chrome SURVIVES the commit.
        let dragStart = CGVector(dx: 0.46, dy: 0.49)
        let dragEnd   = CGVector(dx: 0.46, dy: 0.62)
        window.coordinate(withNormalizedOffset: dragStart)
            .press(forDuration: 0.1,
                   thenDragTo: window.coordinate(withNormalizedOffset: dragEnd))
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(trashBadge.exists,
                      "Selection chrome should survive the first move")

        // A SECOND move must work on the same selection (a stale or
        // silently-cleared selection would leave this drag inert).
        window.coordinate(withNormalizedOffset: dragEnd)
            .press(forDuration: 0.1,
                   thenDragTo: window.coordinate(withNormalizedOffset: dragStart))
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(trashBadge.exists,
                      "Selection chrome should survive consecutive moves")

        // Blank-space tap clears.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(trashBadge.exists,
                       "Tapping blank canvas should clear the selection")
    }

    /// Cursor ("select") tool flow on a shape: create a shape with
    /// the shape tool, tap it with the cursor tool to select (this
    /// routes through the same lasso chrome), delete via the badge,
    /// verify it can't be selected again.
    @MainActor
    func test_cursorTool_selectAndDelete_shape() throws {
        let app = makeApp()
        app.launch()
        completeOnboarding(name: "Shapes", in: app)
        openFreshNotebook(in: app)

        let window = app.windows.firstMatch

        // Create a shape by dragging with the shape tool.
        selectTool(named: "Shape", in: app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.38))
            .press(forDuration: 0.1,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.52)))
        Thread.sleep(forTimeInterval: 1.0)

        // Tap it with the cursor tool → lasso chrome should appear.
        selectTool(named: "Cursor", in: app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)).tap()
        let trashBadge = app.buttons["trash.circle.fill"].firstMatch
        XCTAssertTrue(trashBadge.waitForExistence(timeout: 4),
                      "Cursor tap on a shape should select it with the lasso chrome")

        // Delete and verify it's gone.
        trashBadge.tap()
        Thread.sleep(forTimeInterval: 1.0)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)).tap()
        XCTAssertFalse(trashBadge.waitForExistence(timeout: 3),
                       "Tapping the deleted shape's spot should select nothing")
    }
}
