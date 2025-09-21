import Foundation
import Combine
import CoreLocation
import MapKit
import OSLog

// MARK: - Balloon Position Service

@MainActor
final class BalloonPositionService: ObservableObject {
    // Current position and telemetry data
    @Published var currentPosition: CLLocationCoordinate2D?
    @Published var currentTelemetry: TelemetryData?
    @Published var currentAltitude: Double?
    @Published var currentVerticalSpeed: Double?
    @Published var currentBalloonName: String?
    
    // Derived position data
    @Published var distanceToUser: Double?
    @Published var timeSinceLastUpdate: TimeInterval = 0
    @Published var hasReceivedTelemetry: Bool = false
    
    private let bleService: BLECommunicationService
    let aprsService: APRSTelemetryService
    private let currentLocationService: CurrentLocationService
    private var currentUserLocation: LocationData?
    private var lastTelemetryTime: Date?
    private var cancellables = Set<AnyCancellable>()
    
    init(bleService: BLECommunicationService, aprsService: APRSTelemetryService, currentLocationService: CurrentLocationService) {
        self.bleService = bleService
        self.aprsService = aprsService
        self.currentLocationService = currentLocationService
        setupSubscriptions()
        // BalloonPositionService initialized
    }
    
    private func setupSubscriptions() {
        // Subscribe to BLE service telemetry stream (primary source)
        bleService.telemetryData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] telemetry in
                self?.handleTelemetryUpdate(telemetry, source: "BLE")
            }
            .store(in: &cancellables)

        // Subscribe to APRS service telemetry stream (fallback source)
        aprsService.telemetryData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] telemetry in
                self?.handleTelemetryUpdate(telemetry, source: "APRS")
            }
            .store(in: &cancellables)

        // Monitor BLE telemetry availability and control APRS polling
        bleService.$telemetryAvailabilityState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isHealthy in
                self?.handleBLETelemetryAvailabilityChange(isHealthy)
            }
            .store(in: &cancellables)

        // Subscribe to CurrentLocationService directly for distance calculations
        currentLocationService.$locationData
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }  // Filter out nil values
            .sink { [weak self] locationData in
                self?.handleUserLocationUpdate(locationData)
            }
            .store(in: &cancellables)

        // Update time since last update periodically
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateTimeSinceLastUpdate()
            }
            .store(in: &cancellables)
    }
    
    private func handleTelemetryUpdate(_ telemetry: TelemetryData, source: String) {
        // Only process APRS telemetry when BLE is unavailable (arbitration)
        if source == "APRS" && bleService.telemetryAvailabilityState {
            appLog("BalloonPositionService: APRS telemetry received but BLE is healthy - ignoring", category: .service, level: .debug)
            return
        }

        let now = Date()

        appLog("BalloonPositionService: Processing \(source) telemetry for sonde \(telemetry.sondeName)", category: .service, level: .info)

        // Update current state
        currentTelemetry = telemetry
        currentPosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
        currentAltitude = telemetry.altitude
        currentVerticalSpeed = telemetry.verticalSpeed
        currentBalloonName = telemetry.sondeName
        hasReceivedTelemetry = true
        lastTelemetryTime = now

        // Update APRS service with BLE sonde name for mismatch detection
        if source == "BLE" {
            aprsService.updateBLESondeName(telemetry.sondeName)
        }

        // Update distance to user if location available
        updateDistanceToUser()

        // Position and telemetry are now available through @Published properties
        // Suppress verbose position update log in debug output
    }

    private func handleBLETelemetryAvailabilityChange(_ isHealthy: Bool) {
        appLog("BalloonPositionService: BLE telemetry availability changed - healthy=\(isHealthy)", category: .service, level: .info)

        // Notify APRS service about BLE health status
        aprsService.updateBLETelemetryHealth(isHealthy)

        if isHealthy {
            appLog("BalloonPositionService: BLE telemetry resumed - APRS polling suspended", category: .service, level: .info)
        } else {
            appLog("BalloonPositionService: BLE telemetry lost - APRS polling activated", category: .service, level: .info)
        }
    }
    
    private func handleUserLocationUpdate(_ location: LocationData) {
        currentUserLocation = location
        updateDistanceToUser()
    }
    
    private func updateDistanceToUser() {
        guard let balloonPosition = currentPosition,
              let userLocation = currentUserLocation else {
            distanceToUser = nil
            return
        }
        
        let balloonCLLocation = CLLocation(latitude: balloonPosition.latitude, longitude: balloonPosition.longitude)
        let userCLLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        distanceToUser = balloonCLLocation.distance(from: userCLLocation)
    }
    
    private func updateTimeSinceLastUpdate() {
        guard let lastUpdate = lastTelemetryTime else {
            timeSinceLastUpdate = 0
            return
        }
        timeSinceLastUpdate = Date().timeIntervalSince(lastUpdate)
    }
    
    // Convenience methods for policies
    func getBalloonLocation() -> CLLocationCoordinate2D? {
        return currentPosition
    }
    
    func getLatestTelemetry() -> TelemetryData? {
        return currentTelemetry
    }
    
    func getDistanceToUser() -> Double? {
        return distanceToUser
    }
    
    func isWithinRange(_ distance: Double) -> Bool {
        guard let currentDistance = distanceToUser else { return false }
        return currentDistance <= distance
    }
}

// MARK: - Balloon Track Service

@MainActor
final class BalloonTrackService: ObservableObject {
    @Published var currentBalloonTrack: [BalloonTrackPoint] = []
    @Published var currentBalloonName: String?
    @Published var currentEffectiveDescentRate: Double?
    @Published var trackUpdated = PassthroughSubject<Void, Never>()
    
    // Landing detection
    @Published var isBalloonFlying: Bool = false
    @Published var isBalloonLanded: Bool = false
    @Published var landingPosition: CLLocationCoordinate2D?
    @Published var balloonPhase: BalloonPhase = .unknown
    
    // Smoothed telemetry data (moved from DataPanelView for proper separation of concerns)
    @Published var smoothedHorizontalSpeed: Double = 0
    @Published var smoothedVerticalSpeed: Double = 0
    @Published var adjustedDescentRate: Double? = nil
    @Published var isTelemetryStale: Bool = true
    
    private let persistenceService: PersistenceService
    let balloonPositionService: BalloonPositionService
    private var cancellables = Set<AnyCancellable>()
    
    // Track management
    private var telemetryPointCounter = 0
    private let saveInterval = 10 // Save every 10 telemetry points
    
    // Landing detection - smoothing buffers
    private var verticalSpeedBuffer: [Double] = []
    private var horizontalSpeedBuffer: [Double] = []
    private var landingPositionBuffer: [CLLocationCoordinate2D] = []
    private let verticalSpeedBufferSize = 20
    private let horizontalSpeedBufferSize = 20
    private let landingPositionBufferSize = 100
    private let landingConfidenceClearThreshold = 0.40
    private let landingConfidenceClearSamplesRequired = 3
    private var landingConfidenceFalsePositiveCount = 0

    // Adjusted descent rate smoothing buffer (FSD: 20 values)
    private var adjustedDescentHistory: [Double] = []
    
    // Staleness detection (moved from DataPanelView for proper separation of concerns)
    private var stalenessTimer: Timer?
    private let stalenessThreshold: TimeInterval = 3.0 // 3 seconds threshold

    // Robust speed smoothing state
    private var lastEmaTimestamp: Date? = nil
    private var emaHorizontalMS: Double = 0
    private var emaVerticalMS: Double = 0
    private var hasEma: Bool = false
    private var hWindow: [Double] = []
    private var vWindow: [Double] = []
    private let hampelWindowSize = 10
    private let hampelK = 3.0
    private let vHDeadbandMS: Double = 0.2   // ~0.72 km/h
    private let vVDeadbandMS: Double = 0.05
    private let tauHorizontal: Double = 10.0 // seconds
    private let tauVertical: Double = 10.0   // seconds
    private var lastMetricsLog: Date? = nil
    
    init(persistenceService: PersistenceService, balloonPositionService: BalloonPositionService) {
        self.persistenceService = persistenceService
        self.balloonPositionService = balloonPositionService
        // BalloonTrackService initialized
        setupSubscriptions()
        loadPersistedDataAtStartup()
        startStalenessTimer()
    }
    
    /// Load any persisted balloon data at startup
    private func loadPersistedDataAtStartup() {
        // Try to load any existing track data from persistence
        // Note: We don't know the sonde name yet, so we can't load specific tracks
        // But we can prepare the service for when telemetry arrives
        appLog("BalloonTrackService: Ready to load persisted data on first telemetry", category: .service, level: .info)
    }
    
    private func setupSubscriptions() {
        // Subscribe to BalloonPositionService telemetry directly
        balloonPositionService.$currentTelemetry
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }  // Filter out nil values
            .sink { [weak self] telemetryData in
                self?.processTelemetryData(telemetryData)
            }
            .store(in: &cancellables)
    }
    
    func processTelemetryData(_ telemetryData: TelemetryData) {
        if currentBalloonName == nil || telemetryData.sondeName != currentBalloonName {
            appLog("BalloonTrackService: New sonde detected - \(telemetryData.sondeName), switching from \(currentBalloonName ?? "none")", category: .service, level: .info)
            
            // First, try to load the track for the new sonde
            let persistedTrack = persistenceService.loadTrackForCurrentSonde(sondeName: telemetryData.sondeName)
            
            // Only purge tracks if we're actually switching to a different sonde
            if let currentName = currentBalloonName, currentName != telemetryData.sondeName {
                appLog("BalloonTrackService: Switching from different sonde (\(currentName)) - purging old tracks", category: .service, level: .info)
                persistenceService.purgeAllTracks()
            }
            
            if let track = persistedTrack {
                self.currentBalloonTrack = track
                appLog("BalloonTrackService: Loaded persisted track for \(telemetryData.sondeName) with \(self.currentBalloonTrack.count) points", category: .service, level: .info)
            } else {
                self.currentBalloonTrack = []
                appLog("BalloonTrackService: No persisted track found - starting fresh track for \(telemetryData.sondeName)", category: .service, level: .info)
            }
            telemetryPointCounter = 0
        }
        
        currentBalloonName = telemetryData.sondeName
        
        // Compute track-derived speeds prior to appending, so we can store derived values
        var derivedHorizontalMS: Double? = nil
        var derivedVerticalMS: Double? = nil
        if let prev = currentBalloonTrack.last {
            let dt = telemetryData.timestamp.timeIntervalSince(prev.timestamp)
            if dt > 0 {
                let R = 6371000.0
                let lat1 = prev.latitude * .pi / 180, lon1 = prev.longitude * .pi / 180
                let lat2 = telemetryData.latitude * .pi / 180, lon2 = telemetryData.longitude * .pi / 180
                let dlat = lat2 - lat1, dlon = lon2 - lon1
                let a = sin(dlat/2) * sin(dlat/2) + cos(lat1) * cos(lat2) * sin(dlon/2) * sin(dlon/2)
                let c = 2 * atan2(sqrt(a), sqrt(1 - a))
                let distance = R * c // meters
                derivedHorizontalMS = distance / dt
                derivedVerticalMS = (telemetryData.altitude - prev.altitude) / dt
                // Diagnostics: compare derived vs telemetry
                let hTele = telemetryData.horizontalSpeed
                let vTele = telemetryData.verticalSpeed
                let hDiff = ((derivedHorizontalMS ?? hTele) - hTele) * 3.6
                let vDiff = (derivedVerticalMS ?? vTele) - vTele
                if abs(hDiff) > 3.0 || abs(vDiff) > 0.5 {
                    appLog(String(format: "BalloonTrackService: Speed check — h(track)=%.2f km/h vs h(tele)=%.2f km/h, v(track)=%.2f m/s vs v(tele)=%.2f m/s", (derivedHorizontalMS ?? 0)*3.6, hTele*3.6, (derivedVerticalMS ?? 0), vTele), category: .service, level: .debug)
                }
            }
        }

        let trackPoint = BalloonTrackPoint(
            latitude: telemetryData.latitude,
            longitude: telemetryData.longitude,
            altitude: telemetryData.altitude,
            timestamp: telemetryData.timestamp,
            verticalSpeed: derivedVerticalMS ?? telemetryData.verticalSpeed,
            horizontalSpeed: derivedHorizontalMS ?? telemetryData.horizontalSpeed
        )
        
        currentBalloonTrack.append(trackPoint)

        // Calculate effective descent rate from track history
        updateEffectiveDescentRate()

        // Update landing detection
        updateLandingDetection(telemetryData)

        // Update adjusted descent rate (60s robust + 20-sample smoothing)
        updateAdjustedDescentRate()

        // CSV logging (all builds)
        DebugCSVLogger.shared.logTelemetry(telemetryData)

        // Publish track update
        trackUpdated.send()

        // Robust smoothed speeds update (EMA pipeline)
        if let prev = currentBalloonTrack.dropLast().last {
            let dt = trackPoint.timestamp.timeIntervalSince(prev.timestamp)
            updateSmoothedSpeedsPipeline(instH: trackPoint.horizontalSpeed, instV: trackPoint.verticalSpeed, timestamp: trackPoint.timestamp, dt: dt)
        } else {
            updateSmoothedSpeedsPipeline(instH: trackPoint.horizontalSpeed, instV: trackPoint.verticalSpeed, timestamp: trackPoint.timestamp, dt: 1.0)
        }

        // Update published balloon phase
        if isBalloonLanded {
            balloonPhase = .landed
        } else if trackPoint.verticalSpeed >= 0 {
            balloonPhase = .ascending
        } else {
            balloonPhase = trackPoint.altitude < 10_000 ? .descendingBelow10k : .descendingAbove10k
        }

        // Periodic persistence
        telemetryPointCounter += 1
        if telemetryPointCounter % saveInterval == 0 {
            saveCurrentTrack()
        }
    }

    private func updateSmoothedSpeedsPipeline(instH: Double, instV: Double, timestamp: Date, dt: TimeInterval) {
        // Append to Hampel windows
        hWindow.append(instH); if hWindow.count > hampelWindowSize { hWindow.removeFirst() }
        vWindow.append(instV); if vWindow.count > hampelWindowSize { vWindow.removeFirst() }

        func median(_ a: [Double]) -> Double {
            if a.isEmpty { return 0 }
            let s = a.sorted(); let m = s.count/2
            return s.count % 2 == 0 ? (s[m-1] + s[m]) / 2.0 : s[m]
        }
        func mad(_ a: [Double], med: Double) -> Double {
            if a.isEmpty { return 0 }
            let dev = a.map { abs($0 - med) }
            return median(dev)
        }

        // Hampel filter for outliers
        var xh = instH
        var xv = instV
        let mh = median(hWindow); let mhd = 1.4826 * mad(hWindow, med: mh)
        if mhd > 0, abs(instH - mh) > hampelK * mhd { xh = mh }
        let mv = median(vWindow); let mvd = 1.4826 * mad(vWindow, med: mv)
        if mvd > 0, abs(instV - mv) > hampelK * mvd { xv = mv }

        // Deadbands near zero to kill jitter
        if xh.magnitude < vHDeadbandMS { xh = 0 }
        if xv.magnitude < vVDeadbandMS { xv = 0 }

        // EMA smoothing with time constants
        let prevTime = lastEmaTimestamp
        lastEmaTimestamp = timestamp
        let dtEff: Double
        if let pt = prevTime { dtEff = max(0.01, timestamp.timeIntervalSince(pt)) } else { dtEff = max(0.01, dt > 0 ? dt : 1.0) }
        let alphaH = dtEff / (tauHorizontal + dtEff)
        let alphaV = dtEff / (tauVertical + dtEff)

        if !hasEma {
            emaHorizontalMS = xh
            emaVerticalMS = xv
            hasEma = true
        } else {
            emaHorizontalMS = (1 - alphaH) * emaHorizontalMS + alphaH * xh
            emaVerticalMS = (1 - alphaV) * emaVerticalMS + alphaV * xv
        }

        smoothedHorizontalSpeed = emaHorizontalMS
        smoothedVerticalSpeed = emaVerticalMS
    }

    private func updateAdjustedDescentRate() {
        let now = Date()
        let windowStart = now.addingTimeInterval(-60)
        let window = currentBalloonTrack.filter { $0.timestamp >= windowStart }
        guard window.count >= 3 else { return }

        var intervalRates: [Double] = []
        for i in 1..<window.count {
            let dt = window[i].timestamp.timeIntervalSince(window[i-1].timestamp)
            if dt <= 0 { continue }
            let dv = window[i].altitude - window[i-1].altitude
            intervalRates.append(dv / dt)
        }
        guard !intervalRates.isEmpty else { return }

        let sorted = intervalRates.sorted()
        let mid = sorted.count/2
        let instant = (sorted.count % 2 == 0) ? (sorted[mid-1] + sorted[mid]) / 2.0 : sorted[mid]

        adjustedDescentHistory.append(instant)
        if adjustedDescentHistory.count > 20 { adjustedDescentHistory.removeFirst() }
        let smoothed = adjustedDescentHistory.reduce(0.0, +) / Double(adjustedDescentHistory.count)
        adjustedDescentRate = smoothed
    }
    
    private func updateEffectiveDescentRate() {
        guard currentBalloonTrack.count >= 5 else { return }
        
        let recentPoints = Array(currentBalloonTrack.suffix(5))
        let altitudes = recentPoints.map { $0.altitude }
        let timestamps = recentPoints.map { $0.timestamp.timeIntervalSince1970 }
        
        // Simple linear regression for descent rate
        let n = Double(altitudes.count)
        let sumX = timestamps.reduce(0, +)
        let sumY = altitudes.reduce(0, +)
        let sumXY = zip(timestamps, altitudes).map { $0 * $1 }.reduce(0, +)
        let sumXX = timestamps.map { $0 * $0 }.reduce(0, +)
        
        let denominator = n * sumXX - sumX * sumX
        if denominator != 0 {
            let slope = (n * sumXY - sumX * sumY) / denominator
            currentEffectiveDescentRate = slope // m/s
        }
    }
    
    private func updateLandingDetection(_ telemetryData: TelemetryData) {
        // Update speed buffers for smoothing (prefer track-derived values)
        if let last = currentBalloonTrack.last {
            verticalSpeedBuffer.append(last.verticalSpeed)
        } else {
            verticalSpeedBuffer.append(telemetryData.verticalSpeed)
        }
        if verticalSpeedBuffer.count > verticalSpeedBufferSize {
            verticalSpeedBuffer.removeFirst()
        }
        
        if let last = currentBalloonTrack.last {
            horizontalSpeedBuffer.append(last.horizontalSpeed)
        } else {
            horizontalSpeedBuffer.append(telemetryData.horizontalSpeed)
        }
        if horizontalSpeedBuffer.count > horizontalSpeedBufferSize {
            horizontalSpeedBuffer.removeFirst()
        }
        
        // Update position buffer for landing position smoothing
        let currentPosition = CLLocationCoordinate2D(latitude: telemetryData.latitude, longitude: telemetryData.longitude)
        landingPositionBuffer.append(currentPosition)
        if landingPositionBuffer.count > landingPositionBufferSize {
            landingPositionBuffer.removeFirst()
        }
        
        // Check if we have telemetry signal (within last 3 seconds)
        let hasRecentTelemetry = Date().timeIntervalSince(telemetryData.timestamp) < 3.0

        // Build time windows for stationarity metrics
        let now = Date()
        let window30 = currentBalloonTrack.filter { now.timeIntervalSince($0.timestamp) <= 30.0 }

        // Altitude stationarity (spread)
        func altSpread(_ pts: [BalloonTrackPoint]) -> Double {
            guard let minA = pts.map({ $0.altitude }).min(), let maxA = pts.map({ $0.altitude }).max() else { return .greatestFiniteMagnitude }
            return maxA - minA
        }

        // Horizontal stationarity (95th percentile distance from centroid)
        func p95Radius(_ pts: [BalloonTrackPoint]) -> Double {
            guard !pts.isEmpty else { return .greatestFiniteMagnitude }
            let latMean = pts.map({ $0.latitude }).reduce(0, +) / Double(pts.count)
            let lonMean = pts.map({ $0.longitude }).reduce(0, +) / Double(pts.count)
            func dist(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
                let R = 6371000.0
                let a1 = lat1 * .pi/180, b1 = lon1 * .pi/180
                let a2 = lat2 * .pi/180, b2 = lon2 * .pi/180
                let dA = a2 - a1, dB = b2 - b1
                let a = sin(dA/2)*sin(dA/2) + cos(a1)*cos(a2)*sin(dB/2)*sin(dB/2)
                let c = 2 * atan2(sqrt(a), sqrt(1-a))
                return R * c
            }
            let d = pts.map { dist($0.latitude, $0.longitude, latMean, lonMean) }.sorted()
            let idx = min(d.count-1, Int(ceil(0.95 * Double(d.count))) - 1)
            return d[max(0, idx)]
        }

        let altSpread30 = altSpread(window30)
        let radius30 = p95Radius(window30)
        
        // Use smoothed horizontal speed (km/h) for an additional guard
        let smoothedHorizontalSpeedKmh = horizontalSpeedBuffer.count >= 10 ? (horizontalSpeedBuffer.reduce(0, +) / Double(horizontalSpeedBuffer.count)) * 3.6 : telemetryData.horizontalSpeed * 3.6

        // Calculate statistical confidence for landing detection
        func calculateLandingConfidence(window30: [BalloonTrackPoint], smoothedHorizontalSpeedKmh: Double) -> (confidence: Double, isLanded: Bool) {
            guard window30.count >= 3 else { return (0.0, false) }

            // 1. Altitude stability - account for poor GPS altitude accuracy (±10-15m typical)
            let altitudes = window30.map { $0.altitude }
            let altMean = altitudes.reduce(0, +) / Double(altitudes.count)
            let altVariance = altitudes.map { pow($0 - altMean, 2) }.reduce(0, +) / Double(altitudes.count)
            let altStdDev = sqrt(altVariance)
            let altConfidence = max(0, 1.0 - altStdDev / 12.0) // 12m = 0% confidence, 0m = 100% (reflects GPS altitude inaccuracy)

            // 2. Position stability (movement radius confidence)
            let firstPos = CLLocation(latitude: window30[0].latitude, longitude: window30[0].longitude)
            let maxDistance = window30.map { point in
                let pos = CLLocation(latitude: point.latitude, longitude: point.longitude)
                return firstPos.distance(from: pos)
            }.max() ?? 0
            let posConfidence = max(0, 1.0 - maxDistance / 20.0) // 20m = 0%, 0m = 100%

            // 3. Speed stability (velocity confidence) - more lenient thresholds
            let avgHSpeed = window30.map { $0.horizontalSpeed }.reduce(0, +) / Double(window30.count)
            let avgVSpeed = window30.map { abs($0.verticalSpeed) }.reduce(0, +) / Double(window30.count)
            let avgTotalSpeed = max(avgHSpeed, avgVSpeed)
            let speedConfidence = max(0, 1.0 - avgTotalSpeed / 2.0) // 2 m/s = 0%, 0 m/s = 100% (more lenient)

            // 4. Sample size confidence (more samples = higher confidence)
            let sampleConfidence = min(1.0, Double(window30.count) / 8.0) // 8+ samples = 100%

            // Combined confidence - prioritize horizontal position (more accurate than altitude)
            let totalConfidence = (altConfidence * 0.2 + posConfidence * 0.4 + speedConfidence * 0.3 + sampleConfidence * 0.1)

            // Landing decision: 75% confidence threshold (reduced from 80% for better responsiveness)
            return (totalConfidence, totalConfidence >= 0.75)
        }

        // Statistical confidence-based landing detection
        let (landingConfidence, isLandedNow) = calculateLandingConfidence(window30: window30, smoothedHorizontalSpeedKmh: smoothedHorizontalSpeedKmh)

        // Debug landing detection criteria (only log when we have meaningful data)
        if window30.count >= 3 && altSpread30 < 1000 && radius30 < 10000 {
            appLog(String(format: "🎯 LANDING: points=%d altSpread=%.1fm radius=%.1fm speed=%.1fkm/h confidence=%.1f%% → landed=%@",
                          window30.count, altSpread30, radius30, smoothedHorizontalSpeedKmh, landingConfidence * 100, isLandedNow ? "YES" : "NO"),
                   category: .general, level: .debug)
        }

        let wasPreviouslyFlying = isBalloonFlying

        if !isBalloonLanded && isLandedNow {
            // Balloon just landed
            isBalloonLanded = true
            landingConfidenceFalsePositiveCount = 0

            // Use smoothed (100) position for landing point
            if landingPositionBuffer.count >= 50 { // Use at least 50 points for reasonable smoothing
                let avgLat = landingPositionBuffer.map { $0.latitude }.reduce(0, +) / Double(landingPositionBuffer.count)
                let avgLon = landingPositionBuffer.map { $0.longitude }.reduce(0, +) / Double(landingPositionBuffer.count)
                landingPosition = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            } else {
                landingPosition = currentPosition
            }

            let altSpreadStr = altSpread30.isFinite ? String(format: "%.2f", altSpread30) : "∞"
            let radiusStr = radius30.isFinite ? String(format: "%.1f", radius30) : "∞"
            appLog("BalloonTrackService: Balloon LANDED — altSpread30=\(altSpreadStr)m, radius30=\(radiusStr)m", category: .service, level: .info)

        } else if isBalloonLanded {
            let belowSampleThreshold = window30.count < 3
            if belowSampleThreshold || landingConfidence < landingConfidenceClearThreshold {
                landingConfidenceFalsePositiveCount += 1
            } else {
                landingConfidenceFalsePositiveCount = 0
            }

            if landingConfidenceFalsePositiveCount >= landingConfidenceClearSamplesRequired {
                isBalloonLanded = false
                landingPosition = nil
                landingConfidenceFalsePositiveCount = 0
                appLog(
                    "BalloonTrackService: Landing CLEARED — confidence=\(String(format: "%.1f", landingConfidence * 100))%%, points=\(window30.count)",
                    category: .service,
                    level: .info
                )
            }
        } else {
            landingConfidenceFalsePositiveCount = 0
        }

        // Update balloon flying state after landing evaluation
        isBalloonFlying = hasRecentTelemetry && !isBalloonLanded

        if wasPreviouslyFlying && isBalloonFlying {
            let instH = telemetryData.horizontalSpeed * 3.6
            let instV = telemetryData.verticalSpeed
            let avgV = smoothedVerticalSpeed
            let phase: String = {
                if isBalloonLanded { return "Landed" }
                if telemetryData.verticalSpeed >= 0 { return "Ascending" }
                return telemetryData.altitude < 10_000 ? "Descending <10k" : "Descending"
            }()
            appLog(
                "BalloonTrackService: Balloon FLYING - phase=\(phase), hSpeed(avg)=\(String(format: "%.2f", smoothedHorizontalSpeedKmh)) km/h, hSpeed(inst)=\(String(format: "%.2f", instH)) km/h, vSpeed(avg)=\(String(format: "%.2f", avgV)) m/s, vSpeed(inst)=\(String(format: "%.2f", instV)) m/s",
                category: .service,
                level: .debug
            )
        }
        
        // Periodic debug metrics while not landed (compile-time gated)
        #if DEBUG
        if !isBalloonLanded && window30.count >= 10 {
            let nowT = Date()
            if lastMetricsLog == nil || nowT.timeIntervalSince(lastMetricsLog!) > 10.0 {
                lastMetricsLog = nowT
                let altSpreadStr = altSpread30.isFinite ? String(format: "%.2f", altSpread30) : "∞"
                let radiusStr = radius30.isFinite ? String(format: "%.1f", radius30) : "∞"
                appLog("BalloonTrackService: Metrics — altSpread30=\(altSpreadStr)m, radius30=\(radiusStr)m, hSpeed(avg)=\(String(format: "%.2f", smoothedHorizontalSpeedKmh)) km/h", category: .service, level: .debug)
            }
        }
        #endif
        
    }
    
    private func saveCurrentTrack() {
        guard let balloonName = currentBalloonName else { return }
        persistenceService.saveBalloonTrack(sondeName: balloonName, track: currentBalloonTrack)
    }
    
    // Public API
    func getAllTrackPoints() -> [BalloonTrackPoint] {
        return currentBalloonTrack
    }
    
    func getRecentTrackPoints(_ count: Int) -> [BalloonTrackPoint] {
        return Array(currentBalloonTrack.suffix(count))
    }
    
    func clearCurrentTrack() {
        currentBalloonTrack.removeAll()
        trackUpdated.send()
    }

    // Manually set balloon as landed (e.g., when landing point comes from clipboard)
    func setBalloonAsLanded(at coordinate: CLLocationCoordinate2D) {
        isBalloonLanded = true
        landingPosition = coordinate
        balloonPhase = .landed
        appLog("BalloonTrackService: Balloon manually set as LANDED at \(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))", category: .service, level: .info)
    }

    // MARK: - Smoothing and Staleness Detection (moved from DataPanelView)
    
    private func updateSmoothedSpeeds() {
        // Per FSD: Smoothing using last 5 values (moved from DataPanelView for proper separation of concerns)
        let last5 = Array(currentBalloonTrack.suffix(5))
        
        // Smoothed horizontal speed
        let horizontalSpeeds = last5.compactMap { $0.horizontalSpeed }
        if !horizontalSpeeds.isEmpty {
            smoothedHorizontalSpeed = horizontalSpeeds.reduce(0, +) / Double(horizontalSpeeds.count)
        } else {
            smoothedHorizontalSpeed = balloonPositionService.currentTelemetry?.horizontalSpeed ?? 0
        }
        
        // Smoothed vertical speed
        let verticalSpeeds = last5.compactMap { $0.verticalSpeed }
        if !verticalSpeeds.isEmpty {
            smoothedVerticalSpeed = verticalSpeeds.reduce(0, +) / Double(verticalSpeeds.count)
        } else {
            smoothedVerticalSpeed = balloonPositionService.currentTelemetry?.verticalSpeed ?? 0
        }
    }
    
    private func startStalenessTimer() {
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkTelemetryStaleness()
            }
        }
    }
    
    private func checkTelemetryStaleness() {
        guard let telemetry = balloonPositionService.currentTelemetry else {
            isTelemetryStale = true
            return
        }
        
        let timeSinceUpdate = Date().timeIntervalSince(telemetry.timestamp)
        isTelemetryStale = timeSinceUpdate > stalenessThreshold
    }
    
    deinit {
        stalenessTimer?.invalidate()
    }
}

// MARK: - Landing Point Tracking Service

@MainActor
final class LandingPointTrackingService: ObservableObject {
    @Published private(set) var landingHistory: [LandingPredictionPoint] = []
    @Published private(set) var lastLandingPrediction: LandingPredictionPoint? = nil

    private let persistenceService: PersistenceService
    private let balloonTrackService: BalloonTrackService
    private var cancellables = Set<AnyCancellable>()
    private let deduplicationThreshold: CLLocationDistance = 25.0
    private var currentSondeName: String?

    init(persistenceService: PersistenceService, balloonTrackService: BalloonTrackService) {
        self.persistenceService = persistenceService
        self.balloonTrackService = balloonTrackService

        balloonTrackService.$currentBalloonName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newName in
                self?.handleSondeChange(newName: newName)
            }
            .store(in: &cancellables)
    }

    func recordLandingPrediction(coordinate: CLLocationCoordinate2D, predictedAt: Date, landingEta: Date?, source: LandingPredictionSource = .sondehub) {
        guard let sondeName = balloonTrackService.currentBalloonName else {
            appLog("LandingPointTrackingService: Ignoring landing prediction – missing sonde name", category: .service, level: .debug)
            return
        }

        let newPoint = LandingPredictionPoint(coordinate: coordinate, predictedAt: predictedAt, landingEta: landingEta, source: source)

        if let last = landingHistory.last, last.distance(from: newPoint) < deduplicationThreshold {
            landingHistory[landingHistory.count - 1] = newPoint
        } else {
            landingHistory.append(newPoint)
        }

        lastLandingPrediction = newPoint

        persistenceService.saveLandingHistory(sondeName: sondeName, history: landingHistory)
    }

    func persistCurrentHistory() {
        guard let sondeName = currentSondeName else { return }
        persistenceService.saveLandingHistory(sondeName: sondeName, history: landingHistory)
    }

    func resetHistory() {
        landingHistory = []
        lastLandingPrediction = nil
    }

    private func handleSondeChange(newName: String?) {
        guard currentSondeName != newName else { return }

        if let previous = currentSondeName, let newName, previous != newName {
            persistenceService.removeLandingHistory(for: previous)
        }

        currentSondeName = newName

        if let name = newName, let storedHistory = persistenceService.loadLandingHistory(sondeName: name) {
            landingHistory = storedHistory
            lastLandingPrediction = storedHistory.last
        } else {
            resetHistory()
        }
    }
}
