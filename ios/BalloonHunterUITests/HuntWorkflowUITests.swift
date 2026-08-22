// HuntWorkflowUITests.swift
// Simulator tier of the workflows declared in testing/test-plan.yaml.
//
// What this tier can prove: the order the app does things in, and that nothing
// sonde-specific is on screen before a sonde is selected. What it cannot prove:
// anything that needs telemetry - a track, a landing point, a route. Those steps
// stay on the device and field tiers of the same workflows.

import XCTest

final class HuntWorkflowUITests: XCTestCase {

    // Startup runs a BLE scan and a SondeHub query before the picker can appear.
    private let pickerTimeout: TimeInterval = 120
    // A context load fetches a flight from SondeHub.
    private let contextTimeout: TimeInterval = 90

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Rig

    @discardableResult
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Permission dialogs would otherwise stall the run on a fresh simulator.
        addUIInterruptionMonitor(withDescription: "system permission") { alert in
            for label in ["Allow While Using App", "Allow", "OK"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        return app
    }

    /// Startup has two legitimate endings: the picker, or an automatic selection
    /// when a sonde is demonstrably airborne. Waits for whichever arrives.
    private enum StartupEnding { case picker, autoSelected }

    private func waitForStartupToSettle(_ app: XCUIApplication,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) -> StartupEnding {
        let picker = app.staticTexts["picker.title"]
        let map = app.buttons["map.settings"]
        let deadline = Date().addingTimeInterval(pickerTimeout)
        while Date() < deadline {
            if picker.exists { return .picker }
            if map.exists { return .autoSelected }
            _ = picker.waitForExistence(timeout: 2)
        }
        XCTFail("Startup ended in neither the picker nor the tracking view",
                file: file, line: line)
        return .picker
    }

    /// Selects whatever the picker offers, preferring a real SondeHub row and
    /// falling back to manual entry so the test does not depend on a sonde being
    /// in the air today. Returns the serial it selected, when it knows it.
    @discardableResult
    private func selectSonde(in app: XCUIApplication,
                             avoiding excluded: String? = nil,
                             file: StaticString = #filePath,
                             line: UInt = #line) -> String? {
        let title = app.staticTexts["picker.title"]
        XCTAssertTrue(title.waitForExistence(timeout: pickerTimeout),
                      "The sonde picker never appeared", file: file, line: line)

        var chosen: String?
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "picker.row."))
        for index in 0..<rows.count {
            let row = rows.element(boundBy: index)
            guard row.exists else { continue }
            let serial = String(row.identifier.dropFirst("picker.row.".count))
            if serial == excluded { continue }
            row.tap()
            chosen = serial
            break
        }

        if chosen == nil {
            // No usable row. Manual entry keeps the workflow runnable off-season.
            let field = app.textFields["picker.manualSerial"]
            XCTAssertTrue(field.waitForExistence(timeout: 5),
                          "Neither a sonde row nor the manual field was available",
                          file: file, line: line)
            let serial = excluded == "V0000001" ? "V0000002" : "V0000001"
            field.tap()
            field.typeText(serial)
            chosen = serial
        }

        let confirm = app.buttons["picker.confirm"]
        XCTAssertTrue(confirm.isEnabled, "Confirm stayed disabled after a selection",
                      file: file, line: line)
        confirm.tap()

        XCTAssertTrue(title.waitForNonExistence(timeout: contextTimeout),
                      "The picker did not dismiss after confirming", file: file, line: line)
        return chosen
    }

    private func waitForTrackingView(_ app: XCUIApplication,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        let settings = app.buttons["map.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: contextTimeout),
                      "The tracking view never appeared after selection", file: file, line: line)
    }

    // MARK: - W-STARTUP

    /// A sonde is settled on before anything sonde-specific is shown - through the
    /// picker, or automatically when one is demonstrably airborne.
    func testStartupSettlesOnASondeBeforeShowingAnySondeData() {
        let app = launch()

        switch waitForStartupToSettle(app) {
        case .picker:
            // must_not: the picker appearing with an empty list.
            XCTAssertFalse(app.staticTexts["picker.empty"].exists,
                           "The picker offered no sondes and no way to proceed")

            // must_not: sonde data on screen before a sonde is chosen.
            let panelSerial = app.staticTexts["panel.serial"]
            if panelSerial.exists {
                XCTAssertEqual(panelSerial.label, "N/A",
                               "A serial was displayed before any sonde was selected")
            }

            selectSonde(in: app)
            waitForTrackingView(app)

        case .autoSelected:
            // The airborne branch. The picker must not then arrive on top of it.
            XCTAssertFalse(app.staticTexts["picker.title"].waitForExistence(timeout: 10),
                           "A sonde was auto-selected and the picker appeared anyway")
        }
    }

    // MARK: - W-BACKGROUND

    /// Going away and coming back is not a new hunt: no second picker, no reset.
    func testReturningFromBackgroundKeepsTheHunt() {
        let app = launch()
        if waitForStartupToSettle(app) == .picker { selectSonde(in: app) }
        waitForTrackingView(app)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 15),
                      "The app did not go to the background")

        // The workflow's claim is a delta fetch sized from the last one, and a
        // half-second away proves nothing: the launch fetch is still in flight and
        // the resume simply joins it. The dwell is therefore part of the test, set
        // by TEST_RUNNER_BACKGROUND_SECONDS - long on the phone, short in the gate.
        let dwell = TimeInterval(ProcessInfo.processInfo.environment["BACKGROUND_SECONDS"] ?? "") ?? 5
        if dwell > 0 {
            let away = expectation(description: "away from the app for \(Int(dwell))s")
            away.isInverted = true
            wait(for: [away], timeout: dwell)
        }

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15),
                      "The app did not come back to the foreground")

        waitForTrackingView(app)
        // must_not: the picker returning, which would mean the hunt was lost.
        XCTAssertFalse(app.staticTexts["picker.title"].waitForExistence(timeout: 10),
                       "The picker reappeared on resume - the hunt was not kept")
    }

    // MARK: - W-SONDE-CHANGE

    /// Changing sonde reopens the picker and hands the app a different hunt.
    func testChangingSondeGoesBackThroughThePicker() {
        let app = launch()
        let selected = waitForStartupToSettle(app) == .picker ? selectSonde(in: app) : nil
        waitForTrackingView(app)

        // The panel is the app's own statement of what it is hunting, so it beats
        // whatever the picker handed back - and covers the auto-selected branch,
        // where the test never chose anything.
        let panel = app.staticTexts["panel.serial"]
        let shown = panel.exists ? panel.label : "N/A"
        let first = shown == "N/A" ? selected : shown

        app.buttons["map.changeSonde"].tap()

        let second = selectSonde(in: app, avoiding: first)
        waitForTrackingView(app)

        if let first, let second {
            XCTAssertNotEqual(first, second,
                              "The change-sonde flow returned the same serial, so nothing was changed")
        }
    }
}
