import XCTest
@testable import BalloonHunter

/// Replays two real Payerne flights through the rules that decide what the
/// hunter is told.
///
/// Synthetic tracks only prove the arithmetic. These prove the rules survive a
/// real balloon: a 30 km climb, a burst, and a fall through air that changes
/// density by two orders of magnitude.
///
/// | flight | why it is here |
/// |---|---|
/// | `W4214915` | 31 Jul 2026. A slow parachute, ~2.3 m/s near the ground against an assumed 5.0. Landed roughly 50 km from its first prediction. |
/// | `W4140855` | 31 Jan 2026. A normal descent, included as the control — without it, "we detected the slow one" means nothing. |
///
/// Fixtures are the real SondeHub telemetry at one sample per 30 s.
final class RealFlightTests: XCTestCase {

    private struct Sample: Decodable {
        let t: Double      // seconds since first frame
        let lat: Double
        let lon: Double
        let alt: Double
    }

    private func flight(_ name: String) throws -> [BalloonTrackPoint] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "fixture \(name).json is missing from the test bundle")
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        return samples.map {
            BalloonTrackPoint(latitude: $0.lat, longitude: $0.lon, altitude: $0.alt,
                              timestamp: epoch.addingTimeInterval($0.t),
                              verticalSpeed: 0, horizontalSpeed: 0)
        }
    }

    private func burstIndex(_ track: [BalloonTrackPoint]) -> Int {
        track.indices.max(by: { track[$0].altitude < track[$1].altitude }) ?? 0
    }

    // MARK: - The app must not send me out mid-flight

    func testSlowFlight_neverReportsLandedWhileStillFlying() throws {
        // The worst false positive there is: the app says "landed", locks a
        // target, and I drive to a field while the balloon is still at altitude.
        let track = try flight("W4214915")
        let detector = LandingDetector()

        for end in stride(from: 20, to: track.count, by: 5) {
            let sofar = Array(track[0..<end])
            guard sofar.last!.altitude > 3_000 else { continue }
            XCTAssertFalse(detector.isStoppedByVectorAnalysis(track: sofar),
                           "called landed at \(Int(sofar.last!.altitude)) m")
        }
    }

    func testNormalFlight_neverReportsLandedWhileStillFlying() throws {
        let track = try flight("W4140855")
        let detector = LandingDetector()

        for end in stride(from: 20, to: track.count, by: 5) {
            let sofar = Array(track[0..<end])
            guard sofar.last!.altitude > 3_000 else { continue }
            XCTAssertFalse(detector.isStoppedByVectorAnalysis(track: sofar),
                           "called landed at \(Int(sofar.last!.altitude)) m")
        }
    }

    func testNeitherFlightScansAsLandedWhileTheSondeIsStillFalling() throws {
        // Both fixtures stop while the sonde is still in the air, because that is
        // where SondeHub lost it. Neither may therefore report a landing.
        for name in ["W4214915", "W4140855"] {
            let track = try flight(name)
            XCTAssertGreaterThan(track.last!.altitude, 400, "\(name) fixture assumption")
            XCTAssertNil(LandingDetector().scanTrackForLanding(track),
                         "\(name) reported a landing it never made")
        }
    }

    // MARK: - Telling a slow parachute from a normal one

    /// Compare only below 10 km.
    ///
    /// Above that, `rate x time` is not what Tawhiri predicts: it models air
    /// density, and a sonde falls several times faster at 30 km than at ground
    /// level. Measured from burst, this very flight averages 6 m/s and would look
    /// *fast* — which is the same category error the correction exists to undo.
    /// Below 10 km the density factor is small enough for the comparison to hold,
    /// and it is where the landing is decided.
    private func belowTenK(_ name: String) throws -> (drop: Double, seconds: Double) {
        let track = try flight(name)
        let b = burstIndex(track)
        let low = track[b...].filter { $0.altitude < 10_000 }
        let first = try XCTUnwrap(low.first), last = try XCTUnwrap(low.last)
        return (first.altitude - last.altitude, last.timestamp.timeIntervalSince(first.timestamp))
    }

    func testSlowFlightFallsMarkedlyShortOfTheAssumedRate() throws {
        let seg = try belowTenK("W4214915")
        let model = DescentRateModel()
        let comparison = DescentRateModel.FallComparison(
            actualDrop: seg.drop, predictedDrop: 5.0 * seg.seconds, rateUsed: 5.0)

        let corrected = try XCTUnwrap(model.correctedRate(from: comparison))
        XCTAssertLessThan(corrected, 4.0, "a slow chute must pull the rate down, got \(corrected)")

        let deviation = try XCTUnwrap(model.deviationPercent(from: comparison))
        XCTAssertLessThan(deviation, -20, "should read as clearly slower than assumed, got \(deviation)%")
    }

    func testTheTwoFlightsAreDistinguishable() throws {
        // The discrimination the whole feature rests on. If a slow chute and a
        // normal one correct to the same rate, none of this is worth building.
        func correction(_ name: String) throws -> Double {
            let seg = try belowTenK(name)
            return try XCTUnwrap(DescentRateModel().correctedRate(
                from: .init(actualDrop: seg.drop, predictedDrop: 5.0 * seg.seconds, rateUsed: 5.0)))
        }
        let slow = try correction("W4214915")
        let normal = try correction("W4140855")

        XCTAssertLessThan(slow, normal, "the slow flight must correct to a lower rate than the control")
        XCTAssertGreaterThan(normal - slow, 0.5, "separation was only \(normal - slow) m/s")
    }

    // MARK: - Flight shape

    func testBothFlightsBurstHighAndDescend() throws {
        for name in ["W4214915", "W4140855"] {
            let track = try flight(name)
            let b = burstIndex(track)
            XCTAssertGreaterThan(track[b].altitude, 25_000, "\(name) burst altitude")
            XCTAssertGreaterThan(b, 10, "\(name) should climb before bursting")
            XCTAssertLessThan(track.last!.altitude, track[b].altitude / 2, "\(name) should descend after burst")
        }
    }

    func testTheSlowFlightTookLongerToFallThanTheControl() throws {
        func descentMinutes(_ name: String) throws -> Double {
            let t = try flight(name); let b = burstIndex(t)
            return t.last!.timestamp.timeIntervalSince(t[b].timestamp) / 60
        }
        let slow = try descentMinutes("W4214915")
        let normal = try descentMinutes("W4140855")
        XCTAssertGreaterThan(slow, normal,
                             "the slow chute stayed up longer: \(Int(slow)) vs \(Int(normal)) min")
    }
}
