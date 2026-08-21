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

    // Where the balloon actually touches down — the *final* prediction, from the
    // last APRS fix at 389 m. Ground there is ~300 m, so the balloon was only
    // ~90 m above ground when APRS was lost: ~20 s from landing, drifting a
    // couple hundred metres NE, not kilometres. (An earlier prediction made from
    // higher up put the landing ~2 km further, but by 389 m almost all that drift
    // is already spent — the final estimate sits right by the last fix.)
    private let predictedLanding = (lat: 47.73165, lon: 7.56680)   // ~150 m NE of the last APRS point
    private let groundAltMSL = 300.0                                // terrain ~300 m in that area

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
        //     landing point (~150 m from the last APRS fix, since the balloon was
        //     only ~90 m above ground when APRS was lost).
        let samples = try descent()
        var track = samples.map { trackPoint($0, source: .ble) }

        // 1. Last APRS frame, stale → landed by silence; reason is aprsStale, i.e.
        //    the position is the estimate, not this 389 m point.
        let lostInAir = position(samples.last!, source: .aprs, ageSeconds: 300)
        XCTAssertEqual(detector.landingReason(track: track, position: lostInAir), .aprsStale)

        // 3. BLE reacquires the sonde on the ground, at the predicted landing —
        //    fixed, at ground level (~300 m MSL), vertical speed 0.
        let groundT = samples.last!.t + 1800           // half an hour later
        for i in 0..<20 {
            track.append(BalloonTrackPoint(latitude: predictedLanding.lat, longitude: predictedLanding.lon,
                                           altitude: groundAltMSL,
                                           timestamp: epoch.addingTimeInterval(groundT + Double(i)),
                                           verticalSpeed: 0, horizontalSpeed: 0, source: .ble))
        }
        let onTheGround = PositionData(sondeName: "W4214924",
                                       latitude: predictedLanding.lat, longitude: predictedLanding.lon,
                                       altitude: groundAltMSL, verticalSpeed: 0, horizontalSpeed: 0, heading: 0,
                                       temperature: 0, humidity: 0, pressure: 0,
                                       timestamp: Date(), burstKillerTime: 0, telemetrySource: .ble)

        let phase = detector.classifyPhase(track: track, position: onTheGround)
        XCTAssertEqual(phase, .landed, "a fixed, near-ground BLE fix is the confirmed touchdown")
        XCTAssertEqual(detector.landingReason(track: track, position: onTheGround), .vectorAnalysis,
                       "confirmed by a stationary near-ground observation, not by silence")

        // The touchdown is close to the last APRS fix — the balloon was ~90 m
        // above ground (389 m MSL over ~300 m terrain) when the feed dropped, so
        // it drifted only a couple hundred metres, not kilometres.
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = metersPerDegLat * cos(predictedLanding.lat * .pi / 180)
        let dNorth = (predictedLanding.lat - samples.last!.lat) * metersPerDegLat
        let dEast = (predictedLanding.lon - samples.last!.lon) * metersPerDegLon
        let drift = (dNorth * dNorth + dEast * dEast).squareRoot()
        XCTAssertLessThan(drift, 400, "touchdown within a few hundred m of the last APRS fix, got \(Int(drift)) m")
    }

    // MARK: - Landing-display behaviour through the whole drive (pure)

    /// The behaviour the app must show — landing marker, route target, and
    /// whether the descent line is drawn — resolved as a pure value at each stage
    /// of the recovery. This is the "what the app does" the services only apply.
    func testLandingDisplay_predictionUntilBLEConfirms() throws {
        let samples = try descent()
        let track = samples.map { trackPoint($0, source: .ble) }
        let last = samples.last!

        // Descending on fresh telemetry: the estimate is the prediction, the line
        // is drawn, the route points at the prediction.
        let flying = position(last, source: .aprs, ageSeconds: 5)
        let r1 = detector.resolveLanding(reason: detector.landingReason(track: track, position: flying),
                                         currentPosition: flying, hasPrediction: true)
        XCTAssertEqual(r1, .init(target: .prediction, showPredictionPath: true))

        // APRS goes silent at altitude: landed-by-silence. The marker/route MUST
        // stay on the prediction — never jump to the 389 m last-heard point — and
        // the line stays drawn for the drive.
        let silent = position(last, source: .aprs, ageSeconds: 300)
        XCTAssertEqual(detector.landingReason(track: track, position: silent), .aprsStale)
        let r2 = detector.resolveLanding(reason: .aprsStale, currentPosition: silent, hasPrediction: true)
        XCTAssertEqual(r2, .init(target: .prediction, showPredictionPath: true),
                       "landed-by-silence keeps the prediction; it must not lock to 389 m")

        // BLE confirms the sonde fixed on the ground at the predicted landing:
        // now the marker/route lock to the actual point and the line is dropped.
        let onGround = PositionData(sondeName: "W4214924",
                                    latitude: predictedLanding.lat, longitude: predictedLanding.lon,
                                    altitude: groundAltMSL, verticalSpeed: 0, horizontalSpeed: 0, heading: 0,
                                    temperature: 0, humidity: 0, pressure: 0,
                                    timestamp: Date(), burstKillerTime: 0, telemetrySource: .ble)
        let r3 = detector.resolveLanding(reason: .vectorAnalysis, currentPosition: onGround, hasPrediction: true)
        XCTAssertEqual(r3, .init(target: .confirmed(latitude: predictedLanding.lat, longitude: predictedLanding.lon),
                                 showPredictionPath: false),
                       "a BLE touchdown locks to the actual point and drops the line")
    }

    func testLandingDisplay_noPredictionYet_showsNothing() {
        let r = detector.resolveLanding(reason: nil, currentPosition: nil, hasPrediction: false)
        XCTAssertEqual(r, .init(target: .none, showPredictionPath: false))
    }

    func testLandingDisplay_landedBySilenceWithoutAPrediction_showsNothing() throws {
        // The regression the earlier test missed: landed-by-silence resolves to
        // the prediction — but only if one exists. With no prediction there is
        // nothing to show, which is why predictions MUST run in this state (see
        // PredictionPolicy). This asserts the dependency instead of assuming it.
        let samples = try descent()
        let silent = position(samples.last!, source: .aprs, ageSeconds: 300)
        let r = detector.resolveLanding(reason: .aprsStale, currentPosition: silent, hasPrediction: false)
        XCTAssertEqual(r, .init(target: .none, showPredictionPath: false),
                       "no prediction → nothing to show; predictions must run for landed-by-silence")
    }

    // MARK: - Predictions must run through landed-by-silence

    func testPredictionPolicy_runsThroughLandedBySilence() {
        // This is the test whose absence let the blank-map regression through:
        // landed-by-silence must keep predicting so there is a landing to route to.
        XCTAssertTrue(PredictionPolicy.shouldPredict(state: .aprsLanded, confirmedTouchdown: false),
                      "landed-by-silence must keep predicting")
        XCTAssertTrue(PredictionPolicy.shouldPredict(state: .liveBLELanded, confirmedTouchdown: false))
    }

    func testPredictionPolicy_stopsOnConfirmedTouchdown() {
        for state in [DataState.aprsLanded, .liveBLELanded, .aprsFlying, .liveBLEFlying] {
            XCTAssertFalse(PredictionPolicy.shouldPredict(state: state, confirmedTouchdown: true),
                           "a confirmed touchdown ends predictions in \(state)")
        }
    }

    func testPredictionPolicy_runsWhileFlying_stopsWithoutBasis() {
        XCTAssertTrue(PredictionPolicy.shouldPredict(state: .liveBLEFlying, confirmedTouchdown: false))
        XCTAssertTrue(PredictionPolicy.shouldPredict(state: .aprsFlying, confirmedTouchdown: false))
        for state in [DataState.startup, .waitingForAPRS, .noTelemetry] {
            XCTAssertFalse(PredictionPolicy.shouldPredict(state: state, confirmedTouchdown: false),
                           "\(state) has no basis for a prediction")
        }
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
