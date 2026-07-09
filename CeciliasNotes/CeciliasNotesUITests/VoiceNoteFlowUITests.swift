import XCTest

/// Reproduces the App Store review crash report verbatim:
///
///   "Launched the app and created a new subject. Tapped on the
///    microphone button and then 'Voice note'. App crashed."
///   — iPad Air 11-inch (M3), iPadOS 26.5.2
///
/// The reviewer's steps compress notebook creation (the mic button
/// only exists in the editor toolbar), so the full path is:
/// onboarding → new subject → new notebook → editor → mic →
/// Voice note → recording strip → stop.
///
/// The suite asserts the app SURVIVES every step — any crash fails
/// the test with `app.state != .runningForeground`. Run this on an
/// iPad simulator; mic capture uses the host microphone, and the
/// permission alert is handled by an interruption monitor (or
/// pre-granted via `simctl privacy grant microphone`).
final class VoiceNoteFlowUITests: XCTestCase {

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

    @MainActor
    func test_voiceNote_reviewerSteps_doesNotCrash() throws {
        let app = makeApp()

        // The mic permission alert is a springboard alert — accept it
        // whenever it interrupts. (When the runner pre-grants via
        // `simctl privacy`, this monitor simply never fires.)
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            for label in ["Allow", "OK"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }

        app.launch()
        completeOnboarding(name: "Reviewer", in: app)

        // Onboarding ends behind a full-screen "Personalising your
        // app…" overlay that lingers over the library for several
        // seconds; taps during it land on the overlay and silently
        // do nothing. Wait it out before driving the library.
        let personalising = app.staticTexts["Personalising your app…"]
        let overlayDeadline = Date().addingTimeInterval(20)
        while personalising.exists && Date() < overlayDeadline {
            Thread.sleep(forTimeInterval: 0.5)
        }

        // The "You have changed the icon for Cecilia's Notes" alert
        // surfaces AFTER the personalising overlay clears — not
        // during onboarding, where completeOnboarding already looks
        // for it. It scrims the whole library; dismiss it or every
        // tap below lands on the scrim.
        let iconAlertOK = app.alerts.buttons["OK"].firstMatch
        if iconAlertOK.waitForExistence(timeout: 8) {
            iconAlertOK.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Step: create a new subject.
        let newSubjectCTA = app.buttons["+ new subject"].firstMatch
        XCTAssertTrue(newSubjectCTA.waitForExistence(timeout: 8),
                      "Library empty-state '+ new subject' CTA should appear")
        let hittableDeadline = Date().addingTimeInterval(10)
        while !newSubjectCTA.isHittable && Date() < hittableDeadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        newSubjectCTA.tap()
        // Commit the inline subject rename WITHOUT typing: on
        // hardware-keyboard simulators the rename field may never
        // receive keyboard focus, so `typeText` fails the test
        // before the flow under test even runs. Tapping a neutral
        // spot ends editing and keeps the default subject name.
        Thread.sleep(forTimeInterval: 1.0)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        Thread.sleep(forTimeInterval: 1.0)

        // Step (implicit in the report): a notebook, so the editor
        // and its mic button exist. Use the library toolbar's primary
        // "New notebook" button — it enables once a subject exists;
        // the sidebar's "+ new notebook" footer proved untappable in
        // automation (bottom-edge hit region).
        let newNotebookCTA = app.buttons["New notebook"].firstMatch
        XCTAssertTrue(newNotebookCTA.waitForExistence(timeout: 8),
                      "Library toolbar 'New notebook' button should exist")
        let enabledDeadline = Date().addingTimeInterval(8)
        while !newNotebookCTA.isEnabled && Date() < enabledDeadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(newNotebookCTA.isEnabled,
                      "'New notebook' should enable once a subject exists")
        newNotebookCTA.tap()

        // Step: tap the microphone button. Its appearance is also the
        // "editor is open" signal — the editor toolbar is a custom
        // SwiftUI view, not a UIToolbar, so `app.toolbars` never
        // matches on iPad.
        let micButton = app.buttons["mic"].firstMatch
        XCTAssertTrue(micButton.waitForExistence(timeout: 15),
                      "Editor mic button should appear after creating a notebook")
        micButton.tap()

        // Step: tap "Voice note".
        let voiceNoteOption = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Voice note'")
        ).firstMatch
        XCTAssertTrue(voiceNoteOption.waitForExistence(timeout: 8),
                      "Recording popover should present 'Voice note' option")
        voiceNoteOption.tap()

        // Interruption monitors only fire on the next interaction —
        // poke the app so a pending permission alert gets handled.
        app.tap()

        // THE assertion the reviewer's device failed: the app is
        // still alive in the seconds after the tap, while the
        // permission → session activation → engine start → placeholder
        // element sequence runs.
        let deadline = Date().addingTimeInterval(12)
        var sawRecordingUI = false
        while Date() < deadline {
            XCTAssertEqual(app.state, .runningForeground,
                           "App must not crash after tapping 'Voice note'")
            // Recording strip shows an elapsed timer + stop control.
            if app.buttons["Stop recording"].firstMatch.exists
                || app.buttons["stop.fill"].firstMatch.exists {
                sawRecordingUI = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(app.state, .runningForeground)

        // If recording actually started (permission granted), let it
        // roll a moment and stop — the stop path (engine teardown,
        // session deactivation, finalizeVoiceNote save) is equally
        // crash-prone territory.
        if sawRecordingUI {
            Thread.sleep(forTimeInterval: 2.0)
            let stop = app.buttons["Stop recording"].firstMatch.exists
                ? app.buttons["Stop recording"].firstMatch
                : app.buttons["stop.fill"].firstMatch
            if stop.exists { stop.tap() }
            let stopDeadline = Date().addingTimeInterval(8)
            while Date() < stopDeadline {
                XCTAssertEqual(app.state, .runningForeground,
                               "App must not crash while finalizing the voice note")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        // Editor must still be functional either way.
        XCTAssertTrue(micButton.exists,
                      "Editor mic button should still be present after the voice-note flow")
    }
}
