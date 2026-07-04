import XCTest

/// iPhone-idiom end-to-end coverage. Run against an iPhone
/// simulator destination — the assertions encode the phone
/// capability contract (`DeviceCapabilities`):
///
///   • full library: create subject + notebook, see the notebook
///     card after an editor round-trip;
///   • text-as-element editing: the phone editor defaults to the
///     text tool, a page tap creates a text element, typed text
///     persists;
///   • NO drawing surface: the floating tool palette must not
///     mount (its drag handle is the stable a11y anchor);
///   • NO recording: the toolbar mic must not render (it gates on
///     `canRecord`, which is false on phones — regression guard
///     for the stale `.mutationOnly()` gate that showed a dead
///     mic after light editing was enabled).
///
/// The test skips itself on iPad so it can ride in the shared
/// bundle without constraining which destination runs the suite.
final class PhoneUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        if UIDevice.current.userInterfaceIdiom != .phone {
            throw XCTSkip("PhoneUITests only run on an iPhone destination")
        }
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        return app
    }

    private func completeOnboarding(name: String, in app: XCUIApplication) {
        let nameField = app.textFields["Your name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10),
                      "Onboarding TextField should appear on first launch")
        nameField.tap()
        nameField.typeText(name)
        // The phone layout can expose two "Continue" elements (body
        // CTA + keyboard accessory) — tap the hittable one.
        let continues = app.buttons.matching(identifier: "Continue").allElementsBoundByIndex
        (continues.first(where: { $0.isHittable }) ?? app.buttons["Continue"].firstMatch).tap()
        // System icon-change alert, if it appears.
        for label in ["OK", "Allow", "Continue"] {
            let button = app.alerts.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }
    }

    /// Dismiss the customise panel that auto-opens on a fresh
    /// notebook. On phone it covers the entire editor, so the page
    /// isn't tappable until it's gone. The panel animates in after
    /// the editor mounts — wait for its 'done', commit any focused
    /// title field with Return first, then confirm the panel left.
    private func dismissCustomisePanelIfPresent(in app: XCUIApplication) {
        let done = app.buttons["done"].firstMatch
        guard done.waitForExistence(timeout: 6) else { return }
        if app.keyboards.firstMatch.exists {
            app.typeText("\n")
        }
        for _ in 0..<3 {
            let hittable = app.buttons.matching(identifier: "done")
                .allElementsBoundByIndex.first { $0.isHittable }
            guard let hittable else { break }
            hittable.tap()
            // Panel gone when no hittable 'done' remains.
            if !app.buttons["done"].firstMatch.waitForExistence(timeout: 2) { break }
        }
        // Give the dismissal animation a beat before the page tap.
        _ = app.toolbars["Toolbar"].waitForExistence(timeout: 3)
    }

    @MainActor
    func test_phone_libraryAndTextElement_endToEnd() throws {
        let app = makeApp()
        app.launch()
        completeOnboarding(name: "Sam", in: app)

        // Library up — create subject, then notebook (same CTA flow
        // as iPad; labels are shared).
        let newSubject = app.buttons["+ new subject"].firstMatch
        XCTAssertTrue(newSubject.waitForExistence(timeout: 8),
                      "Phone library empty state should offer '+ new subject'")
        newSubject.tap()
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            app.typeText("\n")   // commit the default subject name
        }

        let newNotebook = app.buttons["+ new notebook"].firstMatch
        XCTAssertTrue(newNotebook.waitForExistence(timeout: 8),
                      "Phone library should offer '+ new notebook' once a subject exists")
        newNotebook.tap()

        // Editor should open.
        let editorToolbar = app.toolbars["Toolbar"]
        XCTAssertTrue(editorToolbar.waitForExistence(timeout: 10),
                      "Phone editor should open with its toolbar")
        dismissCustomisePanelIfPresent(in: app)

        // Capability contract: no tool palette, no mic.
        XCTAssertFalse(app.otherElements["Drag handle"].exists
                        && app.otherElements["Drag handle"].isHittable,
                       "Tool palette must not mount on iPhone (canDraw == false)")
        XCTAssertFalse(app.buttons["mic"].exists,
                       "Toolbar mic must not render on iPhone (canRecord == false)")

        // Text as an element: the phone editor defaults to the text
        // tool — a tap on the page body creates a text element and
        // focuses it.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8),
                      "Tapping the page in text mode should open the keyboard for a new text element")
        app.typeText("phone note")

        // Commit by tapping away from the element (background tap
        // ends editing), then verify the text renders on the page.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        let typed = app.textViews.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "phone note")
        ).firstMatch
        XCTAssertTrue(typed.waitForExistence(timeout: 8),
                      "Typed text should persist as a text element on the page")

        // Back to the library — the notebook card should be there
        // ("viewing all notebooks").
        let back = app.buttons["Back to library"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5),
                      "Phone editor toolbar should expose the back-to-library button")
        back.tap()

        let notebookCard = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'page'"))
            .firstMatch
        XCTAssertTrue(app.buttons["+ new notebook"].firstMatch.waitForExistence(timeout: 8)
                        || notebookCard.waitForExistence(timeout: 8),
                      "Library should be visible again after leaving the editor")

        // Re-open the notebook from the grid and confirm the text
        // element survived the round-trip (persistence, not just
        // in-memory state). Notebook cards merge their a11y children
        // into one element labelled
        // "<title>, <subject>, N pages, last modified …" — the
        // "last modified" phrase is unique to cards, so it can't
        // accidentally match the "+ new notebook" CTA.
        let card = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'last modified'")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8),
                      "Library should show the created notebook card")
        card.tap()
        let persisted = app.textViews.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "phone note")
        ).firstMatch
        XCTAssertTrue(persisted.waitForExistence(timeout: 10),
                      "Text element should persist across an editor round-trip on iPhone")
    }
}
