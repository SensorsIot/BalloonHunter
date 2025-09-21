import Foundation
import Combine
import CoreLocation
import OSLog

// MARK: - Prediction Cache (co-located with PredictionService)

private struct PredictionCacheEntry: Sendable {
    let data: PredictionData
    let timestamp: Date
    let version: Int
    let accessCount: Int

    nonisolated init(data: PredictionData, version: Int, timestamp: Date = Date(), accessCount: Int = 1) {
        self.data = data
        self.timestamp = timestamp
        self.version = version
        self.accessCount = accessCount
    }

    nonisolated func accessed() -> PredictionCacheEntry {
        PredictionCacheEntry(data: data, version: version, timestamp: timestamp, accessCount: accessCount + 1)
    }
}

private struct PredictionCacheMetrics: Sendable {
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
    private var cache: [String: PredictionCacheEntry] = [:]
    private let ttl: TimeInterval
    private let capacity: Int
    private var lru: [String] = []
    private var metrics: PredictionCacheMetrics

    init(ttl: TimeInterval = 300, capacity: Int = 100) {
        self.ttl = ttl
        self.capacity = capacity
        self.metrics = PredictionCacheMetrics(hits: 0, misses: 0, evictions: 0, expirations: 0)
    }

    func get(key: String) -> PredictionData? {
        cleanExpiredEntries()
        guard let entry = cache[key] else {
            metrics.misses += 1
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

        // Update entry with access count
        cache[key] = entry.accessed()

        // Update LRU: move to front
        lru.removeAll(where: { $0 == key })
        lru.insert(key, at: 0)

        metrics.hits += 1
        appLog("PredictionCache: Hit for key \(key) (v\(entry.version), accessed \(entry.accessCount + 1) times)", category: .cache, level: .debug)
        return entry.data
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

        let entry = PredictionCacheEntry(
            data: value,
            version: version,
            timestamp: Date(),
            accessCount: 1
        )
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
            appLog("PredictionCache: Cleaned \(expiredKeys.count) expired entries", category: .cache, level: .debug)
        }
    }

    func getMetrics() -> [String: Any] {
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
    static func makeKey(balloonID: String, coordinate: CLLocationCoordinate2D, altitude: Double, timeBucket: Date) -> String {
        let lat = String(format: "%.2f", coordinate.latitude)
        let lon = String(format: "%.2f", coordinate.longitude)
        let alt = String(format: "%.0f", altitude)
        let time = String(format: "%.0f", timeBucket.timeIntervalSince1970 / 300) // 5-minute buckets
        return "\(balloonID)-\(lat)-\(lon)-\(alt)-\(time)"
    }
}

// MARK: - Prediction Service

@MainActor
final class PredictionService: ObservableObject {
    // MARK: - API Dependencies
    private let session: URLSession
    private var serviceHealth: ServiceHealth = .healthy
    
    // MARK: - Scheduling Dependencies  
    private let predictionCache: PredictionCache
    private weak var serviceCoordinator: ServiceCoordinator?
    private let userSettings: UserSettings
    private let balloonTrackService: BalloonTrackService?
    
    // MARK: - Published State
    var isRunning: Bool = false
    var hasValidPrediction: Bool = false
    private var lastPredictionTime: Date?
    var predictionStatus: String = "Not started"
    @Published var latestPrediction: PredictionData?
    
    // Time calculations (moved from DataPanelView for proper separation of concerns)
    @Published var predictedLandingTimeString: String = "--:--"
    @Published var remainingFlightTimeString: String = "--:--"
    
    // MARK: - Private State
    private var internalTimer: Timer?
    private let predictionInterval: TimeInterval = 60.0
    private var lastProcessedTelemetry: TelemetryData?
    private var apiCallCount: Int = 0
    private let isoWithFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoNoFrac = ISO8601DateFormatter()

    // MARK: - Simplified Constructor (API-only mode)
    init() {
        // Initialize API session only
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        self.session = URLSession(configuration: config)
        
        // Initialize scheduling dependencies as nil (API-only mode)
        self.predictionCache = PredictionCache() // Default cache
        self.serviceCoordinator = nil
        self.userSettings = UserSettings() // Default settings
        // API-only mode - no service dependencies needed for predictions
        self.balloonTrackService = nil // Not needed for API-only predictions
        
        // PredictionService initialized in API-only mode
        publishHealthEvent(.healthy, message: "Prediction service initialized (API-only)")
    }
    
    // MARK: - Full Constructor (with scheduling)
    init(
        predictionCache: PredictionCache,
        serviceCoordinator: ServiceCoordinator,
        userSettings: UserSettings,
        balloonTrackService: BalloonTrackService
    ) {
        // Initialize API session
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        self.session = URLSession(configuration: config)
        
        // Initialize scheduling dependencies
        self.predictionCache = predictionCache
        self.serviceCoordinator = serviceCoordinator
        self.userSettings = userSettings
        self.balloonTrackService = balloonTrackService
        
        // PredictionService initialized with scheduling
        publishHealthEvent(.healthy, message: "Prediction service initialized")
    }
    
    // MARK: - Service Lifecycle
    
    func startAutomaticPredictions() {
        guard !isRunning else {
            appLog("PredictionService: Already running automatic predictions", category: .service, level: .debug)
            return
        }
        
        isRunning = true
        predictionStatus = "Running (timer by coordinator)"
        appLog("PredictionService: Running; coordinator owns 60s timer", category: .service, level: .info)
    }
    
    func stopAutomaticPredictions() {
        isRunning = false
        stopInternalTimer()
        predictionStatus = "Stopped"
        
        appLog("PredictionService: Stopped automatic predictions", category: .service, level: .info)
    }
    
    // MARK: - Manual Prediction Triggers
    
    func triggerManualPrediction() async {
        guard let serviceCoordinator = serviceCoordinator,
              let telemetry = serviceCoordinator.balloonTelemetry else {
            appLog("PredictionService: Manual trigger ignored - no telemetry available", category: .service, level: .debug)
            return
        }
        
        appLog("PredictionService: Manual trigger - performing prediction", category: .service, level: .info)
        await performPrediction(telemetry: telemetry, trigger: "manual")
    }
    
    func triggerStartupPrediction() async {
        guard let serviceCoordinator = serviceCoordinator,
              let telemetry = serviceCoordinator.balloonTelemetry else {
            return
        }
        
        appLog("PredictionService: Startup trigger - first telemetry received", category: .service, level: .info)
        await performPrediction(telemetry: telemetry, trigger: "startup")
    }
    
    // MARK: - Private Timer Implementation (disabled; coordinator owns timer)
    private func startInternalTimer() { /* no-op: coordinator manages timer */ }
    private func stopInternalTimer() { internalTimer?.invalidate(); internalTimer = nil }
    private func handleTimerTrigger() async { /* no-op */ }
    
    // MARK: - Core Prediction Logic
    
    private func performPrediction(telemetry: TelemetryData, trigger: String) async {
        predictionStatus = "Processing prediction..."
        
        // Dev sondes are processed normally; CSV filtering handled elsewhere

        do {
            let sinceLast = lastPredictionTime.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "N/A"
            appLog("PredictionService: performPrediction start (trigger=\(trigger), sinceLast=\(sinceLast)s)", category: .service, level: .debug)
            // Determine if balloon is descending
            let balloonDescends = telemetry.verticalSpeed < 0
            appLog("PredictionService: Balloon descending: \(balloonDescends) (verticalSpeed: \(telemetry.verticalSpeed) m/s)", category: .service, level: .info)
            
            // Calculate effective descent rate
            let effectiveDescentRate = calculateEffectiveDescentRate(telemetry: telemetry)
            
            // Create cache key
            let cacheKey = createCacheKey(telemetry)
            appLog("PredictionService: Trigger=\(trigger) cacheKey=\(cacheKey)", category: .service, level: .debug)
            
            // Check cache first
            if let cachedPrediction = await predictionCache.get(key: cacheKey) {
                appLog("PredictionService: Using cached prediction", category: .service, level: .info)
                await handlePredictionResult(cachedPrediction, trigger: trigger)
                return
            }
            
            // Cache miss -> Call API
            apiCallCount += 1
            appLog("PredictionService: API call #\(apiCallCount) (trigger=\(trigger), key=\(cacheKey))", category: .service, level: .debug)
            let predictionData = try await fetchPrediction(
                telemetry: telemetry,
                userSettings: userSettings,
                measuredDescentRate: effectiveDescentRate,
                cacheKey: cacheKey,
                balloonDescends: balloonDescends
            )
            
            // Cache the result
            await predictionCache.set(key: cacheKey, value: predictionData)
            
            // Handle successful prediction
            await handlePredictionResult(predictionData, trigger: trigger)
            
        } catch {
            hasValidPrediction = false
            let msg: String
            if let perr = error as? PredictionError {
                switch perr {
                case .invalidRequest: msg = "Invalid request"
                case .invalidResponse: msg = "Invalid response"
                case .httpError(let code): msg = "HTTP \(code)"
                case .decodingError(let d): msg = "Decoding error: \(d)"
                case .invalidParameters(let p): msg = "Invalid parameters: \(p)"
                }
            } else {
                msg = error.localizedDescription
            }
            predictionStatus = "Prediction failed: \(msg)"
            appLog("PredictionService: Prediction failed from \(trigger): \(msg)", category: .service, level: .error)
        }
    }
    
    private func calculateEffectiveDescentRate(telemetry: TelemetryData) -> Double {
        let isDescending = telemetry.verticalSpeed < 0
        if telemetry.altitude < 10000,
           let smoothedRate = serviceCoordinator?.smoothedDescentRate,
           smoothedRate != 0,
           isDescending {
            let val = abs(smoothedRate)
            appLog("PredictionService: Using smoothed descent rate: \(String(format: "%.2f", val)) m/s (below 10000m)", category: .service, level: .info)
            Task { @MainActor in
                self.serviceCoordinator?.predictionUsesSmoothedDescent = true
            }
            return val
        } else {
            let val = userSettings.descentRate
            if isDescending {
                appLog("PredictionService: Using settings descent rate: \(String(format: "%.2f", val)) m/s (above 10000m or no smoothed rate)", category: .service, level: .info)
            }
            Task { @MainActor in
                self.serviceCoordinator?.predictionUsesSmoothedDescent = false
            }
            return val
        }
    }
    
    private func createCacheKey(_ telemetry: TelemetryData) -> String {
        return PredictionCache.makeKey(
            balloonID: telemetry.sondeName,
            coordinate: CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude),
            altitude: telemetry.altitude,
            timeBucket: Date()
        )
    }
    
    private func handlePredictionResult(_ predictionData: PredictionData, trigger: String) async {
        hasValidPrediction = true
        lastPredictionTime = Date()
        predictionStatus = "Prediction successful"

        // Update prediction data and time calculations
        updatePredictionAndTimeCalculations(predictionData)
        
        appLog("PredictionService: Prediction completed successfully from \(trigger)", category: .service, level: .info)
        
        // Update ServiceCoordinator with results
        guard let serviceCoordinator = serviceCoordinator else {
            appLog("PredictionService: ServiceCoordinator is nil, cannot update", category: .service, level: .error)
            return
        }
        
        await MainActor.run {
            serviceCoordinator.predictionData = predictionData
            serviceCoordinator.updateMapWithPrediction(predictionData)
        }
        if let lp = predictionData.landingPoint {
            DebugCSVLogger.shared.setLatestPredictedLanding(lp)
        }
        
        appLog("PredictionService: Updated ServiceCoordinator with prediction results", category: .service, level: .info)
    }
    
    func fetchPrediction(telemetry: TelemetryData, userSettings: UserSettings, measuredDescentRate: Double, cacheKey: String, balloonDescends: Bool = false) async throws -> PredictionData {
        // Suppress verbose start-of-fetch log
        
        let request = try buildPredictionRequest(telemetry: telemetry, userSettings: userSettings, descentRate: abs(measuredDescentRate), balloonDescends: balloonDescends)
        
        do {
            // Perform request and log response details for debugging
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PredictionError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let bodySnippet = String(data: data.prefix(512), encoding: .utf8) ?? "<non-UTF8 body>"
                appLog("PredictionService: HTTP \(httpResponse.statusCode) response body (first 512B): \(bodySnippet)", category: .service, level: .error)
                publishHealthEvent(.degraded("HTTP \(httpResponse.statusCode)"), message: "HTTP \(httpResponse.statusCode)")
                throw PredictionError.httpError(httpResponse.statusCode)
            }
            
            appLog("PredictionService: HTTP 200 OK (length=\(data.count) bytes)", category: .service, level: .debug)
            if data.count <= 2048 {
                let snippet = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
                appLog("PredictionService: Response JSON (<=2KB): \(snippet)", category: .service, level: .debug)
            } else {
                let snippet = String(data: data.prefix(512), encoding: .utf8) ?? "<non-UTF8 body>"
                appLog("PredictionService: Response JSON snippet (first 512B): \(snippet)", category: .service, level: .debug)
            }

            // Parse the Sondehub v2 response
            let sondehubResponse = try JSONDecoder().decode(SondehubPredictionResponse.self, from: data)
            
            // Convert to our internal PredictionData format
            let predictionData = try convertSondehubToPredictionData(sondehubResponse)
            
            let landingPoint = predictionData.landingPoint
            let burstPoint = predictionData.burstPoint
            
            let landingPointDesc = landingPoint.map { "(\($0.latitude), \($0.longitude))" } ?? "nil"
            let burstPointDesc = burstPoint.map { "(\($0.latitude), \($0.longitude))" } ?? "nil"
            appLog("PredictionService: Sondehub v2 prediction completed - Landing: \(landingPointDesc), Burst: \(burstPointDesc)", category: .service, level: .info)
            
            publishHealthEvent(.healthy, message: "Prediction successful")
            return predictionData
            
        } catch let decodingError as DecodingError {
            appLog("PredictionService: JSON decoding failed: \(decodingError)", category: .service, level: .error)
            
            // More detailed decoding error analysis
            switch decodingError {
            case .keyNotFound(let key, let context):
                appLog("PredictionService: Missing key '\(key.stringValue)' at \(context.codingPath)", category: .service, level: .error)
            case .typeMismatch(let type, let context):
                appLog("PredictionService: Type mismatch for \(type) at \(context.codingPath)", category: .service, level: .error)
            case .valueNotFound(let type, let context):
                appLog("PredictionService: Value not found for \(type) at \(context.codingPath)", category: .service, level: .error)
            case .dataCorrupted(let context):
                appLog("PredictionService: Data corrupted at \(context.codingPath): \(context.debugDescription)", category: .service, level: .error)
            @unknown default:
                appLog("PredictionService: Unknown decoding error: \(decodingError)", category: .service, level: .error)
            }
            
            publishHealthEvent(.unhealthy("JSON decode failed"), message: "JSON decode failed")
            throw PredictionError.decodingError(decodingError.localizedDescription)
            
        } catch {
            let errorMessage = error.localizedDescription
            appLog("PredictionService: Sondehub v2 API failed: \(errorMessage)", category: .service, level: .error)
            publishHealthEvent(.unhealthy("API failed: \(errorMessage)"), message: "API failed: \(errorMessage)")
            throw error
        }
    }
    
    private func buildPredictionRequest(telemetry: TelemetryData, userSettings: UserSettings, descentRate: Double, balloonDescends: Bool) throws -> URLRequest {
        var components = URLComponents(string: "https://api.v2.sondehub.org/tawhiri")!
        let launchTime = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        // FSD: Use settings burst altitude while ascending; when descending, send current altitude + 10m
        // Ensure burst altitude is always greater than current altitude (API requirement)
        let burstAlt = telemetry.verticalSpeed >= 0 ?
            max(userSettings.burstAltitude, telemetry.altitude + 100.0) :
            telemetry.altitude + 10.0
        
        components.queryItems = [
            URLQueryItem(name: "launch_latitude", value: String(format: "%.4f", telemetry.latitude)),
            URLQueryItem(name: "launch_longitude", value: String(format: "%.4f", telemetry.longitude)),
            URLQueryItem(name: "launch_datetime", value: launchTime),
            URLQueryItem(name: "ascent_rate", value: String(format: "%.2f", userSettings.ascentRate)),
            URLQueryItem(name: "burst_altitude", value: String(format: "%.1f", burstAlt)),
            URLQueryItem(name: "descent_rate", value: String(format: "%.2f", descentRate)),
            URLQueryItem(name: "launch_altitude", value: String(format: "%.1f", telemetry.altitude)),
            URLQueryItem(name: "profile", value: "standard_profile"),
            URLQueryItem(name: "format", value: "json")
        ]
        
        guard let url = components.url else { throw PredictionError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        appLog(String(format: "PredictionService: Request URL: %@", url.absoluteString), category: .service, level: .debug)
        appLog(String(format: "PredictionService: Params lat=%.4f lon=%.4f alt=%.1f ascent=%.2f burst=%.1f descent=%.2f descends=%@",
                      telemetry.latitude, telemetry.longitude, telemetry.altitude,
                      userSettings.ascentRate, burstAlt, descentRate,
                      telemetry.verticalSpeed < 0 ? "YES" : "NO"),
               category: .service, level: .debug)
        return request
    }
    
    private func convertSondehubToPredictionData(_ response: SondehubPredictionResponse) throws -> PredictionData {
        // Extract ascent/descent trajectories and derive burst/landing points
        let stages = response.prediction
        let ascent = stages.first(where: { $0.stage.lowercased() == "ascent" })
        let descent = stages.first(where: { $0.stage.lowercased() == "descent" })
        if ascent == nil || descent == nil {
            appLog("PredictionService: Missing ascent/descent stages in response (ascent? \(ascent != nil), descent? \(descent != nil))", category: .service, level: .error)
            throw PredictionError.decodingError("Missing ascent or descent stage")
        }
        
        let ascentLast = ascent!.trajectory.last
        let descentLast = descent!.trajectory.last
        appLog("PredictionService: Trajectories — ascent=\(ascent!.trajectory.count), descent=\(descent!.trajectory.count), last descent datetime=\(descentLast?.datetime ?? "nil")", category: .service, level: .debug)
        
        let pathCoords: [CLLocationCoordinate2D] = stages.flatMap { $0.trajectory }.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        
        let burstPoint = ascentLast.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let landingPoint = descentLast.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        
        // Parse landing time robustly (handle fractional seconds)
        let landingTimeParsed: Date? = {
            guard let dt = descentLast?.datetime else { return nil }
            if let d = isoWithFrac.date(from: dt) { return d }
            if let d = isoNoFrac.date(from: dt) { return d }
            appLog("PredictionService: Unable to parse landing datetime '\(dt)'", category: .service, level: .error)
            return nil
        }()

        let predictionData = PredictionData(
            path: pathCoords,
            burstPoint: burstPoint,
            landingPoint: landingPoint,
            landingTime: landingTimeParsed,
            launchPoint: ascent!.trajectory.first.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
            burstAltitude: ascentLast?.altitude,
            flightTime: nil,
            metadata: nil
        )

        // Update time calculations for direct API calls
        updatePredictionAndTimeCalculations(predictionData)

        return predictionData
    }
    
    private func updateTimeCalculations() {
        guard let landingTime = latestPrediction?.landingTime else { return }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm"
        predictedLandingTimeString = dateFormatter.string(from: landingTime)
        appLog("PredictionService: Predicted landing time string set to \(predictedLandingTimeString)", category: .service, level: .debug)
        
        let remaining = landingTime.timeIntervalSinceNow
        if remaining > 0 {
            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            remainingFlightTimeString = String(format: "%02d:%02d", hours, minutes)
            appLog("PredictionService: Remaining flight time string set to \(remainingFlightTimeString)", category: .service, level: .debug)
        } else {
            remainingFlightTimeString = "00:00"
            appLog("PredictionService: Remaining flight time is 0 (already past landing)", category: .service, level: .debug)
        }
    }

    // MARK: - Time Calculation Trigger

    /// Updates time calculations whenever prediction data is set
    private func updatePredictionAndTimeCalculations(_ prediction: PredictionData) {
        latestPrediction = prediction
        updateTimeCalculations()
        appLog("PredictionService: Prediction and time calculations updated (landing=\(predictedLandingTimeString), flight=\(remainingFlightTimeString))", category: .service, level: .debug)
    }

    // MARK: - Prediction Models & Errors
    
    struct SondehubPredictionResponse: Codable {
        let metadata: Metadata
        let prediction: [Stage]
        let request: Request
        let warnings: [String: String]?
    }
    
    struct Metadata: Codable {
        let complete_datetime: String
        let start_datetime: String
    }
    
    struct Stage: Codable {
        let stage: String
        let trajectory: [Trajectory]
    }
    
    struct Trajectory: Codable {
        let altitude: Double
        let datetime: String
        let latitude: Double
        let longitude: Double
    }
    
    struct Request: Codable {
        let ascent_rate: Double
        let burst_altitude: Double
        let dataset: String?
        let descent_rate: Double
        let format: String
        let launch_altitude: Double?
        let launch_datetime: String
        let launch_latitude: Double
        let launch_longitude: Double
        let profile: String
        let version: Int?
    }
    
    enum PredictionError: Error {
        case invalidRequest
        case invalidResponse
        case httpError(Int)
        case decodingError(String)
        case invalidParameters(String)
    }
    
    // MARK: - Health
    private func publishHealthEvent(_ health: ServiceHealth, message: String) {
        serviceHealth = health
    }
}
