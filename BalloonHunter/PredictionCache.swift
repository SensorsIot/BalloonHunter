import Foundation
import CoreLocation
import OSLog

struct CacheEntry<T>: Sendable where T: Sendable {
    let data: T
    let timestamp: Date
    let version: Int
    let accessCount: Int
    
    init(data: T, version: Int, timestamp: Date = Date()) {
        self.data = data
        self.timestamp = timestamp
        self.version = version
        self.accessCount = 1
    }
    
    private init(data: T, timestamp: Date, version: Int, accessCount: Int) {
        self.data = data
        self.timestamp = timestamp
        self.version = version
        self.accessCount = accessCount
    }
    
    nonisolated func accessed() -> CacheEntry<T> {
        return CacheEntry(data: data, timestamp: timestamp, version: version, accessCount: accessCount + 1)
    }
}

struct CacheMetrics: Sendable {
    var hits: Int = 0
    var misses: Int = 0
    var evictions: Int = 0
    var expirations: Int = 0
    
    var hitRate: Double {
        let total = hits + misses
        return total > 0 ? Double(hits) / Double(total) : 0.0
    }
}

actor PredictionCache {
    private var cache: [String: CacheEntry<PredictionData>] = [:]
    private let ttl: TimeInterval
    private let capacity: Int
    private var lru: [String] = []
    private var metrics: CacheMetrics

    init(ttl: TimeInterval = 300, capacity: Int = 100) {
        self.ttl = ttl
        self.capacity = capacity
        self.metrics = CacheMetrics(hits: 0, misses: 0, evictions: 0, expirations: 0)
    }

    func get(key: String) -> PredictionData? {
        cleanExpiredEntries()
        guard let entry = cache[key] else {
            metrics.misses += 1
            appLog("PredictionCache: Miss for key \(key)", category: .cache, level: .debug)
            return nil
        }
        
        if Date.now.timeIntervalSince(entry.timestamp) > ttl {
            cache.removeValue(forKey: key)
            lru.removeAll(where: { $0 == key })
            metrics.expirations += 1
            metrics.misses += 1
            appLog("PredictionCache: Expired entry for key \(key)", category: .cache, level: .debug)
            return nil
        }
        
        // Extract data before updating entry to avoid MainActor issues
        let data = entry.data
        
        // Update entry with access count
        cache[key] = entry.accessed()
        
        // Update LRU: move to front
        lru.removeAll(where: { $0 == key })
        lru.insert(key, at: 0)
        
        metrics.hits += 1
        appLog("PredictionCache: Hit for key \(key) (v\(entry.version), accessed \(entry.accessCount + 1) times)", 
               category: .cache, level: .debug)
        return data
    }

    func set(key: String, value: PredictionData, version: Int = 0) {
        cleanExpiredEntries()
        
        // Check if we need to evict entries
        if cache.count >= capacity && cache[key] == nil {
            // Evict LRU entry
            if let lruKey = lru.popLast() {
                cache.removeValue(forKey: lruKey)
                metrics.evictions += 1
                appLog("PredictionCache: Evicted LRU entry \(lruKey)", category: .cache, level: .debug)
            }
        }
        
        let entry = CacheEntry(data: value, version: version, timestamp: Date())
        cache[key] = entry
        
        // Update LRU
        lru.removeAll(where: { $0 == key })
        lru.insert(key, at: 0)
        
        appLog("PredictionCache: Set key \(key) with version \(version)", category: .cache, level: .debug)
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
            appLog("PredictionCache: Cleaned \(expiredKeys.count) expired entries", 
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
        appLog("PredictionCache: Cleared all entries", category: .cache, level: .info)
    }
    
    func getStats() -> [String: Any] {
        let now = Date.now
        let validEntries = cache.values.filter { now.timeIntervalSince($0.timestamp) <= ttl }
        let avgAge = validEntries.isEmpty ? 0 : validEntries.map { now.timeIntervalSince($0.timestamp) }.reduce(0, +) / Double(validEntries.count)
        
        return [
            "totalEntries": cache.count,
            "validEntries": validEntries.count,
            "hitRate": metrics.hitRate,
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
    static func makeKey(balloonID: String, coordinate: CLLocationCoordinate2D, altitude: Double, timeBucket: Date) -> String {
        let lat = String(format: "%.2f", coordinate.latitude)
        let lon = String(format: "%.2f", coordinate.longitude)
        let alt = String(format: "%.0f", altitude)
        let time = String(format: "%.0f", timeBucket.timeIntervalSince1970 / 300) // 5-minute buckets
        return "\(balloonID)-\(lat)-\(lon)-\(alt)-\(time)"
    }
}
