import Foundation
import CoreLocation
import OSLog

actor RoutingCache {
    private var cache: [String: CacheEntry<RouteData>] = [:]
    private let ttl: TimeInterval
    private let capacity: Int
    private var lru: [String] = []
    private var metrics = CacheMetrics(hits: 0, misses: 0, evictions: 0, expirations: 0)

    init(ttl: TimeInterval = 300, capacity: Int = 100) {
        self.ttl = ttl
        self.capacity = capacity
    }

    func get(key: String) -> RouteData? {
        cleanExpiredEntries()
        guard let entry = cache[key] else {
            metrics.misses += 1
            appLog("RoutingCache: Miss for key \(key)", category: .cache, level: .debug)
            return nil
        }
        
        if Date.now.timeIntervalSince(entry.timestamp) > ttl {
            cache.removeValue(forKey: key)
            lru.removeAll(where: { $0 == key })
            metrics.expirations += 1
            metrics.misses += 1
            appLog("RoutingCache: Expired entry for key \(key)", category: .cache, level: .debug)
            return nil
        }
        
        let accessedEntry = entry.accessed()
        cache[key] = accessedEntry
        
        // Update LRU: move to front
        lru.removeAll(where: { $0 == key })
        lru.insert(key, at: 0)
        
        metrics.hits += 1
        appLog("RoutingCache: Hit for key \(key) (v\(entry.version), accessed \(entry.accessCount + 1) times)", 
               category: .cache, level: .debug)
        // TODO: Fix actor isolation for entry.data access
        return entry.data
    }

    func set(key: String, value: RouteData, version: Int = 0) {
        cleanExpiredEntries()
        
        // Check if we need to evict entries
        if cache.count >= capacity && cache[key] == nil {
            // Evict LRU entry
            if let lruKey = lru.popLast() {
                cache.removeValue(forKey: lruKey)
                metrics.evictions += 1
                appLog("RoutingCache: Evicted LRU entry \(lruKey)", category: .cache, level: .debug)
            }
        }
        
        let entry = CacheEntry(data: value, version: version)
        cache[key] = entry
        
        // Update LRU
        lru.removeAll(where: { $0 == key })
        lru.insert(key, at: 0)
        
        appLog("RoutingCache: Set key \(key) with version \(version)", category: .cache, level: .debug)
    }

    private func cleanExpiredEntries() {
        let now = Date.now
        let expiredKeys = cache.compactMap { (key, entry) in
            now.timeIntervalSince(entry.timestamp) > ttl ? key : nil
        }
        
        for key in expiredKeys {
            cache.removeValue(forKey: key)
            lru.removeAll(where: { $0 == key })
            metrics.expirations += 1
        }
        
        if !expiredKeys.isEmpty {
            appLog("RoutingCache: Cleaned \(expiredKeys.count) expired entries", 
                   category: .cache, level: .debug)
        }
    }

    func getMetrics() -> CacheMetrics {
        return metrics
    }
    
    func clear() {
        cache.removeAll()
        lru.removeAll()
        metrics = CacheMetrics(hits: 0, misses: 0, evictions: 0, expirations: 0)
        appLog("RoutingCache: Cleared all entries", category: .cache, level: .info)
    }
    
    func getStats() -> [String: Any] {
        let now = Date.now
        let validEntries = cache.values.filter { now.timeIntervalSince($0.timestamp) <= ttl }
        let avgAge = validEntries.isEmpty ? 0 : validEntries.map { now.timeIntervalSince($0.timestamp) }.reduce(0, +) / Double(validEntries.count)
        
        let total = metrics.hits + metrics.misses
        let hitRate = total > 0 ? Double(metrics.hits) / Double(total) : 0.0
        
        return [
            "totalEntries": cache.count,
            "validEntries": validEntries.count,
            "hitRate": hitRate,
            "hits": metrics.hits,
            "misses": metrics.misses,
            "evictions": metrics.evictions,
            "expirations": metrics.expirations,
            "averageAge": avgAge,
            "capacity": capacity,
            "ttl": ttl
        ]
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
