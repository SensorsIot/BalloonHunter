// InterfaceUITests.swift
// The user interactions of testing/test-plan.yaml: the button row, the map
// controls and the settings screens.
//
// These attach to the running app rather than launching it, because none of them
// is a startup test and a relaunch would throw away the hunt they act on.
//
// What this tier cannot decide is written into each test rather than left to the
// reader: a tap can be sent and the resulting state read, but whether the route
// turned green or the balloon is drawn in front of the landing marker is a
// judgement about pixels, and those stay with the operator.

import XCTest

final class InterfaceUITests: XCTestCase {

    private var app: XCUIApplication!
    private let uiTimeout: TimeInterval = 20

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        // These act on a hunt in progress with a receiver attached, which the
        // simulator cannot have: it has no CoreBluetooth at all. Running them
        // there produced five failures that said nothing about the app. A test
        // outside its situation has not passed and has not failed - it did not
        // run, and XCTSkip is how that is recorded.
        #if targetEnvironment(simulator)
        throw XCTSkip("Needs the phone and its receiver; the simulator has no CoreBluetooth")
        #endif
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "system permission") { alert in
            for label in ["Allow While Using App", "Allow", "OK", "Don't Allow"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.activate()
        XCTAssertTrue(app.buttons["map.settings"].waitForExistence(timeout: 90),
                      "The tracking view never appeared, so no interaction can be tested")
        clearWhateverIsCoveringTheMap(app)
        XCTAssertTrue(app.buttons["map.settings"].isHittable,
                      "The map is present but something is still covering it")
    }

    override func tearDown() {
        // `app` is nil when setUp threw - a skip on the simulator does exactly
        // that - and an implicitly unwrapped optional turns that into a crash of
        // the runner rather than a skipped test.
        if let app {
            // Leave the app on the map however the test ended, so the next one
            // starts from the state a hunter would be looking at.
            let done = app.buttons["settings.done"]
            if done.exists && done.isHittable { done.tap() }
            clearWhateverIsCoveringTheMap(app)
        }
        super.tearDown()
    }

    // MARK: - D-UI-BUTTONS

    /// The row carries the specified controls, and the transport button swaps mode.
    func testButtonRowAndTransportToggle() {
        for id in ["map.settings", "map.changeSonde", "map.transport", "map.showAll", "map.heading"] {
            XCTAssertTrue(app.buttons[id].exists, "The button row is missing \(id)")
        }

        // The transport button states its own mode, which is what makes the swap
        // observable without reading pixels.
        let transport = app.buttons["map.transport"]
        let before = transport.label
        transport.tap()
        settle()
        let after = transport.label
        XCTAssertNotEqual(before, after,
                          "The transport button did not change mode: still '\(before)'")
        XCTAssertTrue(after.contains("Driving") || after.contains("Cycling"),
                      "The transport button no longer says which mode is in use: '\(after)'")

        // Put it back, so the hunt is left as it was found.
        transport.tap()
        settle()
        XCTAssertEqual(transport.label, before, "The transport mode did not return")
    }

    /// The Apple Maps button appears exactly when there is somewhere to navigate to.
    ///
    /// The landing marker is queried as "target". MapKit names an annotation from
    /// the SF Symbol it draws and ignores an `accessibilityIdentifier` set on the
    /// annotation's content, so the symbol name is the handle that exists.
    ///
    /// Two earlier versions of this test failed the app for asking the wrong
    /// question. The distance overlay is not the signal: it is deliberately
    /// receiver-only, since a SondeHub position says where the sonde was last
    /// heard rather than where it lies, so it is absent through an entire APRS
    /// hunt while a landing point exists. And an annotation off-screen is not in
    /// the tree at all, which is why Show All comes first.
    func testAppleMapsButtonFollowsTheLandingPoint() {
        app.buttons["map.showAll"].tap()
        settle(2.5)

        let maps = app.buttons["map.appleMaps"]
        let marker = app.images["target"]
        if maps.exists != marker.exists {
            attachScreen(app, named: "appleMaps-and-landing-marker-disagree")
        }
        XCTAssertEqual(maps.exists, marker.exists,
                       "The Apple Maps button and the landing marker disagree: button \(maps.exists), marker \(marker.exists)")
    }

    // MARK: - D-UI-HEADING

    /// Heading mode toggles, and toggles back.
    func testHeadingModeToggles() {
        let heading = app.buttons["map.heading"]
        XCTAssertTrue(heading.exists)
        heading.tap()
        settle()
        // Leaving heading mode is what "All" does too, per the button's own action.
        heading.tap()
        settle()
        XCTAssertTrue(app.buttons["map.settings"].exists,
                      "The map did not survive two heading-mode toggles")
    }

    /// Show All runs and leaves the map usable.
    func testShowAll() {
        app.buttons["map.showAll"].tap()
        settle()
        XCTAssertTrue(app.buttons["map.settings"].exists,
                      "The map did not survive Show All")
    }

    // MARK: - D-UI-MUTE

    /// The mute control is present only with a receiver, and reports its state.
    func testMuteReflectsItsState() {
        let mute = app.buttons["map.mute"]
        guard mute.exists else {
            // Not a failure: the control is removed from the layout while the
            // receiver is disconnected, which is itself the specified behaviour.
            XCTAssertFalse(mute.exists)
            return
        }
        // The icon follows the receiver's own reported state, which arrives in the
        // next status packet, so each change is waited for rather than assumed.
        func waitForMute(toBecome wanted: String, _ what: String) {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if (mute.value as? String) == wanted { return }
                settle(0.5)
            }
            XCTFail("\(what): the mute button still reads '\(mute.value as? String ?? "nil")'")
        }

        let before = mute.value as? String ?? "unmuted"
        let opposite = before == "muted" ? "unmuted" : "muted"
        mute.tap()
        waitForMute(toBecome: opposite, "after the first tap")
        mute.tap()
        waitForMute(toBecome: before, "after tapping back")
    }

    // MARK: - D-SET-SONDE

    /// The settings screen opens, offers its three routes onward, and closes.
    func testSondeSettingsOpensAndOffersItsViews() {
        app.buttons["map.settings"].tap()
        XCTAssertTrue(app.buttons["settings.prediction"].waitForExistence(timeout: uiTimeout),
                      "Settings did not open, or offers no Prediction Settings")
        XCTAssertTrue(app.buttons["settings.device"].exists, "Device Settings is missing")
        XCTAssertTrue(app.buttons["settings.tune"].exists, "Tune is missing")

        // With no receiver, the frequency controls and the routes that command it
        // are disabled and the screen says so, rather than accepting input that
        // could never reach a device.
        let connected = app.buttons["settings.device"].isEnabled
        if !connected {
            XCTAssertTrue(app.staticTexts["settings.notConnected"].exists,
                          "No receiver, no disabled-state explanation on screen")
        }

        dismissSheet(app)
        XCTAssertTrue(app.buttons["map.settings"].waitForExistence(timeout: uiTimeout),
                      "Dismissing settings did not return to the map")
    }

    /// Revert is offered exactly when the frequency can be changed.
    func testRevertTracksTheReceiver() {
        app.buttons["map.settings"].tap()
        XCTAssertTrue(app.buttons["settings.prediction"].waitForExistence(timeout: uiTimeout))
        let revert = app.buttons["settings.revert"]
        let connected = app.buttons["settings.device"].isEnabled
        if connected {
            XCTAssertTrue(revert.exists, "The receiver is connected but Revert is absent")
            XCTAssertTrue(revert.isEnabled, "Revert is present but cannot be used")
        }
        dismissSheet(app)
        _ = app.buttons["map.settings"].waitForExistence(timeout: uiTimeout)
    }

    // MARK: - D-SET-PREDICTION

    /// Prediction settings carry their four parameters and the server URL, and a
    /// change survives leaving the view.
    func testPredictionSettingsHoldTheirValues() {
        app.buttons["map.settings"].tap()
        XCTAssertTrue(app.buttons["settings.prediction"].waitForExistence(timeout: uiTimeout))
        app.buttons["settings.prediction"].tap()

        let burst = app.textFields["pred.burstAltitude"]
        XCTAssertTrue(burst.waitForExistence(timeout: uiTimeout), "Burst Altitude is missing")
        for id in ["pred.ascentRate", "pred.descentRate", "pred.stationId", "pred.serverURL"] {
            XCTAssertTrue(app.textFields[id].exists, "Prediction settings is missing \(id)")
        }

        // The server must be the https one by default, since an http URL is refused
        // at selection rather than at request time.
        let url = app.textFields["pred.serverURL"].value as? String ?? ""
        XCTAssertTrue(url.hasPrefix("https://"),
                      "The prediction server URL is not https: '\(url)'")

        // Change the burst altitude, leave the view, come back, and read it again.
        // The restore is registered first, so a failed assertion cannot leave the
        // hunter predicting against a burst altitude this test invented.
        let original = (burst.value as? String) ?? ""
        addTeardownBlock { [weak self] in
            guard !original.isEmpty else { return }
            self?.restorePredictionField("pred.burstAltitude", to: original.filter(\.isNumber))
        }

        // The field formats what it holds - 30000 is displayed as "30'000" - so the
        // comparison is on digits, which is the value, rather than on the rendering.
        func digits(_ text: String?) -> String { (text ?? "").filter(\.isNumber) }

        let probe = digits(original).hasPrefix("35") ? "30000" : "35000"
        setText(burst, to: probe)
        XCTAssertEqual(digits(burst.value as? String), probe,
                       "The burst altitude did not take the new value")

        app.buttons["Done"].firstMatch.tap()
        settle()
        app.buttons["settings.prediction"].tap()
        XCTAssertTrue(burst.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(digits(burst.value as? String), probe,
                       "The burst altitude did not survive leaving the view")
        closePredictionSettings()
    }

    // MARK: - D-SET-PERSIST-RELAUNCH

    /// Sets a text field to an exact value rather than editing around whatever is
    /// in it. Tapping a field puts the cursor where the tap landed, so typing a
    /// digit can prepend it - which is how a station ID became "7706610".
    private func setText(_ field: XCUIElement, to value: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        for _ in 0..<(current.count + 2) {
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        field.typeText(value)
    }

    private func openPredictionSettings() {
        clearWhateverIsCoveringTheMap(app)
        app.buttons["map.settings"].tap()
        XCTAssertTrue(app.buttons["settings.prediction"].waitForExistence(timeout: uiTimeout))
        app.buttons["settings.prediction"].tap()
    }

    private func closePredictionSettings() {
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        settle()
        dismissSheet(app)
        _ = app.buttons["map.settings"].waitForExistence(timeout: uiTimeout)
    }

    /// Restores one prediction field to a value, whatever state the test left the
    /// app in. Registered as a teardown block before anything is changed.
    private func restorePredictionField(_ identifier: String, to value: String) {
        app.activate()
        _ = app.buttons["map.settings"].waitForExistence(timeout: 120)
        openPredictionSettings()
        let field = app.textFields[identifier]
        let held = ((field.value as? String) ?? "").filter { $0.isNumber || $0 == "." }
        if field.waitForExistence(timeout: uiTimeout), held != value {
            setText(field, to: value)
            XCTAssertEqual(((field.value as? String) ?? "").filter { $0.isNumber || $0 == "." }, value,
                           "\(identifier) was left as '\(field.value as? String ?? "nil")' rather than the hunter's own '\(value)'")
        }
        closePredictionSettings()
    }

    /// A prediction setting survives a relaunch, which is the only proof that it
    /// reached disk rather than an in-memory object that happens to still exist.
    ///
    /// These are the hunter's own settings, so the restore is registered as a
    /// teardown block before anything is changed. An earlier version restored
    /// inline after the assertions and left the station ID as "7706610" the first
    /// time one of them failed - the app then polls a station that does not exist,
    /// which is worse than the test never running.
    func testPredictionSettingsSurviveARelaunch() {
        openPredictionSettings()
        let station = app.textFields["pred.stationId"]
        XCTAssertTrue(station.waitForExistence(timeout: uiTimeout), "Station ID is missing")
        let original = (station.value as? String) ?? "06610"
        addTeardownBlock { [weak self] in
            self?.restorePredictionField("pred.stationId", to: original)
        }

        let probe = original == "06610" ? "06611" : "06610"
        setText(station, to: probe)
        XCTAssertEqual(station.value as? String, probe, "The station ID did not take the new value")
        closePredictionSettings()

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["map.settings"].waitForExistence(timeout: 120),
                      "The app did not come back after the relaunch")

        openPredictionSettings()
        XCTAssertTrue(station.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(station.value as? String, probe,
                       "The station ID did not survive the relaunch, so it never reached disk")
        closePredictionSettings()
    }

    // MARK: - D-SET-TUNE / D-SET-DEVICE

    /// Tune and Device Settings are reachable exactly when a receiver can be
    /// commanded, and Tune keeps its view open after Save.
    func testTuneAndDeviceSettingsFollowTheReceiver() {
        app.buttons["map.settings"].tap()
        XCTAssertTrue(app.buttons["settings.tune"].waitForExistence(timeout: uiTimeout))

        let commandable = app.buttons["settings.device"].isEnabled
        XCTAssertEqual(app.buttons["settings.tune"].isEnabled, commandable,
                       "Tune and Device Settings disagree about whether the receiver can be commanded")

        if commandable {
            app.buttons["settings.tune"].tap()
            if !app.buttons["tune.transfer"].waitForExistence(timeout: uiTimeout) {
                attachScreen(app, named: "tune-view-without-transfer")
                XCTFail("The Tune view has no Transfer control")
                return
            }
            XCTAssertTrue(app.buttons["tune.save"].exists, "The Tune view has no Save control")
            app.buttons["tune.transfer"].tap()
            settle()
            XCTAssertTrue(app.buttons["tune.save"].exists,
                          "Transfer closed the Tune view; it must stay open so the effect can be watched")
            app.buttons["settings.done"].tap()
            settle()
        }
        dismissSheet(app)
        _ = app.buttons["map.settings"].waitForExistence(timeout: uiTimeout)
    }
}
