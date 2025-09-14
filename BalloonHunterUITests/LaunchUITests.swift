import XCTest

final class BalloonHunterUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        // Smoke check: app launched
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground, "App did not launch")
    }
}

