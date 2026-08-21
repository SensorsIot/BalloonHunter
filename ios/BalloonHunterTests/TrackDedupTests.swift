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
}
