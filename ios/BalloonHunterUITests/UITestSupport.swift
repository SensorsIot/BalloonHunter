// UITestSupport.swift
// The handful of things every UI test here needs, in one place.
//
// These were written twice - once in each test class - and the second copy did
// not get the fixes the first one earned, so a sheet left standing by one class
// failed the other with a bare "not hittable". One owner.

import XCTest

extension XCTestCase {

    /// Waits without blocking the run loop, which a `sleep` would.
    func settle(_ seconds: TimeInterval = 1.5) {
        let pause = expectation(description: "settle")
        pause.isInverted = true
        wait(for: [pause], timeout: seconds)
    }

    /// Drags a sheet off the screen from its top edge.
    ///
    /// `app.swipeDown()` is the obvious call and the wrong one: these sheets carry
    /// a `Form`, and a swipe starting inside it scrolls the form rather than moving
    /// the sheet.
    func dismissSheet(_ app: XCUIApplication) {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.05, thenDragTo: bottom)
    }

    /// Clears whatever stands between the test and the map.
    ///
    /// A sheet or an alert hides the map without removing it from the hierarchy, so
    /// `exists` stays true and every tap fails as "not hittable" - which reads like
    /// a broken button and is not one. The frequency-sync proposal belongs here
    /// too: it can appear at any moment the receiver connects, which is outside any
    /// test's control.
    @discardableResult
    func clearWhateverIsCoveringTheMap(_ app: XCUIApplication) -> Bool {
        for _ in 0..<4 {
            if app.buttons["map.settings"].isHittable { return true }

            // An app alert: answer it the way that changes nothing. Rejecting the
            // frequency proposal leaves the receiver where the hunter put it.
            if app.alerts.count > 0 {
                let alert = app.alerts.firstMatch
                for label in ["Keep Current Settings", "Cancel", "OK"] where alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    break
                }
                settle(0.5)
                continue
            }

            let done = app.buttons["Done"].firstMatch
            if done.exists && done.isHittable { done.tap(); settle(0.8); continue }

            dismissSheet(app)
            settle(0.8)
        }
        return app.buttons["map.settings"].isHittable
    }

    /// Attaches the element tree and a screenshot, so a failure says what was on
    /// screen instead of leaving it to be reconstructed from a tap that missed.
    func attachScreen(_ app: XCUIApplication, named name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name)-elements"
        tree.lifetime = .keepAlways
        add(tree)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
