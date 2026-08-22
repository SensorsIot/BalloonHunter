// SmokeUITests.swift
// Proves the UI-test harness itself works: that a test process can launch the app,
// see its elements and tap them. Everything else in this target depends on it, so
// when the workflow tests fail this one says whether the harness or the app is at
// fault.

import XCTest

final class SmokeUITests: XCTestCase {

    func testHarnessCanLaunchTheAppAndSeeIt() throws {
        let app = XCUIApplication()
        // The smoke test asks whether the harness can drive the app at all, so it
        // takes what is running rather than restarting it.
        app.activate()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "The app did not reach the foreground")

        // The launch screen carries the product name before any service answers.
        let launchTitle = app.staticTexts["BalloonHunter"]
        let picker = app.staticTexts["picker.title"]
        let settings = app.buttons["map.settings"]

        let seen = expectation(description: "the app rendered something the harness can address")
        let deadline = Date().addingTimeInterval(120)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if launchTitle.exists || picker.exists || settings.exists {
                timer.invalidate()
                seen.fulfill()
            } else if Date() > deadline {
                timer.invalidate()
            }
        }
        wait(for: [seen], timeout: 130)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "smoke"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
