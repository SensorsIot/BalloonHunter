import XCTest
import CoreLocation
@testable import BalloonHunter

/// End-to-end replay of a real landing sequence, driven frame by frame through
/// `LandingDetector` — not just the parts, the whole descent.
///
/// Uses today's flight W4214924 (21 Aug 2026): the real SondeHub descent from
/// burst (34 397 m) down to 389 m, where the feed was lost. The receiver was on
/// BLE for the descent; the test hands the last minute over to APRS, the switch
/// that produced the false-landing investigation. The questions this pins:
///
/// - the descent is classified correctly the whole way down;
/// - the BLE→APRS handoff, with continuous fresh data, does **not** produce a
///   false landing (the real failure was a *stale* gap, not the switch itself);
/// - a genuine ground-sit after the descent **is** detected as landed;
/// - a stale frame after the switch is what actually triggers the landed rule.
final class LandingSequenceTests: XCTestCase {

    private struct Sample: Decodable { let t: Double; let lat: Double; let lon: Double; let alt: Double; let vv: Double }

    private let detector = LandingDetector()
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func descent() throws -> [Sample] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "W4214924_descent", withExtension: "json"),
                                "fixture W4214924_descent.json missing")
        return try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
    }

    private func trackPoint(_ s: Sample, source: TelemetrySource) -> BalloonTrackPoint {
        BalloonTrackPoint(latitude: s.lat, longitude: s.lon, altitude: s.alt,
                          timestamp: epoch.addingTimeInterval(s.t),
                          verticalSpeed: s.vv, horizontalSpeed: 0, source: source)
    }

    private func position(_ s: Sample, source: TelemetrySource, ageSeconds: TimeInterval = 0) -> PositionData {
        PositionData(sondeName: "W4214924", latitude: s.lat, longitude: s.lon, altitude: s.alt,
                     verticalSpeed: s.vv, horizontalSpeed: 0, heading: 0,
                     temperature: 0, humidity: 0, pressure: 0,
                     timestamp: Date().addingTimeInterval(-ageSeconds),
                     burstKillerTime: 0, telemetrySource: source)
    }

    // MARK: - The whole descent, with the handoff in the last minute

    func testFullDescentWithHandoff_neverFalselyLands() throws {
        let samples = try descent()
        let lastT = samples.last!.t
        var track: [BalloonTrackPoint] = []
        var sawBelow10k = false, sawAbove10k = false

        for s in samples {
            // BLE for the descent; hand the last 60 s to APRS, all fresh (age 0).
            let source: TelemetrySource = (lastT - s.t <= 60) ? .aprs : .ble
            track.append(trackPoint(s, source: source))
            let phase = detector.classifyPhase(track: track, position: position(s, source: source))

            // The balloon is descending the entire fixture (feed lost at 389 m,
            // still falling) — it must never read landed on fresh data.
            XCTAssertNotEqual(phase, .landed,
                              "false landing at t=\(s.t)s alt=\(s.alt)m source=\(source)")
            if s.alt >= 10_000, phase == .descendingAbove10k { sawAbove10k = true }
            if s.alt < 10_000, s.vv < 0, phase == .descendingBelow10k { sawBelow10k = true }
        }
        XCTAssertTrue(sawAbove10k, "should classify high-altitude descent")
        XCTAssertTrue(sawBelow10k, "should classify low-altitude descent")
    }

    func testHandoffFrameItself_isNotLanded() throws {
        // The exact moment the source flips to APRS, low and descending: fresh
        // data must read as flying, not landed. This is the switch the real bug
        // was wrongly blamed on.
        let samples = try descent()
        let track = samples.map { trackPoint($0, source: .ble) }
        let last = samples.last!
        let phase = detector.classifyPhase(track: track, position: position(last, source: .aprs, ageSeconds: 0))
        XCTAssertNotEqual(phase, .landed, "a fresh APRS frame mid-descent is not a landing")
        XCTAssertEqual(phase, .descendingBelow10k)
    }

    // The predicted landing for this flight — the last estimate logged before the
    // feed was lost (see docs/LandingPredictionTrack-W4214924). This is where the
    // balloon actually comes down and where the hunter drives; ~2.3 km from the
    // last APRS point (389 m), the drift over the unobserved final descent.
    private let predictedLanding = (lat: 47.71429, lon: 7.53771)

    // MARK: - Losing APRS says the flight is over, not where it lies

    func testStaleAPRSAtAltitude_landsByStaleRule_positionIsEstimate() throws {
        // APRS coverage ends at 389 m, still falling. Silence past the threshold
        // means the flight is over (the balloon reached the ground) — so the phase
        // is landed with reason aprsStale. But this says *that* it landed, not
        // *where*: the position is only the estimate (the prediction), never the
        // last-heard-at-altitude point. See FSD *How a Landing Is Determined*.
        let samples = try descent()
        let track = samples.map { trackPoint($0, source: .ble) }
        let pos = position(samples.last!, source: .aprs, ageSeconds: 200)
        XCTAssertEqual(detector.classifyPhase(track: track, position: pos), .landed)
        XCTAssertEqual(detector.landingReason(track: track, position: pos), .aprsStale,
                       "landed-by-silence: the flight is over, position is the prediction")
    }

    // MARK: - The confirmed touchdown: the hunter closes in on BLE

    func testFullRecovery_APRSLostThenBLEConfirmsAtPredictedLanding() throws {
        // The whole recovery, end to end:
        //  1. APRS descent to 389 m, still falling — feed lost. Landed-by-silence:
        //     the flight is over, the estimate is the predicted landing.
        //  2. the hunter drives to that predicted landing (a telemetry gap).
        //  3. there, the MySondyGo (BLE) hears the sonde sitting fixed near the
        //     ground, vertical speed 0 — the confirmed touchdown, at the predicted
        //     landing point.
        let samples = try descent()
        var track = samples.map { trackPoint($0, source: .ble) }

        // 1. Last APRS frame, stale → landed by silence; reason is aprsStale, i.e.
        //    the position is the estimate, not this 389 m point.
        let lostInAir = position(samples.last!, source: .aprs, ageSeconds: 300)
        XCTAssertEqual(detector.landingReason(track: track, position: lostInAir), .aprsStale)

        // 3. BLE reacquires the sonde on the ground, at the predicted landing —
        //    fixed, near ground, vertical speed 0.
        let groundAlt = 410.0
        let groundT = samples.last!.t + 1800           // half an hour later
        for i in 0..<20 {
            track.append(BalloonTrackPoint(latitude: predictedLanding.lat, longitude: predictedLanding.lon,
                                           altitude: groundAlt,
                                           timestamp: epoch.addingTimeInterval(groundT + Double(i)),
                                           verticalSpeed: 0, horizontalSpeed: 0, source: .ble))
        }
        let onTheGround = PositionData(sondeName: "W4214924",
                                       latitude: predictedLanding.lat, longitude: predictedLanding.lon,
                                       altitude: groundAlt, verticalSpeed: 0, horizontalSpeed: 0, heading: 0,
                                       temperature: 0, humidity: 0, pressure: 0,
                                       timestamp: Date(), burstKillerTime: 0, telemetrySource: .ble)

        let phase = detector.classifyPhase(track: track, position: onTheGround)
        XCTAssertEqual(phase, .landed, "a fixed, near-ground BLE fix is the confirmed touchdown")
        XCTAssertEqual(detector.landingReason(track: track, position: onTheGround), .vectorAnalysis,
                       "confirmed by a stationary near-ground observation, not by silence")

        // The confirmed touchdown is the predicted landing, well away from where
        // APRS was lost — the estimate held, and BLE confirmed it.
        let dLat = abs(predictedLanding.lat - samples.last!.lat)
        XCTAssertGreaterThan(dLat, 0.01, "touchdown is the predicted point, ~km from the last APRS fix")
    }

    // MARK: - Track assembly across the handoff

    func testBackfillOfTheHandoffMinuteDoesNotDuplicate() throws {
        // BLE recorded the descent; a backfill then offers the whole flight from
        // SondeHub with the ~17 s relay skew. The last minute BLE already holds
        // must not be duplicated.
        let samples = try descent()
        let bleTrack = samples.map { trackPoint($0, source: .ble) }
        let backfill = samples.map {
            BalloonTrackPoint(latitude: $0.lat, longitude: $0.lon, altitude: $0.alt,
                              timestamp: epoch.addingTimeInterval($0.t + 17),
                              verticalSpeed: $0.vv, horizontalSpeed: 0, source: .aprs)
        }
        let merged = bleTrack.mergingByPosition(backfill)
        XCTAssertEqual(merged.count, bleTrack.count, "no duplication of BLE-covered descent")
        XCTAssertTrue(merged.allSatisfy { $0.source == .ble }, "every position was already BLE's")
    }
}
