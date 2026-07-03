import XCTest

/// Settings surface walk — opens every section on the iPad rail and
/// asserts a section-distinctive control renders. Catches a broken
/// section (crash, blank detail, dead link) that the persistence
/// round-trip test wouldn't notice, plus regression-guards two
/// controls that were removed/retired because they weren't wired to
/// anything ("Pencil Hover Preview", the "on-device" quiz engine).
final class SettingsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterAssertions()
    }

    private func continueAfterAssertions() {
        continueAfterFailure = false
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        return app
    }

    private func completeOnboardingIfNeeded(in app: XCUIApplication) {
        let nameField = app.textFields["Your name"]
        guard nameField.waitForExistence(timeout: 8) else { return }
        nameField.tap()
        nameField.typeText("Sam")
        app.buttons["Continue"].tap()
        // Later onboarding steps (if any) — keep tapping Continue
        // while it exists, then a final Get Started-style button.
        for _ in 0..<4 {
            let cont = app.buttons["Continue"]
            if cont.waitForExistence(timeout: 2), cont.isHittable {
                cont.tap()
            } else {
                break
            }
        }
        let start = app.buttons["Get Started"]
        if start.waitForExistence(timeout: 2) { start.tap() }
    }

    @MainActor
    func test_settings_everySectionRenders() throws {
        let app = makeApp()
        app.launch()
        completeOnboardingIfNeeded(in: app)

        let gear = app.buttons.matching(identifier: "gearshape").firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 8),
                      "Library toolbar should expose the Settings gear")
        gear.tap()

        // (rail row label, distinctive element in that section's detail)
        let sections: [(row: String, anchorLabel: String)] = [
            ("appearance",            "resume where you left off"),
            ("apple pencil",          "Drawing Haptics"),
            ("audio & transcription", "Save audio clips"),
            ("icloud",                "iCloud sync"),
            ("storage",               "Audio recordings"),
            ("intelligence",          "quiz generation"),
            ("about",                 "privacy policy"),
        ]

        for section in sections {
            let row = app.buttons[section.row].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "Settings rail should list '\(section.row)'")
            row.tap()

            // The anchor may surface as a static text, toggle label,
            // or button depending on the control — search broadly.
            let anchor = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", section.anchorLabel))
                .firstMatch
            XCTAssertTrue(
                anchor.waitForExistence(timeout: 5),
                "Section '\(section.row)' should render '\(section.anchorLabel)'"
            )
        }

        // Regression guards — controls that were removed because they
        // weren't connected to anything must stay gone.
        app.buttons["apple pencil"].firstMatch.tap()
        XCTAssertFalse(
            app.switches["Pencil Hover Preview"].exists,
            "The dead 'Pencil Hover Preview' toggle must not return (hover is deliberately suppressed on the canvas)"
        )
        app.buttons["intelligence"].firstMatch.tap()
        XCTAssertFalse(
            app.staticTexts["on-device"].exists,
            "The retired 'on-device' quiz engine row must not be offered"
        )

        app.buttons["done"].tap()
    }
}
