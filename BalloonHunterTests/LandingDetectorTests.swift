import XCTest
import CoreLocation
@testable import BalloonHunter

/// Tests for the three landing-detection algorithms and their priority chain.
///
/// These thresholds decide whether the app shows a prediction path or navigates
/// the hunter to a field, so each one is pinned here.
final class LandingDetectorTests: XCTestCase {

    private let detector = LandingDetector()
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Builders

    /// A track point. Defaults sit at a plausible Swiss launch site.
    private func point(lat: Double = 46.90,
                       lon: Double = 7.31,
                       alt: Double,
                       t: TimeInterval) -> BalloonTrackPoint {
        BalloonTrackPoint(latitude: lat,
                          longitude: lon,
                          altitude: alt,
                          timestamp: epoch.addingTimeInterval(t),
                          verticalSpeed: 0,
                          horizontalSpeed: 0)
    }

    private func position(alt: Double = 1000,
                          verticalSpeed: Double = 0,
                          source: TelemetrySource = .ble,
                          age: TimeInterval = 0) -> PositionData {
        PositionData(sondeName: "V4210129",
                     latitude: 46.90,
                     longitude: 7.31,
                     altitude: alt,
                     verticalSpeed: verticalSpeed,
                     horizontalSpeed: 0,
                     heading: 0,
                     temperature: 0,
                     humidity: 0,
                     pressure: 0,
                     timestamp: Date().addingTimeInterval(-age),
                     burstKillerTime: 0,
                     telemetrySource: source)
    }

    /// A stationary track: `count` points at one spot, one second apart.
    private func stationaryTrack(count: Int, alt: Double = 500, startAt: TimeInterval = 0) -> [BalloonTrackPoint] {
        (0..<count).map { point(alt: alt, t: startAt + Double($0)) }
    }

    /// A track drifting `metersPerSecond` east, one point per second.
    private func movingTrack(count: Int, metersPerSecond: Double, alt: Double = 500) -> [BalloonTrackPoint] {
        let metersPerDegreeLon = 111_320.0 * cos(46.90 * .pi / 180)
        return (0..<count).map { i in
            point(lon: 7.31 + (Double(i) * metersPerSecond) / metersPerDegreeLon,
                  alt: alt,
                  t: Double(i))
        }
    }

    // MARK: - Vector Analysis

    func testVectorAnalysis_stationaryBelow3000m_isLanded() {
        XCTAssertTrue(detector.isStoppedByVectorAnalysis(track: stationaryTrack(count: 20, alt: 500)))
    }

    func testVectorAnalysis_stationaryAbove3000m_isNotLanded() {
        // A balloon hovering at altitude has not landed, however still it is.
        XCTAssertFalse(detector.isStoppedByVectorAnalysis(track: stationaryTrack(count: 20, alt: 3500)))
    }

    func testVectorAnalysis_atAltitudeThreshold_isNotLanded() {
        // Boundary: 3000 m exactly must fail the strict `<` comparison.
        XCTAssertFalse(detector.isStoppedByVectorAnalysis(track: stationaryTrack(count: 20, alt: 3000)))
    }

    func testVectorAnalysis_movingFasterThan3kmh_isNotLanded() {
        // 2 m/s = 7.2 km/h, well above the 3 km/h threshold.
        XCTAssertFalse(detector.isStoppedByVectorAnalysis(track: movingTrack(count: 20, metersPerSecond: 2.0)))
    }

    func testVectorAnalysis_driftingSlowerThan3kmh_isLanded() {
        // 0.5 m/s = 1.8 km/h — below threshold, e.g. GPS wander on the ground.
        XCTAssertTrue(detector.isStoppedByVectorAnalysis(track: movingTrack(count: 20, metersPerSecond: 0.5)))
    }

    func testVectorAnalysis_fewerThanFivePoints_isNotLanded() {
        // Too little history to judge; must not report a landing at launch.
        XCTAssertFalse(detector.isStoppedByVectorAnalysis(track: stationaryTrack(count: 4)))
    }

    func testVectorAnalysis_exactlyFivePoints_isEvaluated() {
        XCTAssertTrue(detector.isStoppedByVectorAnalysis(track: stationaryTrack(count: 5)))
    }

    func testVectorAnalysis_descendingFast_isNotLanded() {
        // Vertical movement counts: 10 m/s descent must not read as landed
        // even though lat/lon never change.
        let descending = (0..<20).map { point(alt: 2000 - Double($0) * 10, t: Double($0)) }
        XCTAssertFalse(detector.isStoppedByVectorAnalysis(track: descending))
    }

    func testVectorAnalysis_zeroTimeWindow_isNotLanded() {
        // Guards against divide-by-zero when every point shares a timestamp.
        let sameInstant = (0..<10).map { _ in point(alt: 500, t: 0) }
        XCTAssertFalse(detector.isStoppedByVectorAnalysis(track: sameInstant))
    }

    // MARK: - Phase Classification

    func testClassify_noPosition_isUnknown() {
        XCTAssertEqual(detector.classifyPhase(track: [], position: nil), .unknown)
    }

    func testClassify_ascending() {
        XCTAssertEqual(detector.classifyPhase(track: [], position: position(verticalSpeed: 5)), .ascending)
    }

    func testClassify_descendingAbove10k() {
        let p = position(alt: 12_000, verticalSpeed: -8)
        XCTAssertEqual(detector.classifyPhase(track: [], position: p), .descendingAbove10k)
    }

    func testClassify_descendingBelow10k() {
        let p = position(alt: 8_000, verticalSpeed: -8)
        XCTAssertEqual(detector.classifyPhase(track: [], position: p), .descendingBelow10k)
    }

    func testClassify_atDescentSplitAltitude_isAbove10k() {
        // Boundary: 10 000 m exactly is *not* "below 10k".
        let p = position(alt: 10_000, verticalSpeed: -8)
        XCTAssertEqual(detector.classifyPhase(track: [], position: p), .descendingAbove10k)
    }

    func testClassify_zeroVerticalSpeedWithNoTrack_isUnknown() {
        XCTAssertEqual(detector.classifyPhase(track: [], position: position(verticalSpeed: 0)), .unknown)
    }

    func testClassify_staleAPRS_isLanded() {
        let p = position(verticalSpeed: 5, source: .aprs, age: 121)
        XCTAssertEqual(detector.classifyPhase(track: [], position: p), .landed)
    }

    func testClassify_freshAPRS_usesVerticalSpeed() {
        let p = position(verticalSpeed: 5, source: .aprs, age: 60)
        XCTAssertEqual(detector.classifyPhase(track: [], position: p), .ascending)
    }

    func testClassify_staleBLE_isNotLandedByAge() {
        // The age rule is APRS-only; a stale BLE packet must not force .landed.
        let p = position(verticalSpeed: 5, source: .ble, age: 300)
        XCTAssertEqual(detector.classifyPhase(track: [], position: p), .ascending)
    }

    // MARK: - Priority Chain

    func testClassify_trackLandingBeatsAscendingTelemetry() {
        // Once a track landing is known it is definitive: a recovery vehicle
        // carrying the sonde uphill must not flip the app back to flying.
        let landing = TrackLanding(index: 0,
                                   timestamp: epoch,
                                   coordinate: CLLocationCoordinate2D(latitude: 46.9, longitude: 7.3),
                                   reason: .stationaryPeriod)
        let phase = detector.classifyPhase(track: movingTrack(count: 20, metersPerSecond: 30),
                                           position: position(verticalSpeed: 5),
                                           trackLanding: landing)
        XCTAssertEqual(phase, .landed)
    }

    func testClassify_vectorAnalysisBeatsVerticalSpeed() {
        // Telemetry claims ascent, but the track shows the balloon has not moved.
        let phase = detector.classifyPhase(track: stationaryTrack(count: 20, alt: 500),
                                           position: position(alt: 500, verticalSpeed: 5))
        XCTAssertEqual(phase, .landed)
    }

    // MARK: - Track Scan: Blackout

    func testScan_blackoutGapAfterBurst_isDetected() {
        // Ascend, burst, descend, then stop transmitting for 30 minutes.
        var track = (0..<30).map { point(alt: Double($0) * 1000, t: Double($0) * 60) }   // up to 29 km
        track += (0..<30).map { point(alt: 29_000 - Double($0) * 900, t: 1800 + Double($0) * 60) }
        let lastBeforeGap = track.count - 1
        track.append(point(alt: 400, t: 3600 + 31 * 60))   // recovered, 31 min later

        let landing = detector.scanTrackForLanding(track)

        XCTAssertEqual(landing?.index, lastBeforeGap)
        XCTAssertEqual(landing?.reasonDescription, "telemetry blackout")
    }

    func testScan_shortGapAfterBurst_isNotALanding() {
        // A 5-minute dropout is normal and must not truncate the track.
        var track = (0..<30).map { point(alt: Double($0) * 1000, t: Double($0) * 60) }
        track += (0..<30).map { point(alt: 29_000 - Double($0) * 900, t: 1800 + Double($0) * 60) }
        track.append(point(alt: 400, t: 3600 + 5 * 60))

        XCTAssertNil(detector.scanTrackForLanding(track))
    }

    func testScan_gapDuringAscent_isIgnored() {
        // A dropout before burst is not a landing — the balloon is still climbing.
        var track = (0..<15).map { point(alt: Double($0) * 500, t: Double($0) * 60) }
        track += (0..<15).map { point(alt: 7500 + Double($0) * 500, t: 900 + 40 * 60 + Double($0) * 60) }

        let landing = detector.scanTrackForLanding(track)
        XCTAssertNil(landing, "A gap while still ascending must not be read as a landing")
    }

    // MARK: - Track Scan: Stationary

    func testScan_stationaryAfterBurst_isDetected() {
        // Ascend, burst, descend, then sit still on the ground for 25 minutes.
        // The ground segment must exceed the 20-minute window (120 points at
        // 10 s spacing) or the window still straddles the descent and the
        // altitude drift masks the landing.
        var track = (0..<20).map { point(alt: Double($0) * 1000, t: Double($0) * 10) }
        track += (0..<20).map { point(alt: 19_000 - Double($0) * 950, t: 200 + Double($0) * 10) }
        let firstGroundIndex = track.count
        track += (0..<150).map { point(alt: 400, t: 400 + Double($0) * 10) }

        let landing = detector.scanTrackForLanding(track)

        XCTAssertNotNil(landing)
        XCTAssertEqual(landing?.reasonDescription, "stationary period")
        XCTAssertGreaterThanOrEqual(landing?.index ?? 0, firstGroundIndex,
                                    "Landing must be reported at or after the balloon reaches the ground")
    }

    func testScan_groundTimeShorterThanWindow_isNotDetected() {
        // Only 10 minutes on the ground. The 20-minute window cannot be filled
        // with stationary points, so no landing is reported yet. This is the
        // documented cost of the 20-minute rule, pinned here deliberately.
        var track = (0..<20).map { point(alt: Double($0) * 1000, t: Double($0) * 10) }
        track += (0..<20).map { point(alt: 19_000 - Double($0) * 950, t: 200 + Double($0) * 10) }
        track += (0..<60).map { point(alt: 400, t: 400 + Double($0) * 10) }

        XCTAssertNil(detector.scanTrackForLanding(track))
    }

    func testScan_continuousDescent_isNotALanding() {
        // Nearly-vertical descent holds lat/lon almost constant. Altitude change
        // is what stops this being reported as a landing.
        let track = (0..<80).map { point(alt: 20_000 - Double($0) * 250, t: Double($0) * 10) }
        XCTAssertNil(detector.scanTrackForLanding(track))
    }

    func testScan_stillAscending_isNotALanding() {
        let track = (0..<80).map { point(alt: Double($0) * 250, t: Double($0) * 10) }
        XCTAssertNil(detector.scanTrackForLanding(track))
    }

    // MARK: - Track Scan: Guards

    func testScan_tooFewPoints_returnsNil() {
        XCTAssertNil(detector.scanTrackForLanding(stationaryTrack(count: 9, alt: 400)))
    }

    func testScan_emptyTrack_returnsNil() {
        XCTAssertNil(detector.scanTrackForLanding([]))
    }

    func testScan_zeroDurationTrack_returnsNil() {
        // All points share a timestamp — window sizing would divide by zero.
        let sameInstant = (0..<20).map { _ in point(alt: 400, t: 0) }
        XCTAssertNil(detector.scanTrackForLanding(sameInstant))
    }

    func testScan_blackoutTakesPriorityOverStationary() {
        // A track that satisfies both rules must report the blackout, because
        // the gap marks the true landing and the stationary points are
        // post-recovery transmission.
        var track = (0..<20).map { point(alt: Double($0) * 1000, t: Double($0) * 10) }
        track += (0..<20).map { point(alt: 19_000 - Double($0) * 950, t: 200 + Double($0) * 10) }
        let lastBeforeGap = track.count - 1
        track += (0..<60).map { point(alt: 400, t: 400 + 25 * 60 + Double($0) * 10) }

        let landing = detector.scanTrackForLanding(track)

        XCTAssertEqual(landing?.reasonDescription, "telemetry blackout")
        XCTAssertEqual(landing?.index, lastBeforeGap)
    }

    // MARK: - Threshold Injection

    func testCustomThresholds_areHonoured() {
        // Raising the altitude ceiling lets a high hover count as landed.
        let permissive = LandingDetector(
            thresholds: {
                var t = LandingDetector.Thresholds.default
                t.landingAltitudeM = 5000
                return t
            }()
        )
        let track = stationaryTrack(count: 20, alt: 4000)

        XCTAssertFalse(detector.isStoppedByVectorAnalysis(track: track))
        XCTAssertTrue(permissive.isStoppedByVectorAnalysis(track: track))
    }
}
