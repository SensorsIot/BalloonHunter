import XCTest
import CoreLocation
@testable import BalloonHunter

/// Phase 4, from the hunter's chair: out of the car, walking a field.
final class CloseRangeGuidanceTests: XCTestCase {

    private let guidance = CloseRangeGuidance()

    /// A field near Payerne.
    private let sondeSpot = CLLocationCoordinate2D(latitude: 46.8130, longitude: 6.9440)
    /// Roughly 150 m south of it.
    private let meNearby  = CLLocationCoordinate2D(latitude: 46.8117, longitude: 6.9440)

    private func fromReceiver(_ c: CLLocationCoordinate2D) -> CloseRangeGuidance.SondePosition {
        .init(coordinate: c, source: .receiver)
    }
    private func fromNetwork(_ c: CLLocationCoordinate2D) -> CloseRangeGuidance.SondePosition {
        .init(coordinate: c, source: .network)
    }

    // MARK: - How far, and which way

    func testTheReceiverTellsMeHowFarAwayItIs() throws {
        let d = try XCTUnwrap(guidance.distanceToSonde(sonde: fromReceiver(sondeSpot), hunter: meNearby))
        XCTAssertEqual(d, 145, accuracy: 15)
    }

    func testItIsDueNorthOfMe() throws {
        let bearing = try XCTUnwrap(guidance.bearingToSonde(sonde: fromReceiver(sondeSpot), hunter: meNearby))
        XCTAssertEqual(bearing, 0, accuracy: 2, "0 degrees means turn until the marker is at the top")
    }

    func testWalkingTowardsItMakesTheNumberFall() throws {
        let far = try XCTUnwrap(guidance.distanceToSonde(sonde: fromReceiver(sondeSpot), hunter: meNearby))
        let closer = CLLocationCoordinate2D(latitude: 46.8126, longitude: 6.9440)
        let near = try XCTUnwrap(guidance.distanceToSonde(sonde: fromReceiver(sondeSpot), hunter: closer))
        XCTAssertLessThan(near, far)
    }

    func testStandingOnTopOfIt() throws {
        let d = try XCTUnwrap(guidance.distanceToSonde(sonde: fromReceiver(sondeSpot), hunter: sondeSpot))
        XCTAssertEqual(d, 0, accuracy: 0.5)
    }

    // MARK: - SondeHub must not send me anywhere

    func testSondeHubPositionIsNotUsedToGuideMe() {
        // Its last frame is where the sonde stopped being heard, not where it
        // lies. On W4214915 that frame was at 1173 m, still falling.
        XCTAssertNil(guidance.distanceToSonde(sonde: fromNetwork(sondeSpot), hunter: meNearby))
        XCTAssertNil(guidance.bearingToSonde(sonde: fromNetwork(sondeSpot), hunter: meNearby))
    }

    func testANetworkPositionDoesNotPutAnythingOnScreen() {
        XCTAssertFalse(guidance.shouldShowDistance(sonde: fromNetwork(sondeSpot), hunter: meNearby))
    }

    func testTheSameCoordinateIsTrustedFromTheReceiverAndNotFromTheNetwork() {
        // Identical numbers, different provenance, opposite treatment.
        XCTAssertTrue(guidance.shouldShowDistance(sonde: fromReceiver(sondeSpot), hunter: meNearby))
        XCTAssertFalse(guidance.shouldShowDistance(sonde: fromNetwork(sondeSpot), hunter: meNearby))
    }

    // MARK: - Losing the signal while I walk

    func testTheDistanceSurvivesLosingTheRadioForAMoment() {
        // Trees, or my own body over the antenna. The number is a calculation
        // between two GPS fixes; the radio being momentarily down changes neither.
        let lastKnown = fromReceiver(sondeSpot)
        XCTAssertTrue(guidance.shouldShowDistance(sonde: lastKnown, hunter: meNearby),
                      "the metres must not vanish when I am closest and most likely to drop signal")
    }

    func testNothingIsShownWhenThereIsNothingToMeasure() {
        XCTAssertFalse(guidance.shouldShowDistance(sonde: nil, hunter: meNearby))
        XCTAssertFalse(guidance.shouldShowDistance(sonde: fromReceiver(sondeSpot), hunter: nil))
    }

    // MARK: - Which way to turn

    func testBearingsRoundTheCompass() throws {
        let centre = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.0)
        let cases: [(name: String, coord: CLLocationCoordinate2D, expected: Double)] = [
            ("north", .init(latitude: 47.01, longitude: 7.0), 0),
            ("east",  .init(latitude: 47.0, longitude: 7.015), 90),
            ("south", .init(latitude: 46.99, longitude: 7.0), 180),
            ("west",  .init(latitude: 47.0, longitude: 6.985), 270)
        ]
        for c in cases {
            let b = try XCTUnwrap(guidance.bearingToSonde(sonde: fromReceiver(c.coord), hunter: centre))
            XCTAssertEqual(b, c.expected, accuracy: 2, "\(c.name) came out at \(b)")
        }
    }

    func testBearingIsAlwaysACompassReading() throws {
        // Never negative, never past 360 - it goes straight onto a rotated map.
        let centre = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.0)
        for dLat in [-0.02, 0.0, 0.02] {
            for dLon in [-0.02, 0.0, 0.02] where !(dLat == 0 && dLon == 0) {
                let target = CLLocationCoordinate2D(latitude: 47.0 + dLat, longitude: 7.0 + dLon)
                let b = try XCTUnwrap(guidance.bearingToSonde(sonde: fromReceiver(target), hunter: centre))
                XCTAssertTrue((0..<360).contains(b), "bearing \(b) is not a compass reading")
            }
        }
    }

    // MARK: - A route to where you already stand

    /// Within close range the route is not displayed, so calculating one is work
    /// nobody sees — and worse, it feeds the off-route monitor. Apple Maps snaps a
    /// two-metre separation to the nearest road, producing a 13 m route the hunter
    /// is then "280 m off", which triggers another recalculation, forever.
    /// See FSD *Route Calculation Service*.

    func testRoute_notCalculatedToSomewhereYouAlreadyStand() {
        XCTAssertFalse(RoutePolicy.shouldCalculateRoute(userToDestinationMetres: 2),
                       "standing on the destination: there is nothing to navigate")
        XCTAssertFalse(RoutePolicy.shouldCalculateRoute(userToDestinationMetres: 199))
    }

    func testRoute_calculatedOnceTheDestinationIsWorthDrivingTo() {
        XCTAssertTrue(RoutePolicy.shouldCalculateRoute(userToDestinationMetres: 200))
        XCTAssertTrue(RoutePolicy.shouldCalculateRoute(userToDestinationMetres: 34_308))
    }

    /// The radius has one owner. The map hides the route and the router declines to
    /// build it on the same number, so they can never disagree.
    func testRoute_sharesItsRadiusWithTheCloseRangeHandover() {
        XCTAssertEqual(RoutePolicy.closeRangeMetres, 200,
                       "the same radius that hides the route and starts foot guidance")
    }

    // MARK: - When a route is renewed
    //
    // A route is renewed when the landing point moves, or when the hunter has moved
    // significantly. Only the second is throttled: the landing point moves only when
    // a prediction produces a new one, and predictions are paced by their own timer,
    // whereas the hunter's position changes continuously.
    // See FSD *Route Calculation Service → When a route is renewed*.

    private func renew(landingMoved: Bool = false,
                       moved: CLLocationDistance = 0,
                       since: TimeInterval = 3600,
                       hasRoute: Bool = true,
                       modeChanged: Bool = false) -> Bool {
        RouteRenewalPolicy.shouldRenew(hasExistingRoute: hasRoute,
                                       transportModeChanged: modeChanged,
                                       landingPointMoved: landingMoved,
                                       hunterMovedMetres: moved,
                                       sinceLastHunterRenewal: since)
    }

    /// The case that produced eight Apple Maps calls in six minutes: the sonde is
    /// down, its landing point cannot move, and the hunter is sitting still.
    func testRenew_landedAndStationaryNeverRenews() {
        XCTAssertFalse(renew(), "nothing a route depends on has changed")
        XCTAssertFalse(renew(moved: 99), "shuffling about is not going somewhere else")
    }

    /// Not throttled. A new landing point only exists because a prediction produced
    /// one, and those are already paced. Throttling here would delay a confirmed
    /// touchdown — the moment the destination becomes the real place — by a minute.
    func testRenew_landingPointMoveIsNeverThrottled() {
        XCTAssertTrue(renew(landingMoved: true, since: 0),
                      "a moved landing point is acted on at once, whenever it arrives")
        XCTAssertTrue(renew(landingMoved: true, since: 1))
    }

    /// Throttled. The hunter's position changes continuously, so this is the one
    /// trigger that needs a floor under it.
    func testRenew_hunterMovementIsThrottled() {
        XCTAssertTrue(renew(moved: 100, since: 60))
        XCTAssertFalse(renew(moved: 100, since: 59), "a renewal a moment ago is enough for now")
        XCTAssertFalse(renew(moved: 99, since: 3600), "moving less than the threshold is not moving")
    }

    /// A first route and an explicit change of transport are not throttled: there is
    /// nothing to show, or the hunter has just asked for something different.
    func testRenew_firstRouteAndModeChangeAreImmediate() {
        XCTAssertTrue(renew(since: 0, hasRoute: false))
        XCTAssertTrue(renew(since: 0, modeChanged: true))
    }

    func testRenew_thresholdsAreTheAgreedOnes() {
        XCTAssertEqual(RouteRenewalPolicy.significantHunterMovementMetres, 100)
        XCTAssertEqual(RouteRenewalPolicy.minimumInterval, 60)
    }
}
