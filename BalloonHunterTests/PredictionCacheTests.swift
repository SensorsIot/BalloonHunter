import XCTest
import CoreLocation
@testable import BalloonHunter

@MainActor
final class PredictionCacheTests: XCTestCase {
    func testSetGetAndMetrics() async throws {
        let cache = PredictionCache(ttl: 5.0, capacity: 10)
        let sample = PredictionData(
            path: [CLLocationCoordinate2D(latitude: 1.0, longitude: 2.0)],
            burstPoint: nil,
            landingPoint: nil,
            landingTime: nil,
            launchPoint: nil,
            burstAltitude: nil,
            flightTime: nil,
            metadata: nil
        )

        await cache.set(key: "a", value: sample)
        let got = await cache.get(key: "a")
        XCTAssertNotNil(got)

        let metrics = await cache.getMetrics()
        let hits = metrics.hits
        let misses = metrics.misses
        XCTAssertEqual(hits, 1)
        XCTAssertEqual(misses, 0)
    }

    func testExpiration() async throws {
        let cache = PredictionCache(ttl: 0.2, capacity: 10)
        let sample = PredictionData(path: nil, burstPoint: nil, landingPoint: nil, landingTime: nil, launchPoint: nil, burstAltitude: nil, flightTime: nil, metadata: nil)
        await cache.set(key: "k", value: sample)

        // Before TTL
        let before = await cache.get(key: "k")
        XCTAssertNotNil(before)

        // After TTL
        try await Task.sleep(nanoseconds: 300_000_000) // 300ms
        let expired = await cache.get(key: "k")
        XCTAssertNil(expired)

        let metrics = await cache.getMetrics()
        let expirations = metrics.expirations
        let misses = metrics.misses
        XCTAssertGreaterThanOrEqual(expirations, 1)
        XCTAssertGreaterThanOrEqual(misses, 1)
    }

    func testLRUEviction() async throws {
        let cache = PredictionCache(ttl: 5.0, capacity: 2)
        let a = PredictionData(path: nil, burstPoint: nil, landingPoint: nil, landingTime: nil, launchPoint: nil, burstAltitude: nil, flightTime: nil, metadata: nil)
        let b = a
        let c = a

        await cache.set(key: "a", value: a)
        await cache.set(key: "b", value: b)

        // Access "a" to make it MRU; "b" becomes LRU
        _ = await cache.get(key: "a")

        // Inserting "c" should evict LRU ("b")
        await cache.set(key: "c", value: c)

        let shouldBeNil = await cache.get(key: "b")
        let shouldExistA = await cache.get(key: "a")
        let shouldExistC = await cache.get(key: "c")

        XCTAssertNil(shouldBeNil)
        XCTAssertNotNil(shouldExistA)
        XCTAssertNotNil(shouldExistC)
    }
}
