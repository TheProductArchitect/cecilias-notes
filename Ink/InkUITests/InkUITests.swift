import XCTest

/// XCUITest suite covering critical happy-path flows. Every test launches
/// `XCUIApplication` with the `-uiTesting` argument, which causes
/// `InkApp.init` to wipe persisted state and force `Resume` off — so each
/// test starts in a deterministic onboarding-first state.
///
/// On first launch the onboarding cover is presented unconditionally;
/// the helper `completeOnboarding(name:in:)` types a name and taps
/// Continue so the rest of a test can assume the Library is visible.
final class InkUITests: XCTestCase {

    override func setUpWithError() throws {
        // UI tests should fail fast when an expected element doesn't appear.
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        return app
    }

    /// Type the supplied name into the onboarding TextField and tap
    /// Continue. Accepts the system icon-change alert if it appears
    /// (Apple's alert; cannot be styled or suppressed).
    private func completeOnboarding(name: String, in app: XCUIApplication) {
        let nameField = app.textFields["Your name"]
        XCTAssertTrue(
            nameField.waitForExistence(timeout: 10),
            "Onboarding TextField should appear on first launch"
        )
        nameField.tap()
        nameField.typeText(name)

        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.tap()

        // Apple's "Change Icon?" alert appears when setAlternateIconName
        // fires. Dismiss with the system "OK" if shown — alert wording
        // is locale-dependent so handle multiple variants.
        let okButtonLabels = ["OK", "Allow", "Continue"]
        for label in okButtonLabels {
            let button = app.alerts.buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                break
            }
        }
    }

    // MARK: - Test 1: Critical happy path

    @MainActor
    func test_happyPath_onboardingThroughEditor() throws {
        let app = makeApp()
        app.launch()

        completeOnboarding(name: "Alex", in: app)

        // Library is up. Match the greeting by static-text content.
        let greeting = app.staticTexts["alex's notes"]
        XCTAssertTrue(
            greeting.waitForExistence(timeout: 5),
            "Library greeting should read \"alex's notes\""
        )

        // The Library is empty after `-uiTesting` wipes the store, so
        // the empty-state "New Notebook" CTA is visible. Tap it
        // directly instead of opening the toolbar's "+" Menu — both
        // call the same `createUntitledNotebookAndOpen()`, but the CTA
        // is unambiguous (no menu-item collision).
        let newNotebookCTA = app.buttons["New Notebook"]
        XCTAssertTrue(
            newNotebookCTA.waitForExistence(timeout: 5),
            "Library empty-state should expose a 'New Notebook' CTA"
        )
        newNotebookCTA.tap()

        // Customise pill should appear within ~1s of editor opening.
        let pill = app.buttons["Customise notebook"]
        XCTAssertTrue(
            pill.waitForExistence(timeout: 5),
            "Customise pill should appear in the editor for a fresh notebook"
        )

        // The pill auto-dismisses at 5s. Poll-wait so the test fails
        // fast if the pill *doesn't* disappear.
        let pillGonePredicate = NSPredicate(format: "exists == false")
        expectation(for: pillGonePredicate, evaluatedWith: pill, handler: nil)
        waitForExpectations(timeout: 8)

        // Return to Library via the back button.
        let backButton = app.buttons.matching(identifier: "Back").firstMatch
        if backButton.exists {
            backButton.tap()
        } else {
            // Fallback: keyboard shortcut ⌘W
            app.typeKey("w", modifierFlags: .command)
        }

        XCTAssertTrue(
            greeting.waitForExistence(timeout: 5),
            "Should return to Library showing the personal greeting"
        )
    }

    // MARK: - Test 2: Settings round-trip

    @MainActor
    func test_settings_roundTrip_persistsToggle() throws {
        let app = makeApp()
        app.launch()
        completeOnboarding(name: "Sam", in: app)

        // Open Settings via the gear button. SF Symbol "gearshape" is
        // the rendered icon.
        let gearButton = app.buttons.matching(identifier: "gearshape").firstMatch
        if gearButton.waitForExistence(timeout: 5) {
            gearButton.tap()
        } else {
            app.buttons["Settings"].tap()
        }

        // Navigate to Apple Pencil section. SwiftUI Settings list rows
        // are cells; some iOS versions report them as buttons. Try both.
        let pencilCell    = app.cells["Apple Pencil"]
        let pencilButton  = app.buttons["Apple Pencil"]
        let pencilStaticText = app.staticTexts["Apple Pencil"]
        let pencilHit: XCUIElement = {
            if pencilCell.waitForExistence(timeout: 3)    { return pencilCell }
            if pencilButton.waitForExistence(timeout: 3)  { return pencilButton }
            if pencilStaticText.waitForExistence(timeout: 3) { return pencilStaticText }
            return pencilCell
        }()
        XCTAssertTrue(pencilHit.exists,
                      "Settings should expose an 'Apple Pencil' section")
        pencilHit.tap()

        // Toggle Finger Drawing on.
        let toggle = app.switches["Finger Drawing"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let initial = toggle.value as? String ?? "0"
        if initial == "0" { toggle.tap() }

        // Dismiss Settings (sheet drag-down).
        app.swipeDown()

        // Reopen settings — toggle should persist.
        if gearButton.waitForExistence(timeout: 5) { gearButton.tap() }
        let pencilCell2  = app.cells["Apple Pencil"]
        let pencilBtn2   = app.buttons["Apple Pencil"]
        if pencilCell2.waitForExistence(timeout: 5)      { pencilCell2.tap() }
        else if pencilBtn2.waitForExistence(timeout: 3)  { pencilBtn2.tap() }

        let toggleAgain = app.switches["Finger Drawing"]
        XCTAssertTrue(toggleAgain.waitForExistence(timeout: 5))
        XCTAssertEqual(
            toggleAgain.value as? String, "1",
            "Finger Drawing toggle should remain on across Settings dismiss"
        )
    }

    // MARK: - Test 3: Onboarding rejection paths

    @MainActor
    func test_onboarding_rejectsDigits_thenAcceptsValidName() throws {
        let app = makeApp()
        app.launch()

        let nameField = app.textFields["Your name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("Alex123")

        app.buttons["Continue"].tap()

        // Validation message under the field — exact copy.
        let error = app.staticTexts["Letters only, please."]
        XCTAssertTrue(
            error.waitForExistence(timeout: 3),
            "Validation should reject digit input with the correct copy"
        )

        // The field still contains the rejected text. iOS sometimes
        // reports the value with surrounding accessibility chrome, so
        // check via CONTAINS rather than exact equality.
        let fieldValue = nameField.value as? String ?? ""
        XCTAssertTrue(
            fieldValue.contains("Alex123") || fieldValue.contains("123"),
            "Field should retain the user's input after validation error (got '\(fieldValue)')"
        )

        // Clear the field by typing backspaces, then enter the valid
        // name. Triple-tap is unreliable in onboarding's auto-focused
        // field across iOS versions; backspacing is deterministic.
        let currentText = nameField.value as? String ?? ""
        nameField.tap()
        nameField.typeText(String(repeating: "\u{8}", count: currentText.count))
        nameField.typeText("Alex")
        app.buttons["Continue"].tap()

        // Onboarding completes → greeting visible.
        let greeting = app.staticTexts["alex's notes"]
        XCTAssertTrue(
            greeting.waitForExistence(timeout: 10),
            "Onboarding should complete after correcting the input"
        )
    }

    // MARK: - Test 4: Toolbar drag smoke
    //
    // Drags the toolbar to the bottom edge and verifies the app remains
    // responsive. Asserting precise pixel position needs accessibility
    // identifiers on the toolbar's edge state, which the design system
    // doesn't currently expose; this test catches a hung-drag regression.

    @MainActor
    func test_toolbarDrag_doesNotHangApp() throws {
        let app = makeApp()
        app.launch()
        completeOnboarding(name: "Drag", in: app)

        // Empty-state CTA — same as test 1's path.
        let newNotebookCTA = app.buttons["New Notebook"]
        if newNotebookCTA.waitForExistence(timeout: 5) { newNotebookCTA.tap() }

        // Coordinate-based drag from a right-edge point (where the
        // vertical-orientation toolbar sits by default in landscape) to
        // the bottom edge.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        let to   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        from.press(forDuration: 0.6, thenDragTo: to)

        // Smoke check: app is still alive and rendering buttons.
        XCTAssertTrue(
            app.buttons.firstMatch.exists,
            "Editor should remain responsive after a toolbar drag"
        )
    }
}
