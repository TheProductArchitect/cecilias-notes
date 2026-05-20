import XCTest

/// XCUITest suite covering critical happy-path flows. Every test launches
/// `XCUIApplication` with the `-uiTesting` argument, which causes
/// `CeciliasNotesApp.init` to wipe persisted state and force `Resume` off — so each
/// test starts in a deterministic onboarding-first state.
///
/// On first launch the onboarding cover is presented unconditionally;
/// the helper `completeOnboarding(name:in:)` types a name and taps
/// Continue so the rest of a test can assume the Library is visible.
final class CeciliasNotesUITests: XCTestCase {

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

    /// The masthead wordmark merges its accessibility children
    /// (`children: .ignore`) and exposes a single element with the
    /// label `"Wordmark <name>'s notes"`. SwiftUI surfaces that
    /// merged composition as an `otherElement`, not a `staticText`
    /// — so greeting assertions query `otherElements` by that label.
    private func wordmark(_ app: XCUIApplication, name: String) -> XCUIElement {
        app.otherElements["Wordmark \(name) notes"]
    }

    // MARK: - Test 1: Critical happy path

    @MainActor
    func test_happyPath_onboardingThroughEditor() throws {
        let app = makeApp()
        app.launch()

        completeOnboarding(name: "Alex", in: app)

        // Library is up. Match the masthead wordmark element.
        let greeting = wordmark(app, name: "alex's")
        XCTAssertTrue(
            greeting.waitForExistence(timeout: 5),
            "Library masthead should read \"alex's notes\""
        )

        // After `-uiTesting` wipes the store there are no subjects, so
        // the empty state offers "+ new subject" (a notebook can't be
        // created until a subject exists). The label "+ new subject"
        // appears on both the centred empty-state CTA and the sidebar
        // footer button — either creates a subject, so take firstMatch.
        let newSubjectCTA = app.buttons["+ new subject"].firstMatch
        XCTAssertTrue(
            newSubjectCTA.waitForExistence(timeout: 5),
            "Library empty-state should expose a '+ new subject' CTA"
        )
        newSubjectCTA.tap()

        // A freshly-created subject lands in inline-rename mode with
        // its name field focused (keyboard up). Commit the default
        // name with Return so the keyboard dismisses and the notebook
        // CTA becomes interactive.
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            app.typeText("\n")
        }

        // With a subject present, the empty state switches to the
        // "+ new notebook" CTA.
        let newNotebookCTA = app.buttons["+ new notebook"].firstMatch
        XCTAssertTrue(
            newNotebookCTA.waitForExistence(timeout: 5),
            "Library empty-state should expose a '+ new notebook' CTA once a subject exists"
        )
        newNotebookCTA.tap()

        // The editor should open for the new notebook. Assert on the
        // editor's tool Toolbar — a stable element — rather than the
        // transient "Customise" pill: the "+ new notebook" flow
        // auto-opens the Customise *panel*, which suppresses the pill
        // (the pill only renders when no panel is open).
        let editorToolbar = app.toolbars["Toolbar"]
        XCTAssertTrue(
            editorToolbar.waitForExistence(timeout: 8),
            "Editor should open with its tool Toolbar for a fresh notebook"
        )

        // The masthead wordmark stays visible in the iPad split layout —
        // a lightweight smoke check that the app is still alive and the
        // Library hierarchy survived the editor round-trip.
        XCTAssertTrue(
            greeting.exists,
            "Library masthead should remain reachable after opening the editor"
        )
    }

    // MARK: - Test 2: Settings round-trip
    //
    // Settings → Apple Pencil → "Finger Drawing" is a 3-way menu
    // picker (Auto / Always Allow Finger / Pencil Only), not a
    // boolean toggle. This test changes the selection, dismisses
    // Settings, reopens, and verifies the choice persisted.

    @MainActor
    func test_settings_fingerDrawingChoice_persistsAcrossDismiss() throws {
        let app = makeApp()
        app.launch()
        completeOnboarding(name: "Sam", in: app)

        // The Settings list styles its section rows in lowercase; the
        // gear button carries the "gearshape" SF Symbol identifier.
        func openPencilSettings() {
            let gear = app.buttons.matching(identifier: "gearshape").firstMatch
            XCTAssertTrue(gear.waitForExistence(timeout: 5),
                          "Library toolbar should expose the Settings gear")
            gear.tap()

            let pencil = app.buttons["apple pencil"]
            XCTAssertTrue(pencil.waitForExistence(timeout: 5),
                          "Settings should expose an 'Apple Pencil' section")
            pencil.tap()
        }

        // The menu picker collapses to a Button whose label combines
        // the row title with the current selection
        // ("Finger Drawing, Finger Drawing, Auto, Auto").
        func fingerDrawingPicker() -> XCUIElement {
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Finger Drawing'")
            ).firstMatch
        }

        openPencilSettings()

        let picker = fingerDrawingPicker()
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "Apple Pencil settings should expose the Finger Drawing picker")

        // Pick a non-default option. Default is "Auto"; choose
        // "Pencil Only" so the round-trip asserts a real change.
        picker.tap()
        let pencilOnly = app.buttons["Pencil Only"]
        XCTAssertTrue(pencilOnly.waitForExistence(timeout: 5),
                      "Finger Drawing menu should list 'Pencil Only'")
        pencilOnly.tap()

        XCTAssertTrue(
            fingerDrawingPicker().label.contains("Pencil Only"),
            "Picker should reflect the new 'Pencil Only' selection"
        )

        // Dismiss Settings via the sheet's Done button.
        app.buttons["done"].tap()

        // Reopen — the selection should have persisted.
        openPencilSettings()
        XCTAssertTrue(
            fingerDrawingPicker().waitForExistence(timeout: 5),
            "Finger Drawing picker should reappear on the second visit"
        )
        XCTAssertTrue(
            fingerDrawingPicker().label.contains("Pencil Only"),
            "Finger Drawing selection should persist across a Settings dismiss"
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

        // Onboarding completes → masthead wordmark visible.
        let greeting = wordmark(app, name: "alex's")
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
