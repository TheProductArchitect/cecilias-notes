import XCTest

final class DictationFlowUITests: XCTestCase {

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
        // Handle icon-change or other alerts (icon change is skipped in -uiTesting,
        // but guard against any other system alert from the onboarding path).
        for label in ["OK", "Allow", "Continue", "Don't Allow"] {
            let button = app.alerts.buttons[label].firstMatch
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }
    }

    // Dictation flow: onboarding → create subject+notebook → open editor →
    // tap mic → tap Dictation → verify no freeze.
    //
    // On simulator the mic hardware isn't available, so recorder.start() will
    // fail within the 8-second withDictationTimeout; the app must stay
    // responsive throughout and not deadlock on the main thread.
    @MainActor
    func test_dictation_doesNotFreezeApp() throws {
        let app = makeApp()
        app.launch()

        completeOnboarding(name: "Dictation", in: app)

        // Library should appear with empty-state subject CTA.
        let newSubjectCTA = app.buttons["+ new subject"].firstMatch
        XCTAssertTrue(newSubjectCTA.waitForExistence(timeout: 8),
                      "Library empty-state '+ new subject' CTA should appear after onboarding")
        newSubjectCTA.tap()

        // A freshly-created subject opens in inline-rename mode.
        // Commit with Return so the keyboard dismisses and the notebook CTA shows.
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            app.typeText("\n")
        }

        // With a subject present the empty state shows '+ new notebook'.
        let newNotebookCTA = app.buttons["+ new notebook"].firstMatch
        XCTAssertTrue(newNotebookCTA.waitForExistence(timeout: 8),
                      "Library should show '+ new notebook' CTA once a subject exists")
        newNotebookCTA.tap()

        // Editor should open — wait for the toolbar.
        let editorToolbar = app.toolbars["Toolbar"]
        XCTAssertTrue(editorToolbar.waitForExistence(timeout: 10),
                      "Editor toolbar should appear after opening a new notebook")

        // Find the mic button (SF Symbol "mic", accessibility label "mic").
        let micButton = app.buttons["mic"].firstMatch
        XCTAssertTrue(micButton.waitForExistence(timeout: 8),
                      "Mic recording button should be visible in the editor toolbar")

        let tapTime = Date()
        micButton.tap()

        // Recording-mode popover should show the Dictation option.
        // The button's accessibility label may include the subtitle
        // ("Long-form with live transcript. New page."), so match
        // by prefix rather than exact string.
        let dictationOption = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Dictation'")
        ).firstMatch
        XCTAssertTrue(dictationOption.waitForExistence(timeout: 8),
                      "Recording popover should present 'Dictation' option")
        dictationOption.tap()

        // CRITICAL: app must remain responsive within 12 seconds of the tap.
        // The dictation flow:
        //   1. createPage (SwiftData write, fast in local-only mode)
        //   2. recorder.start() wrapped in withDictationTimeout(8s)
        //   3. createInitialTextElement (SwiftData write)
        // In simulator the recorder fails within 8s; the main thread should
        // never be blocked longer than ~9s total from this point.
        //
        // We poll `app.toolbars.firstMatch.exists` — it probes the
        // accessibility tree without a hit-test, so it returns quickly
        // even when the app is mid-async-work.
        var alive = false
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if app.toolbars.firstMatch.exists {
                alive = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let elapsed = Date().timeIntervalSince(tapTime)
        XCTAssertTrue(
            alive,
            "App should remain responsive within 12s of tapping Dictation. " +
            "Elapsed: \(String(format: "%.1f", elapsed))s. " +
            "A freeze here means the main thread is blocked — check SwiftData " +
            "save / audio-engine init sequence."
        )

        // Editor should still be functional after the dictation attempt.
        XCTAssertTrue(
            editorToolbar.exists,
            "Editor toolbar should still be visible after dictation attempt"
        )
    }
}
