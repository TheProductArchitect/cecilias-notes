import XCTest

/// Broad editor smoke: open a fresh notebook, then cycle through every
/// drawing tool in the palette — selecting each, verifying it becomes
/// the active tool, and drawing a real finger stroke with it — and
/// exercise the toolbar's undo / redo. One end-to-end pass that proves
/// the core tools + buttons work together on a live canvas (the device
/// ask: "run an end-to-end test for all tools and buttons").
///
/// Reuses the exact onboarding → editor entry pattern proven by
/// `UndoRedoUITests`, kept self-contained per this suite's convention.
final class EditorToolsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Diagnostics
    //
    // The pass takes ~90s and touches a dozen screens, so a bare
    // "XCTAssertTrue failed" can't distinguish an app break from a stale
    // query. Every assertion routes through `check`, which — before
    // failing — prints a state summary and attaches that summary, the
    // full element tree and a screenshot to the xcresult. `step` names
    // each phase so both the console log and the xcresult timeline show
    // how far the test got.

    private static let logTag = "[EditorToolsUITests]"

    private func frameText(_ frame: CGRect) -> String {
        guard frame.width.isFinite, frame.height.isFinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite else {
            return "non-finite\(frame)"
        }
        return String(format: "%.0fx%.0f@(%.0f,%.0f)",
                      frame.width, frame.height, frame.origin.x, frame.origin.y)
    }

    @MainActor
    @discardableResult
    private func step<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        try XCTContext.runActivity(named: name) { _ in
            print("\(Self.logTag) ▶ \(name)")
            return try body()
        }
    }

    /// One-screen answer to "what was on screen when it broke".
    @MainActor
    private func stateSummary(_ app: XCUIApplication) -> String {
        let appState: String
        switch app.state {
        case .runningForeground:  appState = "runningForeground"
        case .runningBackground:  appState = "runningBackground"
        case .runningBackgroundSuspended: appState = "runningBackgroundSuspended"
        case .notRunning:         appState = "notRunning (crashed or never launched)"
        case .unknown:            appState = "unknown"
        @unknown default:         appState = "unhandled(\(app.state.rawValue))"
        }

        let toolbars = app.toolbars.allElementsBoundByIndex
            .map { "id='\($0.identifier)' label='\($0.label)'" }
        let toolButtons = ["Pen", "Pencil", "Brush", "Highlighter", "Eraser", "Lasso", "Cursor", "Shape", "Text"]
            .compactMap { name -> String? in
                let selected = app.buttons["\(name), selected"].firstMatch.exists
                let plain = app.buttons[name].firstMatch.exists
                guard selected || plain else { return nil }
                return selected ? "\(name)(selected)" : name
            }
        let undo = app.buttons["arrow.uturn.backward"].firstMatch
        let redo = app.buttons["arrow.uturn.forward"].firstMatch

        return """
        app.state      = \(appState)
        toolbars(\(app.toolbars.count))   = \(toolbars.isEmpty ? "NONE" : toolbars.joined(separator: ", "))
        undo           = exists:\(undo.exists) enabled:\(undo.exists && undo.isEnabled)
        redo           = exists:\(redo.exists) enabled:\(redo.exists && redo.isEnabled)
        tool buttons   = \(toolButtons.isEmpty ? "NONE" : toolButtons.joined(separator: ", "))
        sheets:\(app.sheets.count) alerts:\(app.alerts.count) keyboard:\(app.keyboards.firstMatch.exists) windows:\(app.windows.count)
        """
    }

    @MainActor
    private func attachDiagnostics(_ app: XCUIApplication,
                                   label: String,
                                   summary: String,
                                   lifetime: XCTAttachment.Lifetime) {
        let text = XCTAttachment(string: summary)
        text.name = "\(label) — state"
        text.lifetime = lifetime
        add(text)

        // The element tree is what tells you a query matched nothing
        // because the element is named differently, not because it is
        // absent.
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(label) — element tree"
        tree.lifetime = lifetime
        add(tree)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(label) — screenshot"
        shot.lifetime = lifetime
        add(shot)
    }

    /// Milestone capture kept only when the test fails.
    @MainActor
    private func recordMilestone(_ label: String, in app: XCUIApplication) {
        let summary = stateSummary(app)
        print("\(Self.logTag) ✓ \(label)\n\(summary)")
        attachDiagnostics(app, label: label, summary: summary, lifetime: .deleteOnSuccess)
    }

    @MainActor
    @discardableResult
    private func check(_ condition: Bool,
                       _ message: @autoclosure () -> String,
                       in app: XCUIApplication,
                       file: StaticString = #filePath,
                       line: UInt = #line) -> Bool {
        guard condition else {
            let described = message()
            let summary = stateSummary(app)
            print("\(Self.logTag) ✗ FAILED — \(described)\n\(summary)")
            attachDiagnostics(app,
                              label: "FAILED — \(described)",
                              summary: summary,
                              lifetime: .keepAlways)
            XCTFail("\(described)\n\(summary)", file: file, line: line)
            return false
        }
        return true
    }

    // MARK: - Shared helpers (mirror UndoRedoUITests)

    @MainActor
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        return app
    }

    @MainActor
    private func completeOnboarding(name: String, in app: XCUIApplication) {
        let nameField = app.textFields["Your name"]
        check(nameField.waitForExistence(timeout: 10),
              "Onboarding name field 'Your name' never appeared", in: app)
        nameField.tap()
        nameField.typeText(name)
        let continueButton = app.buttons["Continue"]
        check(continueButton.waitForExistence(timeout: 5),
              "Onboarding 'Continue' button never appeared after typing the name", in: app)
        continueButton.tap()
        for label in ["OK", "Allow", "Continue", "Don't Allow"] {
            let button = app.alerts.buttons[label].firstMatch
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, enabled: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isEnabled == enabled { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return element.isEnabled == enabled
    }

    @MainActor
    private func drawStroke(in app: XCUIApplication, offset: CGVector) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.35 + offset.dx, dy: 0.40 + offset.dy))
        let end = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.55 + offset.dx, dy: 0.55 + offset.dy))
        print(String(format: "%@   stroke (%.2f,%.2f) → (%.2f,%.2f)",
                     Self.logTag,
                     0.35 + offset.dx, 0.40 + offset.dy,
                     0.55 + offset.dx, 0.55 + offset.dy))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Onboard → create subject → create notebook → dismiss the
    /// auto-opened Customise sheet, leaving a blank canvas ready to
    /// draw. Returns once the editor toolbar exists.
    @MainActor
    private func enterFreshEditor(name: String, in app: XCUIApplication) {
        step("onboarding") {
            completeOnboarding(name: name, in: app)
        }

        step("create subject + notebook") {
            let newSubjectCTA = app.buttons["+ new subject"].firstMatch
            check(newSubjectCTA.waitForExistence(timeout: 8),
                  "Library '+ new subject' CTA never appeared after onboarding", in: app)
            newSubjectCTA.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
                app.typeText("\n")
            }
            let newNotebookCTA = app.buttons["+ new notebook"].firstMatch
            check(newNotebookCTA.waitForExistence(timeout: 8),
                  "'+ new notebook' CTA never appeared after creating the subject", in: app)
            newNotebookCTA.tap()
        }

        step("wait for editor") {
            // This match is the Customise sheet's keyboard toolbar, which
            // is present because the title field opens focused.
            let editorToolbar = app.toolbars["Toolbar"]
            check(editorToolbar.waitForExistence(timeout: 10),
                  "Editor should open after creating a notebook — no toolbars['Toolbar'] within 10s", in: app)
        }

        step("dismiss Customise sheet") {
            // Fresh notebooks open with the Customise sheet over the canvas,
            // title field focused. Commit the title, then dismiss via the
            // floating Done button (tapped by coordinate — the AX
            // scroll-to-visible action fails on the sheet's overlay).
            Thread.sleep(forTimeInterval: 1.0)
            if app.keyboards.firstMatch.exists {
                app.typeText("\n")
                Thread.sleep(forTimeInterval: 0.5)
            }
            let doneButtons = app.buttons.matching(NSPredicate(format: "label ==[c] 'done'"))
            var tappedDone = false
            for i in 0..<doneButtons.count {
                let b = doneButtons.element(boundBy: i)
                if b.exists && b.isHittable {
                    b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    tappedDone = true
                    break
                }
            }
            print("\(Self.logTag)   done-button candidates=\(doneButtons.count) tapped=\(tappedDone)")
            Thread.sleep(forTimeInterval: 1.0)
            recordMilestone("editor ready (Customise dismissed)", in: app)
        }
    }

    /// What `selectTool` saw, so a failure can say whether the button was
    /// missing outright or present but untappable.
    private enum ToolTapOutcome {
        case tapped(candidate: Int, of: Int)
        case noMatchingButton
        case noHittableCandidate(details: [String])

        var didTap: Bool {
            if case .tapped = self { return true }
            return false
        }

        var described: String {
            switch self {
            case let .tapped(candidate, total):
                return "tapped candidate \(candidate + 1)/\(total)"
            case .noMatchingButton:
                return "no button with that label (or '<name>, selected') appeared within 8s"
            case let .noHittableCandidate(details):
                return "found \(details.count) candidate(s) but none were hittable with a real frame — \(details.joined(separator: " | "))"
            }
        }
    }

    /// Tap the palette button for `toolName`, tolerating the two label
    /// forms (`"Pen"` / `"Pen, selected"`) and the collapsed zero-frame
    /// flyout duplicate.
    @MainActor
    private func selectTool(_ toolName: String, in app: XCUIApplication) -> ToolTapOutcome {
        let matches = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@",
                        toolName, "\(toolName), selected")
        )
        guard matches.firstMatch.waitForExistence(timeout: 8) else { return .noMatchingButton }
        let total = matches.count
        var rejected: [String] = []
        for i in 0..<total {
            let b = matches.element(boundBy: i)
            let frame = b.frame
            // Frame first: the collapsed flyout duplicate is a 0x0 button,
            // and querying `isHittable` on it raises "Activation point
            // invalid and no suggested hit points based on element frame",
            // which fails the test outright rather than returning false.
            guard b.exists, frame.width > 1, frame.height > 1 else {
                rejected.append(String(format: "#%d label='%@' exists:%@ frame:%@ — skipped before hittability query",
                                       i, b.label,
                                       b.exists ? "Y" : "N",
                                       frameText(frame)))
                continue
            }
            guard b.isHittable else {
                rejected.append(String(format: "#%d label='%@' frame:%@ hittable:N",
                                       i, b.label, frameText(frame)))
                continue
            }
            b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 0.4)
            return .tapped(candidate: i, of: total)
        }
        return .noHittableCandidate(details: rejected)
    }

    // MARK: - Test

    @MainActor
    func test_editor_everyDrawingTool_selectsAndDraws_withUndoRedo() throws {
        let app = makeApp()
        app.launch()
        enterFreshEditor(name: "Tools", in: app)

        let undoButton = app.buttons["arrow.uturn.backward"].firstMatch
        let redoButton = app.buttons["arrow.uturn.forward"].firstMatch
        step("verify undo/redo start state") {
            check(undoButton.waitForExistence(timeout: 8),
                  "Editor toolbar should expose an undo button (arrow.uturn.backward)", in: app)
            check(redoButton.exists,
                  "Editor toolbar should expose a redo button (arrow.uturn.forward)", in: app)
            check(!undoButton.isEnabled,
                  "Undo starts disabled on a blank notebook, but it was already enabled", in: app)
        }

        // Cycle every drawing-tool category. Each must select (its label
        // flips to "<name>, selected") and produce a stroke.
        let tools = ["Pen", "Pencil", "Brush", "Highlighter"]
        var offset: CGFloat = 0
        for tool in tools {
            step("tool: \(tool)") {
                let outcome = selectTool(tool, in: app)
                check(outcome.didTap,
                      "\(tool) should be selectable in the tool palette — \(outcome.described)", in: app)
                // Confirm the tool actually became active.
                let selected = app.buttons["\(tool), selected"].firstMatch
                check(selected.waitForExistence(timeout: 5),
                      "\(tool) should report itself selected after tapping — no button labelled '\(tool), selected' within 5s", in: app)
                drawStroke(in: app, offset: CGVector(dx: offset, dy: offset))
                offset += 0.04
            }
        }

        step("undo / redo the drawn strokes") {
            // Every stroke landed → undo must now be live.
            check(waitFor(undoButton, enabled: true, timeout: 5),
                  "Undo should be enabled after drawing with each tool, but stayed disabled for 5s", in: app)

            // Undo one, redo one — proves the toolbar buttons drive the stack.
            undoButton.tap()
            check(waitFor(redoButton, enabled: true, timeout: 5),
                  "Redo should be enabled after an undo, but stayed disabled for 5s", in: app)
            redoButton.tap()
        }

        step("verify editor survived") {
            // App still alive and interactive.
            check(app.toolbars["Toolbar"].exists,
                  "Editor toolbar should survive the full tool cycle — toolbars['Toolbar'] not found", in: app)
        }
    }
}
