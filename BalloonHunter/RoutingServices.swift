import Foundation
import Combine
import MapKit
import OSLog

// MARK: - Route Calculation Service

// MARK: - Routing Cache (co-located with RouteCalculationService)

actor RoutingCache {
    private struct RoutingCacheEntry: Sendable {
        let data: RouteData
        let timestamp: Date
        let version: Int
        let accessCount: Int

        init(data: RouteData, version: Int, timestamp: Date = Date(), accessCount: Int = 1) {
            self.data = data
            self.timestamp = timestamp
            self.version = version
            self.accessCount = accessCount
        }

        func accessed() -> RoutingCacheEntry {
            RoutingCacheEntry(data: data, version: version, timestamp: timestamp, accessCount: accessCount + 1)
        }
    }

    private struct RoutingCacheMetrics: Sendable {
        var hits: Int = 0
        var misses: Int = 0
        var evictions: Int = 0
        var expirations: Int = 0

        var hitRate: Double {
            let total = hits + misses
            return total > 0 ? Double(hits) / Double(total) : 0.0
        }
    }

    private var cache: [String: RoutingCacheEntry] = [:]
    private let ttl: TimeInterval
    private let capacity: Int
    private var lru: [String] = []
    private var metrics = RoutingCacheMetrics()

    init(ttl: TimeInterval = 300, capacity: Int = 100) {
        self.ttl = ttl
        self.capacity = capacity
    }

    func get(key: String) -> RouteData? {
        cleanExpiredEntries()
        guard let entry = cache[key] else {
            metrics.misses += 1
            // Cache miss - will calculate route
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

        cache[key] = entry.accessed()

        // Update LRU: move to front
        lru.removeAll(where: { $0 == key })
        lru.insert(key, at: 0)

        metrics.hits += 1
        appLog("RoutingCache: Hit for key \(key) (v\(entry.version), accessed \(entry.accessCount + 1) times)", category: .cache, level: .debug)
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

        let entry = RoutingCacheEntry(data: value, version: version, timestamp: Date())
        cache[key] = entry

        // Update LRU
        lru.removeAll(where: { $0 == key })
        lru.insert(key, at: 0)

        // Route cached successfully
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
            appLog("RoutingCache: Cleaned \(expiredKeys.count) expired entries", category: .cache, level: .debug)
        }
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
}

final class RouteCalculationService: ObservableObject {
    @Published var currentRoute: RouteData?
    @Published var isCalculatingRoute: Bool = false
    @Published var transportMode: TransportationMode = .car

    private let currentLocationService: CurrentLocationService
    private var lastDestination: CLLocationCoordinate2D?
    private var appSettings: AppSettings?

    init(currentLocationService: CurrentLocationService) {
        self.currentLocationService = currentLocationService
    }

    /// Set AppSettings reference for transport mode persistence
    func setAppSettings(_ settings: AppSettings) {
        appSettings = settings
        transportMode = settings.transportMode
    }

    /// Set transport mode and automatically recalculate current route
    func setTransportMode(_ mode: TransportationMode) {
        appLog("RouteCalculationService: Transport mode changed to \(mode)", category: .service, level: .info)
        transportMode = mode

        // Save to AppSettings
        appSettings?.transportMode = mode

        // Recalculate current route with new transport mode
        if let destination = lastDestination,
           let userLocation = currentLocationService.locationData {
            appLog("RouteCalculationService: Recalculating route with new transport mode", category: .service, level: .info)
            calculateAndPublishRoute(from: userLocation, to: destination, transportMode: mode)
        }
    }

    /// Calculate and publish route - called by state machine
    func calculateAndPublishRoute(from userLocation: LocationData, to destination: CLLocationCoordinate2D, transportMode: TransportationMode? = nil) {
        // Store destination for transport mode changes
        lastDestination = destination

        // Use provided transport mode or service's current mode
        let effectiveTransportMode = transportMode ?? self.transportMode

        Task { @MainActor in
            isCalculatingRoute = true
            do {
                let route = try await calculateRoute(from: userLocation, to: destination, transportMode: effectiveTransportMode)
                currentRoute = route
            } catch {
                appLog("RouteCalculationService: Failed to calculate route: \(error.localizedDescription)", category: .service, level: .info)
                currentRoute = nil
            }
            isCalculatingRoute = false
        }
    }
    
    func calculateRoute(from userLocation: LocationData, to destination: CLLocationCoordinate2D, transportMode: TransportationMode) async throws -> RouteData {
        // Calculate route from user to destination

        // Helper to build a request for a given transport type
        func makeRequest(_ type: MKDirectionsTransportType, to dest: CLLocationCoordinate2D) -> MKDirections.Request {
            let req = MKDirections.Request()
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)))
            req.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
            req.transportType = type
            req.requestsAlternateRoutes = true
            return req
        }

        // Try preferred mode first
        // Prefer dedicated cycling directions when requested and the OS supports it.
        let preferredType: MKDirectionsTransportType
            if transportMode == .car {
                preferredType = .automobile
            } else if #available(iOS 17.0, *) {
                preferredType = .cycling
            } else {
                preferredType = .walking // Fallback when cycling directions are not available
            }
        do {
            let response = try await MKDirections(request: makeRequest(preferredType, to: destination)).calculate()
            if let route = response.routes.first {
                let adjusted = transportMode == .bike ? route.expectedTravelTime * 0.7 : route.expectedTravelTime
                return RouteData(
                    coordinates: extractCoordinates(from: route.polyline),
                    distance: route.distance,
                    expectedTravelTime: adjusted,
                    transportType: transportMode
                )
            }
            throw RouteError.noRouteFound
        } catch {
            // If directions not available, try shifting destination by 500m in random directions
            if let nserr = error as NSError?, nserr.domain == MKErrorDomain && nserr.code == 2 {
                let maxAttempts = 10
                for attempt in 1...maxAttempts {
                    let bearing = Double.random(in: 0..<(2 * .pi))
                    let shifted = offsetCoordinate(origin: destination, distanceMeters: 500, bearingRadians: bearing)
                    appLog(String(format: "RouteCalculationService: Attempt %d — shifted destination to (%.5f,%.5f) bearing=%.0f°",
                                  attempt, shifted.latitude, shifted.longitude, bearing * 180 / .pi),
                           category: .service, level: .debug)
                    do {
                        let response = try await MKDirections(request: makeRequest(preferredType, to: shifted)).calculate()
                        if let route = response.routes.first {
                            let adjusted = transportMode == .bike ? route.expectedTravelTime * 0.7 : route.expectedTravelTime
                            return RouteData(
                                coordinates: extractCoordinates(from: route.polyline),
                                distance: route.distance,
                                expectedTravelTime: adjusted,
                                transportType: transportMode
                            )
                        }
                    } catch {
                        // Keep trying other random shifts on directionsNotAvailable; bail on other errors
                        if let e = error as NSError?, !(e.domain == MKErrorDomain && e.code == 2) {
                            appLog("RouteCalculationService: Shift attempt failed with non-DNA error: \(error.localizedDescription)", category: .service, level: .debug)
                            break
                        }
                    }
                }
                
                // Expanded destination search (no transport type switching)
                let searchRadii: [Double] = [300, 600, 1200] // meters
                let bearingsDeg: [Double] = stride(from: 0.0, to: 360.0, by: 45.0).map { $0 }
                searchLoop: for r in searchRadii {
                    for deg in bearingsDeg {
                        let shifted = offsetCoordinate(origin: destination, distanceMeters: r, bearingRadians: deg * .pi / 180)
                        appLog(String(format: "RouteCalculationService: Radial search r=%.0fm bearing=%.0f° -> (%.5f,%.5f)", r, deg, shifted.latitude, shifted.longitude), category: .service, level: .debug)
                        do {
                            let response = try await MKDirections(request: makeRequest(preferredType, to: shifted)).calculate()
                            if let route = response.routes.first {
                                let adjusted = transportMode == .bike ? route.expectedTravelTime * 0.7 : route.expectedTravelTime
                                return RouteData(
                                    coordinates: extractCoordinates(from: route.polyline),
                                    distance: route.distance,
                                    expectedTravelTime: adjusted,
                                    transportType: transportMode
                                )
                            }
                        } catch {
                            if let e = error as NSError?, !(e.domain == MKErrorDomain && e.code == 2) {
                                appLog("RouteCalculationService: Radial search failed with non-DNA error: \(error.localizedDescription)", category: .service, level: .debug)
                                break searchLoop
                            }
                        }
                    }
                }
                // (fallback to straight-line handled below)
                // Final fallback: straight-line polyline with heuristic ETA
                let coords = [
                    CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
                    destination
                ]
                let distance = CLLocation(latitude: coords[0].latitude, longitude: coords[0].longitude)
                    .distance(from: CLLocation(latitude: coords[1].latitude, longitude: coords[1].longitude))
                // Heuristic speeds (m/s)
                let speed: Double = (transportMode == .car) ? 22.0 : 4.2 // ~79 km/h car, ~15 km/h bike
                let eta = distance / speed
                appLog(String(format: "RouteCalculationService: Directions not available — using straight-line fallback (dist=%.1f km, eta=%d min)", distance/1000.0, Int(eta/60)), category: .service, level: .info)
                return RouteData(coordinates: coords, distance: distance, expectedTravelTime: eta, transportType: transportMode)
            } else {
                // Propagate other errors
                throw error
            }
        }
    }

    private func offsetCoordinate(origin: CLLocationCoordinate2D, distanceMeters: Double, bearingRadians: Double) -> CLLocationCoordinate2D {
        let R = 6_371_000.0 // meters
        let δ = distanceMeters / R
        let θ = bearingRadians
        let φ1 = origin.latitude * .pi / 180
        let λ1 = origin.longitude * .pi / 180
        let sinφ1 = sin(φ1), cosφ1 = cos(φ1)
        let sinδ = sin(δ), cosδ = cos(δ)

        let sinφ2 = sinφ1 * cosδ + cosφ1 * sinδ * cos(θ)
        let φ2 = asin(sinφ2)
        let y = sin(θ) * sinδ * cosφ1
        let x = cosδ - sinφ1 * sinφ2
        let λ2 = λ1 + atan2(y, x)

        var lon = λ2 * 180 / .pi
        // Normalize lon to [-180, 180]
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        let lat = φ2 * 180 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    
    private func extractCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let coordinateCount = polyline.pointCount
        let coordinates = UnsafeMutablePointer<CLLocationCoordinate2D>.allocate(capacity: coordinateCount)
        defer { coordinates.deallocate() }
        
        polyline.getCoordinates(coordinates, range: NSRange(location: 0, length: coordinateCount))
        
        return Array(UnsafeBufferPointer(start: coordinates, count: coordinateCount))
    }
}
