import XCTest
@testable import BalloonHunter

/// Phase 2, from the hunter's chair: still at home, deciding when to set off.
final class DepartureTimeTests: XCTestCase {

    private let departure = DepartureTime()
    /// 14:00 on the day of a flight.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutesFromNow: Double) -> Date {
        now.addingTimeInterval(minutesFromNow * 60)
    }

    // MARK: - When do I leave?

    func testLandingInAnHour_driveIsTwentyMinutes_leaveInForty() {
        let plan = departure.plan(landingTime: at(60), drivingTime: 20 * 60, now: now)
        XCTAssertEqual(try XCTUnwrap(plan).timeUntilDeparture / 60, 40, accuracy: 0.01)
    }

    func testTheClockTimeToLeaveIsLandingMinusDrive() throws {
        let plan = try XCTUnwrap(departure.plan(landingTime: at(90), drivingTime: 30 * 60, now: now))
        XCTAssertEqual(plan.leaveAt, at(60))
    }

    func testNoMarginIsAdded() throws {
        // I judge my own slack. The app does not pad the number for me.
        let plan = try XCTUnwrap(departure.plan(landingTime: at(50), drivingTime: 50 * 60, now: now))
        XCTAssertEqual(plan.timeUntilDeparture, 0, accuracy: 0.01, "leave exactly now, not five minutes ago")
    }

    // MARK: - The balloon moves, so does the answer

    func testTheBalloonSlowsDown_soIGetMoreTime() throws {
        // A slow parachute pushes the landing later. I can leave later too.
        let early = try XCTUnwrap(departure.plan(landingTime: at(60), drivingTime: 30 * 60, now: now))
        let later = try XCTUnwrap(departure.plan(landingTime: at(85), drivingTime: 30 * 60, now: now))
        XCTAssertGreaterThan(later.timeUntilDeparture, early.timeUntilDeparture)
        XCTAssertEqual((later.timeUntilDeparture - early.timeUntilDeparture) / 60, 25, accuracy: 0.01)
    }

    func testTheLandingMovesFurtherAway_soIMustLeaveSooner() throws {
        // Same landing time, longer drive: the deadline comes at me.
        let near = try XCTUnwrap(departure.plan(landingTime: at(60), drivingTime: 20 * 60, now: now))
        let far  = try XCTUnwrap(departure.plan(landingTime: at(60), drivingTime: 45 * 60, now: now))
        XCTAssertLessThan(far.timeUntilDeparture, near.timeUntilDeparture)
    }

    // MARK: - I cannot make it

    func testLandingInFortyMinutes_driveIsSeventy_thirtyMinutesTooLate() throws {
        let plan = try XCTUnwrap(departure.plan(landingTime: at(40), drivingTime: 70 * 60, now: now))
        XCTAssertTrue(plan.isTooLate)
        XCTAssertEqual(plan.timeUntilDeparture / 60, -30, accuracy: 0.01)
    }

    func testTooLateIsShownAsANegativeNumberAndNothingElse() throws {
        // No warning, no suggestion, no switching targets. I read minus thirty
        // and decide for myself.
        let plan = try XCTUnwrap(departure.plan(landingTime: at(10), drivingTime: 60 * 60, now: now))
        XCTAssertEqual(plan.timeUntilDeparture / 60, -50, accuracy: 0.01)
    }

    func testIShouldHaveLeftAlready_butOnlyJust() throws {
        let plan = try XCTUnwrap(departure.plan(landingTime: at(30), drivingTime: 31 * 60, now: now))
        XCTAssertTrue(plan.isTooLate)
        XCTAssertEqual(plan.timeUntilDeparture / 60, -1, accuracy: 0.01)
    }

    // MARK: - Nothing to go on

    func testNoPredictionYet_noDepartureTime() {
        XCTAssertNil(departure.plan(landingTime: nil, drivingTime: 30 * 60, now: now))
    }

    func testNoRouteYet_noDepartureTime() {
        // Before a route exists there is no honest answer, so give none.
        XCTAssertNil(departure.plan(landingTime: at(60), drivingTime: nil, now: now))
    }

    func testNonsenseDrivingTimeIsRefused() {
        XCTAssertNil(departure.plan(landingTime: at(60), drivingTime: -100, now: now))
        XCTAssertNil(departure.plan(landingTime: at(60), drivingTime: .infinity, now: now))
    }

    // MARK: - Not the same as Arrival

    func testDepartureIsNotArrival() throws {
        // Arrival answers "when would I get there if I left now" - a different
        // question, and the one the panel already answers.
        let landing = at(90), drive: TimeInterval = 30 * 60
        let plan = try XCTUnwrap(departure.plan(landingTime: landing, drivingTime: drive, now: now))
        let arrivalIfILeftNow = now.addingTimeInterval(drive)

        XCTAssertEqual(plan.leaveAt, at(60))
        XCTAssertEqual(arrivalIfILeftNow, at(30))
        XCTAssertNotEqual(plan.leaveAt, arrivalIfILeftNow)
    }
}
