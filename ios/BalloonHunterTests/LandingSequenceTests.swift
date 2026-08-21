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

    // MARK: - What actually ends the flight

    func testStaleAPRSAfterHandoff_landsByStaleRule() throws {
        // The real failure: after the switch, telemetry stops arriving. A frame
        // older than the 120 s threshold is what makes the detector say landed —
        // and its reason is aprsStale, not the switch.
        let samples = try descent()
        let track = samples.map { trackPoint($0, source: .ble) }
        let last = samples.last!
        let phase = detector.classifyPhase(track: track, position: position(last, source: .aprs, ageSeconds: 200))
        XCTAssertEqual(phase, .landed)
        XCTAssertEqual(detector.landingReason(track: track, position: position(last, source: .aprs, ageSeconds: 200)),
                       .aprsStale)
    }

    func testGenuineGroundSit_landsByVectorAnalysis() throws {
        // Complete the sequence the lost feed never showed: the balloon settles
        // at its last point and keeps transmitting, stationary, below 3000 m.
        // That must be detected as landed by vector analysis.
        let samples = try descent()
        var track = samples.map { trackPoint($0, source: .ble) }
        let rest = samples.last!
        let groundT = samples.last!.t
        for i in 1...25 {   // 25 samples sitting still, ~1/10 s cadence
            track.append(BalloonTrackPoint(latitude: rest.lat, longitude: rest.lon, altitude: rest.alt,
                                           timestamp: epoch.addingTimeInterval(groundT + Double(i) * 10),
                                           verticalSpeed: 0, horizontalSpeed: 0, source: .ble))
        }
        let settled = PositionData(sondeName: "W4214924", latitude: rest.lat, longitude: rest.lon,
                                   altitude: rest.alt, verticalSpeed: 0, horizontalSpeed: 0, heading: 0,
                                   temperature: 0, humidity: 0, pressure: 0,
                                   timestamp: Date(), burstKillerTime: 0, telemetrySource: .ble)
        let phase = detector.classifyPhase(track: track, position: settled)
        XCTAssertEqual(phase, .landed, "a stationary balloon below 3000 m has landed")
        XCTAssertEqual(detector.landingReason(track: track, position: settled), .vectorAnalysis)
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
