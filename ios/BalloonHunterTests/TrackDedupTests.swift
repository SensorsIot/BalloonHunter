import XCTest
@testable import BalloonHunter

/// Tests for track deduplication by physical position.
///
/// BLE and APRS decode the same sonde frame, so they report identical GPS
/// position — but BLE stamps the phone's arrival time while APRS carries the
/// sonde's frame time, and the two differ by the relay latency (~17 s observed
/// on W4214924, 21 Aug 2026). Keying dedup on the timestamp therefore let the
/// gap-fill re-insert APRS copies of points BLE had already laid down. Keying on
/// position fixes it. See FSD *Track Assembly → Deduplication*.
final class TrackDedupTests: XCTestCase {

    private func pt(_ lat: Double, _ lon: Double, _ alt: Double,
                    _ secondsFromEpoch: TimeInterval, _ source: TelemetrySource) -> BalloonTrackPoint {
        BalloonTrackPoint(latitude: lat, longitude: lon, altitude: alt,
                          timestamp: Date(timeIntervalSince1970: secondsFromEpoch),
                          verticalSpeed: -4.5, horizontalSpeed: 1.0, source: source)
    }

    // MARK: - The exact regression from the device

    func testAPRSCopyOfABLEPointIsNotDuplicated() {
        // The real numbers: BLE laid down 47.72113,7.56473,1551 at its arrival
        // time; the APRS copy arrives 17 s later with the same position.
        let ble = [pt(47.72113, 7.56473, 1551, 1000, .ble)]
        let aprsCopy = [pt(47.72113, 7.56473, 1551, 1017, .aprs)]   // +17 s, same place

        let merged = ble.mergingByPosition(aprsCopy)

        XCTAssertEqual(merged.count, 1, "the APRS copy of a BLE-covered position must be dropped")
        XCTAssertEqual(merged.first?.source, .ble, "the point BLE already held stays")
    }

    func testWholeBLETailIsNotDuplicatedByABackfill() {
        // Six BLE points, then a backfill of the same six positions 17 s later.
        let ble = (0..<6).map { i in pt(47.7210 + Double(i) * 1e-5, 7.5645 + Double(i) * 1e-5,
                                        1568 - Double(i) * 4, 1000 + Double(i), .ble) }
        let backfill = ble.map { pt($0.latitude, $0.longitude, $0.altitude,
                                    $0.timestamp.timeIntervalSince1970 + 17, .aprs) }

        let merged = ble.mergingByPosition(backfill)

        XCTAssertEqual(merged.count, 6, "no duplication of BLE-covered positions")
    }

    // MARK: - Genuine gaps are still filled

    func testGenuineGapIsFilled() {
        let ble = [pt(47.7210, 7.5645, 1600, 1000, .ble),
                   pt(47.7213, 7.5648, 1400, 1040, .ble)]           // 40 s / 200 m gap
        let aprsFill = [pt(47.7211, 7.5646, 1550, 1012, .aprs),
                        pt(47.7212, 7.5647, 1500, 1024, .aprs)]     // distinct positions

        let merged = ble.mergingByPosition(aprsFill)

        XCTAssertEqual(merged.count, 4, "distinct positions in the gap must be filled")
    }

    func testResultIsChronological() {
        let ble = [pt(47.7213, 7.5648, 1400, 1040, .ble)]
        let earlier = [pt(47.7210, 7.5645, 1600, 1000, .aprs)]      // earlier time, new position

        let merged = ble.mergingByPosition(earlier)

        XCTAssertEqual(merged.map { $0.timestamp }, merged.map { $0.timestamp }.sorted(),
                       "merged track must be time-ordered")
        XCTAssertEqual(merged.first?.altitude, 1600, "the earlier point sorts first")
    }

    // MARK: - Distinct samples are never merged

    func testDistinctDescentSamplesAreKept() {
        // 1 Hz descent at ~4.5 m/s: consecutive points are metres apart and must
        // never collapse into one.
        let track = (0..<10).map { i in pt(47.7210 + Double(i) * 2e-5, 7.5645 + Double(i) * 2e-5,
                                           1600 - Double(i) * 4.5, 1000 + Double(i), .aprs) }
        let merged = [BalloonTrackPoint]().mergingByPosition(track)
        XCTAssertEqual(merged.count, 10, "distinct descent samples must all survive")
    }

    func testSameAltitudeDifferentPlaceIsKept() {
        // The balloon passes 1600 m going up and again coming down — same
        // altitude, different lat/lon. Position keeps them apart; altitude alone
        // would have wrongly merged them.
        let ascending = [pt(47.700, 7.500, 1600, 1000, .aprs)]
        let descending = [pt(47.750, 7.600, 1600, 5000, .aprs)]
        let merged = ascending.mergingByPosition(descending)
        XCTAssertEqual(merged.count, 2, "same altitude at different places are distinct samples")
    }

    // MARK: - The key itself

    func testPositionKeyIgnoresTimeAndSource() {
        let a = pt(47.72113, 7.56473, 1551, 1000, .ble)
        let b = pt(47.72113, 7.56473, 1551, 1017, .aprs)
        XCTAssertEqual(a.positionKey, b.positionKey, "same place = same key, whatever the time or source")
    }

    func testPositionKeySeparatesByAboutAMetre() {
        let a = pt(47.72113, 7.56473, 1551, 1000, .ble)
        let higher = pt(47.72113, 7.56473, 1553, 1000, .ble)   // +2 m altitude
        XCTAssertNotEqual(a.positionKey, higher.positionKey, "a 2 m altitude difference is a different sample")
    }

    // MARK: - Legacy persistence

    // MARK: - Drawing simplification (full track kept for calculations)

    func testSimplify_straightRunCollapsesToEndpoints() {
        // 50 collinear 1 Hz points (due north) → just the two endpoints.
        let line = (0..<50).map { i in pt(47.0 + Double(i) * 1e-4, 7.0, 1000, Double(i), .aprs) }
        let simplified = line.simplifiedForDrawing(toleranceMeters: 25)
        XCTAssertEqual(simplified.count, 2, "a straight run keeps only its endpoints")
        XCTAssertEqual(simplified.first?.latitude, 47.0)
        XCTAssertEqual(simplified.last?.latitude, 47.0 + 49e-4)
    }

    func testSimplify_keepsACorner() {
        // An L-shape: north then east. The corner must survive.
        var pts = (0..<20).map { i in pt(47.0 + Double(i) * 1e-4, 7.0, 1000, Double(i), .aprs) }
        pts += (1..<20).map { i in pt(47.0 + 19e-4, 7.0 + Double(i) * 1e-4, 1000, Double(20 + i), .aprs) }
        let simplified = pts.simplifiedForDrawing(toleranceMeters: 25)
        XCTAssertTrue(simplified.count >= 3, "the corner is preserved, not collapsed")
        XCTAssertTrue(simplified.count < pts.count, "but it is still simplified")
        // The corner point (47.0+19e-4, 7.0) must be present.
        XCTAssertTrue(simplified.contains { abs($0.latitude - (47.0 + 19e-4)) < 1e-9 && abs($0.longitude - 7.0) < 1e-9 })
    }

    func testSimplify_smallTrackUntouched() {
        let two = [pt(47.0, 7.0, 1000, 0, .aprs), pt(47.001, 7.001, 1000, 1, .aprs)]
        XCTAssertEqual(two.simplifiedForDrawing().count, 2)
    }

    func testLegacyPointWithoutSourceDecodes() throws {
        // Tracks persisted before source tracking existed must still load.
        let legacy = #"{"latitude":47.5,"longitude":7.5,"altitude":1000,"timestamp":0,"verticalSpeed":-4,"horizontalSpeed":1}"#
        let p = try JSONDecoder().decode(BalloonTrackPoint.self, from: Data(legacy.utf8))
        XCTAssertNil(p.source, "absent source decodes as nil, not a crash")
        XCTAssertEqual(p.altitude, 1000)
    }

    func testSourceRoundTrips() throws {
        let p = pt(47.5, 7.5, 1000, 0, .aprs)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(BalloonTrackPoint.self, from: data)
        XCTAssertEqual(back.source, .aprs)
    }

    // MARK: - Round-trip gap fill on a real flight

    /// A real SondeHub flight at 1 sample / 30 s.
    private func flight(_ name: String) throws -> [BalloonTrackPoint] {
        struct Sample: Decodable { let t: Double; let lat: Double; let lon: Double; let alt: Double }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "fixture \(name).json missing")
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        return samples.map {
            BalloonTrackPoint(latitude: $0.lat, longitude: $0.lon, altitude: $0.alt,
                              timestamp: epoch.addingTimeInterval($0.t),
                              verticalSpeed: 0, horizontalSpeed: 0, source: .ble)
        }
    }

    /// Cut a consecutive slice out of a real track and let the inserter refill it
    /// from the full flight (as an APRS backfill would). The result must equal
    /// the original — every deleted point back, and not one duplicate of the
    /// points that were never missing.
    func testDeletedSliceIsRefilledExactly() throws {
        let full = try flight("W4214915")
        try XCTSkipIf(full.count < 40, "fixture too small")

        // Remove a consecutive middle slice.
        let lo = full.count / 3, hi = lo + full.count / 5
        var withGap = full
        withGap.removeSubrange(lo..<hi)
        XCTAssertEqual(withGap.count, full.count - (hi - lo))

        // The backfill offers the WHOLE flight (gap + the parts already present),
        // simulating SondeHub returning everything. Timestamps are shifted to
        // prove the merge keys on position, not time.
        let backfill = full.map {
            BalloonTrackPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude,
                              timestamp: $0.timestamp.addingTimeInterval(17),  // relay-latency skew
                              verticalSpeed: 0, horizontalSpeed: 0, source: .aprs)
        }

        let merged = withGap.mergingByPosition(backfill)

        // The deleted slice is back, and nothing already present was duplicated.
        // (The count equals the original because the removed slice is a distinct,
        // non-repeating segment; the merge drops the backfill's copies of every
        // position that survived in `withGap`.)
        XCTAssertEqual(merged.count, full.count,
                       "gap refilled, nothing already present duplicated (got \(merged.count), want \(full.count))")
        XCTAssertEqual(Set(merged.map { $0.positionKey }), Set(full.map { $0.positionKey }),
                       "same set of positions as the original")
        // Only the deleted slice was refilled, and it came from the APRS backfill.
        let filled = merged.filter { $0.source == .aprs }
        XCTAssertEqual(filled.count, hi - lo, "exactly the deleted slice was refilled from APRS")
    }

    func testNoGapMeansNoInsertions() throws {
        // Offering the whole flight again when nothing is missing must add nothing.
        let full = try flight("W4214915")
        let backfill = full.map {
            BalloonTrackPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude,
                              timestamp: $0.timestamp.addingTimeInterval(17),
                              verticalSpeed: 0, horizontalSpeed: 0, source: .aprs)
        }
        let merged = full.mergingByPosition(backfill)
        XCTAssertEqual(merged.count, full.count, "a complete track gains nothing from a re-offer")
    }

    // MARK: - Sizing the delta fetch

    /// "Nothing held" is expressed as `nil`, never as a sentinel Double. A sentinel
    /// invites a guard that fails to recognise it — `.greatestFiniteMagnitude`
    /// satisfies `isFinite`, so an `isFinite` check waves it through and any later
    /// `Int()` conversion traps.
    func testBucket_nothingHeld_isWholeFlight() {
        XCTAssertEqual(BalloonTrackService.sondeHubDurationBucket(covering: nil), "3d",
                       "an empty track must fetch the whole flight")
    }

    func testBucket_roundsUpToSondeHubsAllowedWindows() {
        // SondeHub accepts only these, so a delta must round up to one of them.
        XCTAssertEqual(BalloonTrackService.sondeHubDurationBucket(covering: 10), "15s")
        XCTAssertEqual(BalloonTrackService.sondeHubDurationBucket(covering: 15), "15s")
        XCTAssertEqual(BalloonTrackService.sondeHubDurationBucket(covering: 16), "1m")
        XCTAssertEqual(BalloonTrackService.sondeHubDurationBucket(covering: 90), "30m")
        XCTAssertEqual(BalloonTrackService.sondeHubDurationBucket(covering: 3600), "1h")
        XCTAssertEqual(BalloonTrackService.sondeHubDurationBucket(covering: 3601), "3h")
        XCTAssertEqual(BalloonTrackService.sondeHubDurationBucket(covering: 86_400), "1d")
    }

    /// Beyond SondeHub's retention there is nothing larger to ask for.
    func testBucket_beyondRetentionClampsToThreeDays() {
        XCTAssertEqual(BalloonTrackService.sondeHubDurationBucket(covering: 400_000), "3d")
        XCTAssertEqual(BalloonTrackService.sondeHubDurationBucket(covering: .greatestFiniteMagnitude), "3d",
                       "an absurd value must clamp, not trap")
    }

    // MARK: - The BLE hunt tail
    //
    // The only sonde data worth keeping on disk, because it is the only sonde data
    // SondeHub cannot return: the stretch from the last APRS fix to where the
    // balloon actually lies. See FSD *APRS Telemetry → The BLE hunt tail*.

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    /// A flight that APRS covered down to 400 m, after which only BLE heard it.
    private func flightWithBLETail() -> [BalloonTrackPoint] {
        let aprs = (0..<5).map { i in
            pt(47.70 + Double(i) * 1e-3, 7.50 + Double(i) * 1e-3, 2000 - Double(i) * 400,
               1000 + Double(i) * 10, .aprs)
        }
        let ble = (0..<4).map { i in
            pt(47.71 + Double(i) * 1e-4, 7.51 + Double(i) * 1e-4, 380 - Double(i) * 90,
               1050 + Double(i) * 10, .ble)
        }
        return aprs + ble
    }

    func testTail_keepsOnlyWhatFollowsTheLastAPRSFix() {
        let tail = HuntTail.from(track: flightWithBLETail(), serial: "W123", at: epoch)
        XCTAssertEqual(tail?.points.count, 4, "only the BLE stretch beyond APRS coverage is kept")
        XCTAssertEqual(tail?.points.first?.altitude, 380)
        XCTAssertTrue(tail?.points.allSatisfy { $0.source == .ble } ?? false,
                      "nothing APRS already holds belongs on disk")
    }

    /// Off-grid: no APRS at all, so the whole BLE track is the tail. The same rule
    /// covers this case with no special handling.
    func testTail_withNoAPRSAtAll_keepsTheWholeBLETrack() {
        let bleOnly = (0..<6).map { i in
            pt(47.70 + Double(i) * 1e-4, 7.50 + Double(i) * 1e-4, 500 - Double(i) * 80,
               1000 + Double(i) * 10, .ble)
        }
        let tail = HuntTail.from(track: bleOnly, serial: "W123", at: epoch)
        XCTAssertEqual(tail?.points.count, 6, "with no APRS coverage the whole BLE track is irreplaceable")
    }

    /// APRS heard it all the way down and BLE added nothing: there is nothing on
    /// this phone that SondeHub cannot return, so nothing is written.
    func testTail_whenAPRSCoveredEverything_isNil() {
        let aprsOnly = (0..<5).map { i in
            pt(47.70 + Double(i) * 1e-3, 7.50 + Double(i) * 1e-3, 2000 - Double(i) * 400,
               1000 + Double(i) * 10, .aprs)
        }
        XCTAssertNil(HuntTail.from(track: aprsOnly, serial: "W123", at: epoch),
                     "duplicating an authoritative source is not persistence")
    }

    func testTail_emptyTrackIsNil() {
        XCTAssertNil(HuntTail.from(track: [], serial: "W123", at: epoch))
    }

    /// During flight the receiver and the network both feed the track, so BLE points
    /// exist *before* the last APRS fix too. Those are not irreplaceable — SondeHub
    /// holds that stretch — so keeping every BLE point would persist most of the
    /// flight and duplicate an authoritative source. Only the BLE that follows the
    /// final APRS fix is the hunt tail.
    func testTail_excludesBLEHeardBeforeTheLastAPRSFix() {
        let track = [
            pt(47.700, 7.500, 2000, 1000, .ble),   // in flight, APRS has this too
            pt(47.701, 7.501, 1600, 1010, .aprs),
            pt(47.702, 7.502, 1200, 1020, .ble),   // still in APRS coverage
            pt(47.703, 7.503,  800, 1030, .aprs),  // ← last APRS fix
            pt(47.704, 7.504,  400, 1040, .ble),   // the hunt tail starts here
            pt(47.705, 7.505,  100, 1050, .ble),
        ]
        let tail = HuntTail.from(track: track, serial: "W123", at: epoch)
        XCTAssertEqual(tail?.points.count, 2,
                       "only the BLE beyond the final APRS fix is irreplaceable")
        XCTAssertEqual(tail?.points.first?.altitude, 400,
                       "the tail begins at the first BLE point after APRS coverage ends")
    }

    // MARK: - Restoring a tail: it must prove it belongs

    func testTail_restoresForItsOwnSerial() {
        let tail = HuntTail.from(track: flightWithBLETail(), serial: "W123", at: epoch)!
        let restored = tail.points(for: "W123", now: epoch.addingTimeInterval(3600))
        XCTAssertEqual(restored.count, 4)
    }

    /// The serial is stored *with* the points precisely so this can be checked.
    /// A tail belonging to another sonde is not the hunted sonde's data.
    func testTail_refusesADifferentSerial() {
        let tail = HuntTail.from(track: flightWithBLETail(), serial: "W123", at: epoch)!
        XCTAssertTrue(tail.points(for: "W999", now: epoch.addingTimeInterval(3600)).isEmpty,
                      "a tail must never be served for a sonde it does not belong to")
    }

    /// A hunt does not outlive a day.
    func testTail_expiresAfter24Hours() {
        let tail = HuntTail.from(track: flightWithBLETail(), serial: "W123", at: epoch)!
        XCTAssertFalse(tail.points(for: "W123", now: epoch.addingTimeInterval(24 * 3600)).isEmpty,
                       "exactly 24 h is still within retention")
        XCTAssertTrue(tail.points(for: "W123", now: epoch.addingTimeInterval(24 * 3600 + 1)).isEmpty,
                      "past 24 h the tail is stale and must not be restored")
    }

    /// Persistence exists to survive backgrounding, so a tail must round-trip.
    func testTail_roundTripsThroughJSON() throws {
        let tail = HuntTail.from(track: flightWithBLETail(), serial: "W123", at: epoch)!
        let back = try JSONDecoder().decode(HuntTail.self, from: JSONEncoder().encode(tail))
        XCTAssertEqual(back.serial, "W123")
        XCTAssertEqual(back.points.count, 4)
        XCTAssertEqual(back.points.map { $0.positionKey }, tail.points.map { $0.positionKey })
    }
}
