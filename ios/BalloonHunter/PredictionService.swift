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

    // MARK: - Sonde Change Handling

    func purgeAll() {
        cache.removeAll()
        lru.removeAll()
        metrics = PredictionCacheMetrics(hits: 0, misses: 0, evictions: 0, expirations: 0)
        appLog("PredictionCache: Purged all entries for new sonde", category: .cache, level: .info)
    }
}

// MARK: - Prediction Service

@MainActor
final class PredictionService: ObservableObject {

    /// Landing time anchored to the sonde's real telemetry, not the request's
    /// fictional launch. `launch`/`landing` are the predictor's trajectory
    /// datetimes; their difference is the flight duration, which added to the
    /// telemetry time gives the true landing time (in the future for a live
    /// descent, in the past for a sonde that already came down). Pure and
    /// `nonisolated` so it is unit-testable. See FSD *How a Landing Is Determined*.
    nonisolated static func anchoredLandingTime(telemetryTime: Date, launch: Date, landing: Date) -> Date {
        telemetryTime.addingTimeInterval(landing.timeIntervalSince(launch))
    }
    // MARK: - API Dependencies
    private let session: URLSession
    private var serviceHealth: ServiceHealth = .healthy
    
    // MARK: - Scheduling Dependencies  
    private let predictionCache: PredictionCache
    private weak var serviceCoordinator: ServiceCoordinator?
    private let userSettings: UserSettings
    private let balloonTrackService: BalloonTrackService?
    private weak var balloonPositionService: BalloonPositionService?
    private weak var landingPointTrackingService: LandingPointTrackingService?
    
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
    private var lastProcessedPosition: PositionData?
    private var apiCallCount: Int = 0
    private var currentPredictionTask: Task<Void, Never>?  // Track in-flight prediction for cancellation
    private let isoWithFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoNoFrac = ISO8601DateFormatter()

    // MARK: - Shared Dependencies Constructor (for app initialization)
    init(predictionCache: PredictionCache, userSettings: UserSettings) {
        // Initialize API session
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        self.session = URLSession(configuration: config)

        // Use shared dependencies
        self.predictionCache = predictionCache
        self.userSettings = userSettings
        self.serviceCoordinator = nil // Will be set later to avoid circular dependency
        self.balloonTrackService = nil // Will be set later if needed
        self.balloonPositionService = nil // Will be set later to avoid circular dependency
        self.landingPointTrackingService = nil // Will be set later for service chain

        // PredictionService initialized with shared dependencies
        publishHealthEvent(.healthy, message: "Prediction service initialized with shared dependencies")
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
        self.balloonPositionService = nil // Will be set later to avoid circular dependency
        self.landingPointTrackingService = nil // Will be set later for service chain
        
        // PredictionService initialized with scheduling
        publishHealthEvent(.healthy, message: "Prediction service initialized")
    }

    // MARK: - Configuration

    func setServiceCoordinator(_ coordinator: ServiceCoordinator) {
        self.serviceCoordinator = coordinator
        appLog("PredictionService: ServiceCoordinator configured", category: .service, level: .info)
    }

    func setBalloonPositionService(_ service: BalloonPositionService) {
        self.balloonPositionService = service
        appLog("PredictionService: BalloonPositionService configured", category: .service, level: .info)
    }

    func setLandingPointTrackingService(_ service: LandingPointTrackingService) {
        self.landingPointTrackingService = service
        appLog("PredictionService: LandingPointTrackingService configured for service chain", category: .service, level: .info)
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
        predictionStatus = "Stopped"

        appLog("PredictionService: Stopped automatic predictions", category: .service, level: .info)
    }
    
    // MARK: - Manual Prediction Triggers
    
    func triggerManualPrediction() async {
        guard let balloonPositionService = balloonPositionService else {
            appLog("PredictionService: Manual trigger ignored - no balloon position service", category: .service, level: .debug)
            return
        }

        // Use three-channel architecture
        if let position = balloonPositionService.currentPositionData {
            appLog("PredictionService: Manual trigger - performing prediction with position data", category: .service, level: .info)

            // Cancel any existing prediction task (don't wait for it to finish)
            currentPredictionTask?.cancel()

            // Create new prediction task and let it run independently
            currentPredictionTask = Task {
                await performPrediction(position: position, trigger: "manual")
            }
        } else {
            appLog("PredictionService: Manual trigger ignored - no position data available", category: .service, level: .debug)
        }
    }

    func triggerStartupPrediction() async {
        guard let balloonPositionService = balloonPositionService else {
            return
        }

        // Use three-channel architecture
        if let position = balloonPositionService.currentPositionData {
            appLog("PredictionService: Startup trigger - first position data received", category: .service, level: .info)

            // Cancel any existing prediction task (don't wait for it to finish)
            currentPredictionTask?.cancel()

            // Create new prediction task and let it run independently
            currentPredictionTask = Task {
                await performPrediction(position: position, trigger: "startup")
            }
        }
    }

    /// Trigger prediction with position data (three-channel architecture)
    func triggerPredictionWithPosition(_ position: PositionData, trigger: String = "coordinator") async {
        // Cancel any existing prediction task (don't wait for it to finish)
        currentPredictionTask?.cancel()

        // Create new prediction task and let it run independently
        currentPredictionTask = Task {
            await performPrediction(position: position, trigger: trigger)
        }

        // Note: We don't await the task here - it runs independently
        // If sonde changes, clearAllData() will cancel it immediately
    }
    
    
    // MARK: - Core Prediction Logic
    
    // TelemetryData version removed - use PositionData version below

    /// Three-channel architecture: Perform prediction with PositionData
    private func performPrediction(position: PositionData, trigger: String) async {
        predictionStatus = "Processing prediction..."

        // Dev sondes are processed normally; CSV filtering handled elsewhere

        do {
            let sinceLast = lastPredictionTime.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "N/A"
            appLog("PredictionService: performPrediction start (trigger=\(trigger), sinceLast=\(sinceLast)s)", category: .service, level: .debug)

            // Check cancellation before expensive operations
            try Task.checkCancellation()

            // Determine if balloon is descending
            let balloonDescends = position.verticalSpeed < 0
            appLog("PredictionService: Balloon descending: \(balloonDescends) (verticalSpeed: \(position.verticalSpeed) m/s)", category: .service, level: .info)

            // Calculate effective descent rate
            // Tawhiri's descent_rate is a sea-level terminal velocity, which is
            // exactly what the setting holds, so it is the base for the whole
            // flight. Reality is applied afterwards by comparing how far the
            // sonde has actually fallen against how far Tawhiri said it would.
            let effectiveDescentRate = userSettings.descentRate

            // Create cache key
            let cacheKey = createCacheKey(position)
            appLog("PredictionService: Trigger=\(trigger) cacheKey=\(cacheKey)", category: .service, level: .debug)

            // Check cache first
            if let cachedPrediction = await predictionCache.get(key: cacheKey) {
                appLog("PredictionService: Using cached prediction", category: .service, level: .info)

                // Check cancellation before publishing cached result
                try Task.checkCancellation()

                await handlePredictionResult(cachedPrediction, trigger: trigger)
                return
            }

            // Cache miss -> Call API
            apiCallCount += 1
            appLog("PredictionService: API call #\(apiCallCount) (trigger=\(trigger), key=\(cacheKey))", category: .service, level: .debug)
            let predictionData = try await fetchPrediction(
                position: position,
                userSettings: userSettings,
                measuredDescentRate: effectiveDescentRate,
                cacheKey: cacheKey,
                balloonDescends: balloonDescends
            )

            // Check cancellation before publishing API result
            try Task.checkCancellation()

            // Cache the result
            await predictionCache.set(key: cacheKey, value: predictionData)

            // Handle successful prediction
            await handlePredictionResult(predictionData, trigger: trigger)
            
        } catch is CancellationError {
            // Task was cancelled (sonde change) - this is expected, don't log as error
            appLog("PredictionService: Prediction cancelled (trigger=\(trigger)) - likely due to sonde change", category: .service, level: .info)
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




    private func createCacheKey(_ position: PositionData) -> String {
        // Bucket by the sonde's telemetry time, not now. A stale balloon (landed
        // by silence) has a fixed timestamp, so its key never changes — the same
        // prediction is served from cache and the landing point stays put instead
        // of wandering ~240 m every 5-minute bucket. A live balloon's timestamp
        // advances, so it still re-predicts with fresh data. See FSD *How a
        // Landing Is Determined*.
        return PredictionCache.makeKey(
            balloonID: position.sondeName,
            coordinate: CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude),
            altitude: position.altitude,
            timeBucket: position.timestamp
        )
    }

    
    private func handlePredictionResult(_ predictionData: PredictionData, trigger: String) async {
        hasValidPrediction = true
        lastPredictionTime = Date()
        predictionStatus = "Prediction successful"

        // Update prediction data and time calculations
        updatePredictionAndTimeCalculations(predictionData)
        
        appLog("PredictionService: Prediction completed successfully from \(trigger)", category: .service, level: .info)
        

        // NEW: Auto-chain to LandingPointTrackingService
        if let landingPoint = predictionData.landingPoint,
           let landingService = landingPointTrackingService {
            await landingService.updateLandingPoint(landingPoint, source: .prediction)
        }
        
        appLog("PredictionService: Updated ServiceCoordinator with prediction results", category: .service, level: .info)
    }
    
    func fetchPrediction(position: PositionData, userSettings: UserSettings, measuredDescentRate: Double, cacheKey: String, balloonDescends: Bool = false) async throws -> PredictionData {
        // Suppress verbose start-of-fetch log
        
        // Measure the assumed rate against how far the sonde has actually
        // fallen. Returns the input unchanged until there is enough fall to judge.
        // The configured rate, unchanged, for the whole flight. Tawhiri's
        // descent_rate is a sea-level terminal velocity and the predictor scales
        // it with altitude itself, so there is nothing for the app to adjust.
        let rateToSend = abs(measuredDescentRate)
        let chosen = PredictionEndpoint.base(useSwiss: userSettings.useSwissPredictor,
                                             swissURL: userSettings.swissPredictorURL)
        var request = try buildPredictionRequest(position: position, userSettings: userSettings, descentRate: rateToSend, balloonDescends: balloonDescends, baseURL: chosen)
        var servedBy = chosen
        appLog("PredictionService: Asking \(PredictionEndpoint.name(for: chosen))", category: .service, level: .info)

        do {
            // Ask the chosen server. If it cannot answer, retry once against
            // SondeHub so a hunt does not lose its predictions to a server that
            // is down, unreachable, or not yet deployed. Both failure shapes
            // count: a non-200 response, and a thrown transport error (DNS,
            // refused connection, TLS — a certificate that does not match the
            // host throws here, which is exactly how a not-yet-provisioned
            // vhost fails). Logged loudly: an A/B run is worthless if the log
            // does not say which server produced a landing point.
            func fetch(_ req: URLRequest) async throws -> (Data, URLResponse) {
                try await session.data(for: req)
            }

            var data: Data
            var response: URLResponse
            do {
                (data, response) = try await fetch(request)
                if PredictionEndpoint.shouldFallBack(from: chosen),
                   (response as? HTTPURLResponse)?.statusCode != 200 {
                    let code = (response as? HTTPURLResponse).map { String($0.statusCode) } ?? "no HTTP response"
                    appLog("PredictionService: ⚠️ \(PredictionEndpoint.name(for: chosen)) returned \(code) - falling back to SondeHub", category: .service, level: .error)
                    servedBy = PredictionEndpoint.fallback
                    request = try buildPredictionRequest(position: position, userSettings: userSettings, descentRate: rateToSend, balloonDescends: balloonDescends, baseURL: servedBy)
                    (data, response) = try await fetch(request)
                }
            } catch {
                guard PredictionEndpoint.shouldFallBack(from: chosen) else { throw error }
                appLog("PredictionService: ⚠️ \(PredictionEndpoint.name(for: chosen)) unreachable (\(error.localizedDescription)) - falling back to SondeHub", category: .service, level: .error)
                servedBy = PredictionEndpoint.fallback
                request = try buildPredictionRequest(position: position, userSettings: userSettings, descentRate: rateToSend, balloonDescends: balloonDescends, baseURL: servedBy)
                (data, response) = try await fetch(request)
            }

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
            
            // Convert to our internal PredictionData format. Anchor the landing
            // time to this telemetry sample's timestamp, not the request's launch.
            let predictionData = try convertSondehubToPredictionData(sondehubResponse, telemetryTime: position.timestamp)

            
            let landingPoint = predictionData.landingPoint
            let burstPoint = predictionData.burstPoint
            
            let landingPointDesc = landingPoint.map { "(\($0.latitude), \($0.longitude))" } ?? "nil"
            let burstPointDesc = burstPoint.map { "(\($0.latitude), \($0.longitude))" } ?? "nil"
            appLog("PredictionService: Prediction completed by \(PredictionEndpoint.name(for: servedBy)) - Landing: \(landingPointDesc), Burst: \(burstPointDesc)", category: .service, level: .info)
            
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


    private func buildPredictionRequest(position: PositionData, userSettings: UserSettings, descentRate: Double, balloonDescends: Bool, baseURL: URL) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        // Anchor the launch to the sonde's telemetry time, not now+60s. For a live
        // balloon that is ~now; for a stale one (landed by silence) it is the past
        // moment it was actually at this position, so the predictor uses the winds
        // from *then* — giving the correct descent and a landing that does not
        // drift as real time advances. See FSD *How a Landing Is Determined*.
        let launchTime = ISO8601DateFormatter().string(from: position.timestamp)
        // FSD: Use settings burst altitude while ascending; when descending, send current altitude + 10m
        // Ensure burst altitude is always greater than current altitude (API requirement)
        // Determine burst altitude based on whether balloon is descending
        let burstAlt = position.verticalSpeed >= 0 ?
            max(userSettings.burstAltitude, position.altitude + 100.0) :
            position.altitude + 10.0
        
        components.queryItems = [
            URLQueryItem(name: "launch_latitude", value: String(format: "%.4f", position.latitude)),
            URLQueryItem(name: "launch_longitude", value: String(format: "%.4f", position.longitude)),
            URLQueryItem(name: "launch_datetime", value: launchTime),
            URLQueryItem(name: "ascent_rate", value: String(format: "%.2f", userSettings.ascentRate)),
            URLQueryItem(name: "burst_altitude", value: String(format: "%.1f", burstAlt)),
            URLQueryItem(name: "descent_rate", value: String(format: "%.2f", descentRate)),
            URLQueryItem(name: "launch_altitude", value: String(format: "%.1f", position.altitude)),
            URLQueryItem(name: "profile", value: "standard_profile"),
            URLQueryItem(name: "format", value: "json")
        ]
        
        guard let url = components.url else { throw PredictionError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        appLog(String(format: "PredictionService: API request lat=%.4f lon=%.4f alt=%.0fm ↑%.1f ↓%.1f burst=%.0fm",
                      position.latitude, position.longitude, position.altitude,
                      userSettings.ascentRate, descentRate, burstAlt),
               category: .service, level: .debug)
        return request
    }

    /// Three-channel architecture: Build prediction request using PositionData
    
    private func convertSondehubToPredictionData(_ response: SondehubPredictionResponse, telemetryTime: Date) throws -> PredictionData {
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
        
        // Landing time, anchored to the sonde's actual last-heard time — NOT the
        // request's fictional launch. We send launch_datetime = now+60s, so the
        // predictor's absolute landing datetime is always in the future; using it
        // directly makes a balloon that landed hours ago read as "lands in a few
        // minutes." Instead take the predicted *duration* (launch → landing) and
        // add it to the telemetry timestamp: for a fresh descent that is
        // now + remaining fall; for a stale/landed sonde it is correctly in the
        // past. See FSD *How a Landing Is Determined*.
        func parse(_ dt: String?) -> Date? {
            guard let dt else { return nil }
            return isoWithFrac.date(from: dt) ?? isoNoFrac.date(from: dt)
        }
        let launchDatetime = parse(ascent!.trajectory.first?.datetime)
        let predictedLandingDatetime = parse(descentLast?.datetime)
        let landingTimeParsed: Date? = {
            guard let launch = launchDatetime, let land = predictedLandingDatetime else {
                if descentLast?.datetime != nil {
                    appLog("PredictionService: Unable to parse trajectory datetimes for landing time", category: .service, level: .error)
                }
                return nil
            }
            return Self.anchoredLandingTime(telemetryTime: telemetryTime, launch: launch, landing: land)
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

    // MARK: - Sonde Change

    func clearAllData() {
        // Cancel any in-flight prediction task
        currentPredictionTask?.cancel()
        currentPredictionTask = nil

        // Clear all prediction data
        latestPrediction = nil
        predictedLandingTimeString = "--:--"
        remainingFlightTimeString = "--:--"
        hasValidPrediction = false
        lastPredictionTime = nil
        lastProcessedPosition = nil
        appLog("PredictionService: All data cleared for new sonde (cancelled in-flight prediction)", category: .service, level: .info)
    }
}
