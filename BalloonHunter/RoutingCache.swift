import Foundation
import CoreLocation
import OSLog

actor RoutingCache {
    private var cache: [String: (RouteData, Date)] = [:]
    private let ttl: TimeInterval // Time-to-live for cache entries
    private let capacity: Int // Maximum number of entries
    private var lru: [String] = [] // Least Recently Used keys

    init(ttl: TimeInterval = 300, capacity: Int = 100) { // Default TTL 5 minutes, capacity 100
        self.ttl = ttl
        self.capacity = capacity
    }

    func get(key: String) -> RouteData? {
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

    func set(key: String, value: RouteData) {
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
    static func makeKey(userCoordinate: CLLocationCoordinate2D, balloonCoordinate: CLLocationCoordinate2D, mode: TransportationMode) -> String {
        let userLat = String(format: "%.2f", userCoordinate.latitude)
        let userLon = String(format: "%.2f", userCoordinate.longitude)
        let balloonLat = String(format: "%.2f", balloonCoordinate.latitude)
        let balloonLon = String(format: "%.2f", balloonCoordinate.longitude)
        return "user_\(userLat)_\(userLon)-balloon_\(balloonLat)_\(balloonLon)-mode_\(mode)"
    }
}
