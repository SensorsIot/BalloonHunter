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
}
