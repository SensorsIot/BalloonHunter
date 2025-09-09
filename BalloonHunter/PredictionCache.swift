import Foundation
import CoreLocation
import OSLog

actor PredictionCache {
    private var cache: [String: (PredictionData, Date)] = [:]
    private let ttl: TimeInterval // Time-to-live for cache entries
    private let capacity: Int // Maximum number of entries
    private var lru: [String] = [] // Least Recently Used keys

    init(ttl: TimeInterval = 300, capacity: Int = 100) { // Default TTL 5 minutes, capacity 100
        self.ttl = ttl
        self.capacity = capacity
    }

    func get(key: String) -> PredictionData? {
        cleanExpiredEntries()
        guard let (data, timestamp) = cache[key] else {
            appLog("Cache miss for key: \(key)", category: .cache, level: .debug)
            return nil
        }
        if Date().timeIntervalSince(timestamp) > ttl {
            appLog("Cache entry expired for key: \(key)", category: .cache, level: .debug)
            cache.removeValue(forKey: key)
            lru.removeAll(where: { $0 == key })
            return nil
        }
        appLog("Cache hit for key: \(key)", category: .cache, level: .debug)
        // Update LRU: move to front
        lru.removeAll(where: { $0 == key })
        lru.insert(key, at: 0)
        return data
    }

    func set(key: String, value: PredictionData) {
        cleanExpiredEntries()
        if cache.count >= capacity {
            // Evict LRU entry
            if let lruKey = lru.popLast() {
                cache.removeValue(forKey: lruKey)
            }
        }
        cache[key] = (value, Date())
        lru.removeAll(where: { $0 == key })
        lru.insert(key, at: 0)
    }

    private func cleanExpiredEntries() {
        let now = Date()
        for (key, (_, timestamp)) in cache {
            if now.timeIntervalSince(timestamp) > ttl {
                cache.removeValue(forKey: key)
                lru.removeAll(where: { $0 == key })
            }
        }
    }

    // Helper to create quantized key
    static func makeKey(balloonID: String, coordinate: CLLocationCoordinate2D, altitude: Double, timeBucket: Date) -> String {
        let lat = String(format: "%.2f", coordinate.latitude)
        let lon = String(format: "%.2f", coordinate.longitude)
        let alt = String(format: "%.0f", altitude)
        let time = String(format: "%.0f", timeBucket.timeIntervalSince1970 / 300) // 5-minute buckets
        return "\(balloonID)-\(lat)-\(lon)-\(alt)-\(time)"
    }
}
