import XCTest
@testable import BalloonHunter

/// Tests for `SondeHubSondeData.isFlying`, which decides whether startup
/// auto-selects a sonde or falls through to the selection popup.
///
/// The rule is vertical speed, not altitude. Payerne launches from 490 m, so a
/// sonde resting in the surrounding hills sits higher than one still descending
/// over the lake: altitude cannot separate them.
final class SondeFlightStateTests: XCTestCase {

    private func sonde(vel_v: Double?, alt: Double = 1000, type: String = "RS41") -> SondeHubSondeData {
        SondeHubSondeData(serial: "V4210129",
                          type: type,
                          frequency: 404.5,
                          tx_frequency: 404.5,
                          datetime: "2026-08-20T10:00:00.000000Z",
                          lat: 46.90,
                          lon: 7.31,
                          alt: alt,
                          vel_h: 12.0,
                          vel_v: vel_v,
                          temp: -40,
                          humidity: 20,
                          pressure: 300,
                          uploader_position: nil)
    }

    // MARK: - Airborne

    func testAscending_isFlying() {
        XCTAssertEqual(sonde(vel_v: 5.0).isFlying, true)
    }

    func testDescending_isFlying() {
        // Descent is flight. A balloon under parachute is the case the hunter
        // most needs to chase, so a negative rate must not read as landed.
        XCTAssertEqual(sonde(vel_v: -8.0).isFlying, true)
    }

    func testDescendingNearGround_isFlying() {
        // 400 m and still falling: below the old 500 m altitude rule, which
        // would have wrongly called this landed.
        XCTAssertEqual(sonde(vel_v: -6.0, alt: 400).isFlying, true)
    }

    // MARK: - On the ground

    func testStationary_isNotFlying() {
        XCTAssertEqual(sonde(vel_v: 0.0).isFlying, false)
    }

    func testStationaryHighInTheHills_isNotFlying() {
        // 800 m but not moving. The old altitude rule called this flying.
        XCTAssertEqual(sonde(vel_v: 0.1, alt: 800).isFlying, false)
    }

    func testDriftBelowThreshold_isNotFlying() {
        // GPS noise on a grounded sonde must not register as flight.
        XCTAssertEqual(sonde(vel_v: 0.9).isFlying, false)
        XCTAssertEqual(sonde(vel_v: -0.9).isFlying, false)
    }

    func testAtThreshold_isNotFlying() {
        // Boundary: 1.0 m/s exactly fails the strict `>`.
        XCTAssertEqual(sonde(vel_v: 1.0).isFlying, false)
        XCTAssertEqual(sonde(vel_v: -1.0).isFlying, false)
    }

    func testJustAboveThreshold_isFlying() {
        XCTAssertEqual(sonde(vel_v: 1.1).isFlying, true)
    }

    // MARK: - Undetermined

    func testMissingVerticalSpeed_isUndetermined() {
        // iMet sondes report no vertical speed. Undetermined must be nil, never
        // false: the caller falls through to asking the user rather than
        // silently deciding the sonde has landed.
        XCTAssertNil(sonde(vel_v: nil, type: "iMet").isFlying)
    }

    func testUndeterminedIsNotConfusedWithLanded() {
        // Pins the distinction the auto-select filter depends on. If `isFlying`
        // ever collapses to a plain Bool, this fails.
        let undetermined = sonde(vel_v: nil, type: "iMet")
        let landed = sonde(vel_v: 0.0)

        XCTAssertNotEqual(undetermined.isFlying, landed.isFlying)
        XCTAssertFalse(undetermined.isFlying == true, "must not auto-select an undetermined sonde")
        XCTAssertFalse(landed.isFlying == true, "must not auto-select a landed sonde")
    }

    // MARK: - Auto-select filter

    func testAutoSelectPicksFlyingSondeAmongLandedOnes() {
        let sondes = [sonde(vel_v: 0.0), sonde(vel_v: nil), sonde(vel_v: -7.0)]
        XCTAssertEqual(sondes.filter { $0.isFlying == true }.count, 1)
    }

    func testAutoSelectPicksNothingWhenAllGroundedOrUnknown() {
        let sondes = [sonde(vel_v: 0.0), sonde(vel_v: nil), sonde(vel_v: 0.5)]
        XCTAssertNil(sondes.first { $0.isFlying == true })
    }
}
