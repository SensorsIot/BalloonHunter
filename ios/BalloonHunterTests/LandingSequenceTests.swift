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

    // MARK: - What the app locks the landing point to (confirmsTouchdown)

    /// The real decision the app applies: landed-by-silence keeps the prediction,
    /// only a confirmed touchdown locks to the actual point.
    func testConfirmsTouchdown_onlyForGroundObservation() {
        XCTAssertFalse(detector.confirmsTouchdown(.aprsStale),
                       "landed-by-silence is an estimate — keep the prediction, do not lock")
        XCTAssertFalse(detector.confirmsTouchdown(nil), "flying — no touchdown")
        XCTAssertTrue(detector.confirmsTouchdown(.vectorAnalysis), "stationary near ground = touchdown")
        XCTAssertTrue(detector.confirmsTouchdown(.trackLanding), "track landing = touchdown")
    }

    // MARK: - Predictions run when the position is unknown, not merely when flying

    /// The question is "do we know where it is?", never "is it landed?".
    /// See FSD *How a Landing Is Determined → When prediction runs*.

    func testPredict_whileFlying_always() {
        for state in [DataState.liveBLEFlying, .aprsFlying] {
            XCTAssertTrue(PredictionPolicy.shouldPredict(state: state,
                                                         touchdownConfirmed: false,
                                                         hasPrediction: false),
                          "\(state): flying with no estimate yet must predict")
            XCTAssertTrue(PredictionPolicy.shouldPredict(state: state,
                                                         touchdownConfirmed: false,
                                                         hasPrediction: true),
                          "\(state): flying keeps re-predicting — each run has fresh telemetry")
        }
    }

    /// A sonde whose APRS coverage ended while it was still descending is down, but
    /// nobody has seen where. The predicted landing point is the only estimate there
    /// is, so one must be made.
    func testPredict_landedBySilence_withNoPrediction() {
        XCTAssertTrue(PredictionPolicy.shouldPredict(state: .aprsLanded,
                                                     touchdownConfirmed: false,
                                                     hasPrediction: false),
                      "down but never seen: without a prediction there is no landing point at all")
    }

    /// ...but only once. No new telemetry is arriving, so re-running would move the
    /// marker purely because the wind forecast advanced.
    func testNoPredict_landedBySilence_whenPredictionExists() {
        XCTAssertFalse(PredictionPolicy.shouldPredict(state: .aprsLanded,
                                                      touchdownConfirmed: false,
                                                      hasPrediction: true),
                       "estimate exists and nothing new arrived — re-running only tracks the forecast")
    }

    /// A fixed, near-ground observation is the position. Nothing left to estimate.
    func testNoPredict_afterConfirmedTouchdown() {
        for state in [DataState.aprsLanded, .liveBLELanded] {
            for hasPrediction in [true, false] {
                XCTAssertFalse(PredictionPolicy.shouldPredict(state: state,
                                                              touchdownConfirmed: true,
                                                              hasPrediction: hasPrediction),
                               "\(state): touchdown confirmed — the position is known")
            }
        }
    }

    /// BLE reporting landed without a confirmed touchdown is still an unknown
    /// position, and follows the same rule as landed-by-silence.
    func testPredict_bleLanded_unconfirmed_withNoPrediction() {
        XCTAssertTrue(PredictionPolicy.shouldPredict(state: .liveBLELanded,
                                                     touchdownConfirmed: false,
                                                     hasPrediction: false),
                      "landed but unconfirmed is an unknown position, whatever the source")
    }

    /// No telemetry to predict from, in any combination.
    func testNoPredict_withoutTelemetry() {
        for state in [DataState.startup, .waitingForAPRS, .noTelemetry] {
            for confirmed in [true, false] {
                for hasPrediction in [true, false] {
                    XCTAssertFalse(PredictionPolicy.shouldPredict(state: state,
                                                                  touchdownConfirmed: confirmed,
                                                                  hasPrediction: hasPrediction),
                                   "\(state): nothing to predict from")
                }
            }
        }
    }

    /// The touchdown verdict is `LandingDetector`'s, never re-derived here — the
    /// policy takes it as an input so there is one owner for that question.
    func testTouchdownVerdictComesFromTheDetector() {
        XCTAssertFalse(PredictionPolicy.shouldPredict(state: .aprsLanded,
                                                      touchdownConfirmed: detector.confirmsTouchdown(.vectorAnalysis),
                                                      hasPrediction: false))
        XCTAssertTrue(PredictionPolicy.shouldPredict(state: .aprsLanded,
                                                     touchdownConfirmed: detector.confirmsTouchdown(.aprsStale),
                                                     hasPrediction: false))
    }

    // MARK: - Landing time is anchored to telemetry, not the request launch

    func testLandingTime_anchoredToTelemetryNotLaunch() {
        // The predictor is asked with launch_datetime = now+60s, so its absolute
        // landing datetime is always in the future. The app must anchor to the
        // sonde's real telemetry time instead.
        let launch = Date(timeIntervalSince1970: 1_800_000_000)          // request launch
        let landing = launch.addingTimeInterval(90)                      // predictor: +90 s fall

        // A live descent heard just now → lands ~90 s from now.
        let fresh = Date()
        let freshLanding = PredictionService.anchoredLandingTime(telemetryTime: fresh, launch: launch, landing: landing)
        XCTAssertEqual(freshLanding.timeIntervalSince(fresh), 90, accuracy: 0.5)
        XCTAssertGreaterThan(freshLanding.timeIntervalSinceNow, 0, "a live descent lands in the future")

        // The W4214924 case: last heard 7.5 h ago → landing is in the PAST, not
        // "in a few minutes". This is the bug the anchoring fixes.
        let stale = Date().addingTimeInterval(-7.5 * 3600)
        let staleLanding = PredictionService.anchoredLandingTime(telemetryTime: stale, launch: launch, landing: landing)
        XCTAssertLessThan(staleLanding.timeIntervalSinceNow, 0,
                          "a sonde last heard 7.5 h ago landed in the past, not the future")
        XCTAssertEqual(staleLanding.timeIntervalSince(stale), 90, accuracy: 0.5)
    }

    // MARK: - Recovery status (radiosondy.info finds via SondeHub)

    private func report(_ recovered: Bool, at datetime: String) -> RecoveryReport {
        RecoveryReport(serial: "W4214924", datetime: datetime, recovered: recovered,
                       recovered_by: "DO2MIB", description: "test")
    }

    func testRecoveryStatus_foundProblemNone() {
        XCTAssertEqual(RecoveryStatus.latest(from: []), .none, "no report → none (landed marker stays blue)")
        XCTAssertEqual(RecoveryStatus.latest(from: [report(true, at: "2026-08-21T15:28:05")]), .found)
        XCTAssertEqual(RecoveryStatus.latest(from: [report(false, at: "2026-08-21T15:28:05")]), .problem)
    }

    func testRecoveryStatus_usesLatestReport() {
        // Newest datetime wins: an early "not recovered" then a later "found".
        let reports = [report(false, at: "2026-08-21T14:00:00"),
                       report(true, at: "2026-08-21T15:28:05")]
        XCTAssertEqual(RecoveryStatus.latest(from: reports), .found)
        XCTAssertEqual(RecoveryStatus.latest(from: reports.reversed()), .found, "order-independent")
    }

    func testRecoveryReport_decodesNativeSondeHubJSON() throws {
        // W4150389: native SondeHub recovery (fractional seconds + offset, extra
        // fields planned/alt/recovery_software).
        let json = #"[{"serial":"W4150389","lat":47.17759,"lon":7.94028,"alt":0,"recovered":true,"planned":false,"recovered_by":"MCH","description":"","recovery_software":"Sondehub Tracker","datetime":"2026-08-19T23:51:48.990646+00:00","position":[7.94028,47.17759]}]"#
        let reports = try JSONDecoder().decode([RecoveryReport].self, from: Data(json.utf8))
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(RecoveryStatus.latest(from: reports), .found)
    }

    func testRecoveryReport_decodesRealSondeHubJSON() throws {
        // The exact shape returned by api.v2.sondehub.org/recovered for W4214924.
        let json = #"[{"datetime":"2026-08-21T15:28:05","serial":"W4214924","lat":0.0,"lon":0.0,"recovered":true,"recovered_by":"DO2MIB","description":"Saubere Landung [via Radiosondy.info]","recovery_software":"SondeHub radiosondy.info Importer","position":[0.0,0.0]}]"#
        let reports = try JSONDecoder().decode([RecoveryReport].self, from: Data(json.utf8))
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports[0].recovered)
        XCTAssertEqual(reports[0].recovered_by, "DO2MIB")
        XCTAssertEqual(RecoveryStatus.latest(from: reports), .found)
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
