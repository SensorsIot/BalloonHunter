import XCTest
import CoreLocation
@testable import BalloonHunter

/// Phase 3, from the driver's seat: when is it worth asking me to re-point Maps?
///
/// Every offer costs a cancel and a tap while driving, because an active Apple
/// Maps route cannot be replaced from another app. So the bar is not "the landing
/// point moved" - it moves constantly - but "the drive changed enough to matter".
final class NavigationHandoffTests: XCTestCase {

    private let handoff = NavigationHandoff()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func situation(current: TimeInterval,
                           atLastHandover: TimeInterval? = 40 * 60,
                           lastOfferedMinutesAgo: Double? = 30,
                           distance: CLLocationDistance = 40_000) -> NavigationHandoff.Situation {
        .init(currentTravelTime: current,
              travelTimeAtLastHandover: atLastHandover,
              lastOfferedAt: lastOfferedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
              distanceToLanding: distance)
    }

    // MARK: - Worth interrupting me

    func testTheDriveGotHalfAnHourLonger_askMe() {
        let d = handoff.decide(situation(current: 70 * 60), now: now)
        XCTAssertEqual(d, .offer(travelTimeDelta: 30 * 60))
    }

    func testTheDriveGotMuchShorter_askMeToo() {
        // Shorter matters as much as longer: the balloon may now be coming down
        // on my side of the ridge, and I would take a different road.
        let d = handoff.decide(situation(current: 20 * 60), now: now)
        XCTAssertEqual(d, .offer(travelTimeDelta: -20 * 60))
    }

    func testMapsHasNeverBeenPointedAnywhere_offerImmediately() {
        let d = handoff.decide(situation(current: 40 * 60, atLastHandover: nil), now: now)
        XCTAssertEqual(d, .offerFirstTime)
    }

    // MARK: - Not worth interrupting me

    func testThePredictionDriftedButMyDriveDidNot_sayNothing() {
        // Five minutes on a forty minute drive does not change which roads I take.
        let d = handoff.decide(situation(current: 45 * 60), now: now)
        XCTAssertEqual(d, .stayQuiet)
    }

    func testItAlreadyAskedTwoMinutesAgo_sayNothing() {
        // A prediction wandering across the threshold must not ask every minute.
        let d = handoff.decide(situation(current: 70 * 60, lastOfferedMinutesAgo: 2), now: now)
        XCTAssertEqual(d, .stayQuiet)
    }

    func testAfterTheQuietPeriodItMayAskAgain() {
        let d = handoff.decide(situation(current: 70 * 60, lastOfferedMinutesAgo: 11), now: now)
        XCTAssertEqual(d, .offer(travelTimeDelta: 30 * 60))
    }

    func testIAmAlreadyNearlyThere_sayNothing() {
        // Under 2 km the hunt is on foot. Maps has nothing left to contribute.
        let d = handoff.decide(situation(current: 70 * 60, distance: 800), now: now)
        XCTAssertEqual(d, .stayQuiet)
    }

    func testNoRouteYet_sayNothing() {
        XCTAssertEqual(handoff.decide(situation(current: 0), now: now), .stayQuiet)
        XCTAssertEqual(handoff.decide(situation(current: .infinity), now: now), .stayQuiet)
    }

    // MARK: - The rule that must not creep back

    func testDistanceMovedIsNeverTheTrigger() {
        // The landing point can move kilometres along the same motorway without
        // changing the drive, and 500 m across a ridge can add half an hour.
        // Only travel time decides. Same drive, no offer, whatever moved.
        let unchangedDrive = handoff.decide(situation(current: 40 * 60), now: now)
        XCTAssertEqual(unchangedDrive, .stayQuiet, "an unchanged drive must never prompt")
    }

    func testThresholdBoundary() {
        XCTAssertEqual(handoff.decide(situation(current: 40 * 60 + 599), now: now), .stayQuiet)
        XCTAssertEqual(handoff.decide(situation(current: 40 * 60 + 600), now: now),
                       .offer(travelTimeDelta: 600))
    }

    // MARK: - Tuning

    func testAJumpierHunterCanBeAskedLessOften() {
        let patient = NavigationHandoff(minimumTravelTimeChange: 25 * 60, minimumInterval: 20 * 60)
        XCTAssertEqual(patient.decide(situation(current: 60 * 60), now: now), .stayQuiet,
                       "20 minutes longer is below a 25 minute bar")
        XCTAssertEqual(patient.decide(situation(current: 70 * 60), now: now),
                       .offer(travelTimeDelta: 30 * 60))
    }
}
