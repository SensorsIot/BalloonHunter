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
}
