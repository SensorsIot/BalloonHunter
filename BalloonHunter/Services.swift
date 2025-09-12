// Services.swift
// Consolidated service layer for BalloonHunter
// Contains all service implementations in one organized file

import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import OSLog

// MARK: - Core Data Models

enum TransportationMode: String, CaseIterable, Codable {
    case car = "car"
    case bike = "bike"
}

@MainActor
class UserSettings: ObservableObject, Codable {
    @Published var burstAltitude: Double = 30000
    @Published var ascentRate: Double = 5.0
    @Published var descentRate: Double = 5.0
    
    enum CodingKeys: CodingKey {
        case burstAltitude, ascentRate, descentRate
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        burstAltitude = try container.decode(Double.self, forKey: .burstAltitude)
        ascentRate = try container.decode(Double.self, forKey: .ascentRate)
        descentRate = try container.decode(Double.self, forKey: .descentRate)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(burstAltitude, forKey: .burstAltitude)
        try container.encode(ascentRate, forKey: .ascentRate)
        try container.encode(descentRate, forKey: .descentRate)
    }
    
    init() {
        // Default values already set above
    }
}

// MARK: - Data Models

struct TelemetryData {
    var sondeName: String = ""
    var probeType: String = ""
    var frequency: Double = 0.0
    var latitude: Double = 0.0
    var longitude: Double = 0.0
    var altitude: Double = 0.0
    var verticalSpeed: Double = 0.0
    var horizontalSpeed: Double = 0.0
    var heading: Double = 0.0
    var temperature: Double = 0.0
    var humidity: Double = 0.0
    var pressure: Double = 0.0
    var batteryVoltage: Double = 0.0
    var batteryPercentage: Int = 0
    var signalStrength: Int = 0
    var timestamp: Date = Date()
    var buzmute: Bool = false
    var afcFrequency: Int = 0
    var burstKillerEnabled: Bool = false
    var burstKillerTime: Int = 0
    var softwareVersion: String = ""
    
    mutating func parse(message: String) {
        let components = message.components(separatedBy: "/")
        guard components.count > 3 else { return }
        
        let packetType = components[0]
        timestamp = Date()
        
        switch packetType {
        case "0":
            // Type 0: Device Basic Info and Status (8 fields)
            guard components.count >= 8 else { return }
            probeType = components[1]
            frequency = Double(components[2]) ?? 0.0
            signalStrength = Int(Double(components[3]) ?? 0.0)
            batteryPercentage = Int(components[4]) ?? 0
            batteryVoltage = Double(components[5]) ?? 0.0
            buzmute = components[6] == "1"
            softwareVersion = components[7]
            
        case "1":
            // Type 1: Probe Telemetry (20 fields)
            guard components.count >= 20 else { return }
            probeType = components[1]
            frequency = Double(components[2]) ?? 0.0
            sondeName = components[3]
            latitude = Double(components[4]) ?? 0.0
            longitude = Double(components[5]) ?? 0.0
            altitude = Double(components[6]) ?? 0.0
            horizontalSpeed = Double(components[7]) ?? 0.0
            verticalSpeed = Double(components[8]) ?? 0.0
            signalStrength = Int(Double(components[9]) ?? 0.0)
            batteryPercentage = Int(components[10]) ?? 0
            afcFrequency = Int(components[11]) ?? 0
            burstKillerEnabled = components[12] == "1"
            burstKillerTime = Int(components[13]) ?? 0
            batteryVoltage = Double(components[14]) ?? 0.0
            buzmute = components[15] == "1"
            // reserved1-3 = components[16-18] (not used)
            softwareVersion = components[19]
            
        case "2":
            // Type 2: Name Only (10 fields)
            guard components.count >= 10 else { return }
            probeType = components[1]
            frequency = Double(components[2]) ?? 0.0
            sondeName = components[3]
            signalStrength = Int(Double(components[4]) ?? 0.0)
            batteryPercentage = Int(components[5]) ?? 0
            afcFrequency = Int(components[6]) ?? 0
            batteryVoltage = Double(components[7]) ?? 0.0
            buzmute = components[8] == "1"
            softwareVersion = components[9]
            // Note: No coordinates available in Type 2
            latitude = 0.0
            longitude = 0.0
            altitude = 0.0
            horizontalSpeed = 0.0
            verticalSpeed = 0.0
            
        default:
            // Unknown packet type
            break
        }
    }
}

struct LocationData {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let heading: Double
    let timestamp: Date
}

struct BalloonTrackPoint: Codable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let verticalSpeed: Double
    let horizontalSpeed: Double
}

struct PredictionData {
    let path: [CLLocationCoordinate2D]?
    let burstPoint: CLLocationCoordinate2D?
    let landingPoint: CLLocationCoordinate2D?
    let landingTime: Date?
    let metadata: [String: Any]?
}

struct RouteData {
    let coordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let transportType: TransportationMode
}

struct MapAnnotationItem: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let title: String
    let type: AnnotationType
    
    enum AnnotationType {
        case balloon
        case user
        case landing
        case burst
    }
}


@MainActor
class AppSettings: ObservableObject {
    // App-level settings can be added here as needed
    @Published var debugMode: Bool = false
    
    init() {
        // Default values
    }
}

// MARK: - Application Logging

enum LogCategory: String {
    case event = "Event"
    case policy = "Policy"
    case service = "Service"
    case ui = "UI"
    case cache = "Cache"
    case general = "General"
    case persistence = "Persistence"
    case ble = "BLE"
    case lifecycle = "Lifecycle"
    case modeState = "ModeState"
}

nonisolated func appLog(_ message: String, category: LogCategory, level: OSLogType = .default) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timestamp = formatter.string(from: Date.now)
    let timestampedMessage = "[\(timestamp)] \(message)"
    
    let logger = Logger(subsystem: "com.yourcompany.BalloonHunter", category: category.rawValue)
    
    // Use literal string formatting to avoid decode issues with special characters
    switch level {
    case OSLogType.debug: logger.debug("\(timestampedMessage, privacy: .public)")
    case OSLogType.info: logger.info("\(timestampedMessage, privacy: .public)")
    case OSLogType.error: logger.error("\(timestampedMessage, privacy: .public)")
    case OSLogType.fault: logger.fault("\(timestampedMessage, privacy: .public)")
    default: logger.log("\(timestampedMessage, privacy: .public)")
    }
}


// MARK: - Current Location Service

@MainActor
final class CurrentLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    
    @Published var locationData: LocationData? = nil
    @Published var isLocationPermissionGranted: Bool = false
    
    private let locationManager = CLLocationManager()
    private var lastHeading: Double? = nil
    private var lastLocationTime: Date? = nil
    private var lastLocationUpdate: Date? = nil
    private var currentBalloonPosition: CLLocationCoordinate2D?
    private var currentProximityMode: ProximityMode = .far
    private var cancellables = Set<AnyCancellable>()
    
    // GPS configuration based on proximity to balloon per specification
    enum ProximityMode {
        case close  // <100m from balloon - Highest GPS precision, no movement threshold, 1Hz max
        case far    // >100m from balloon - Reasonable precision, 5m movement threshold
    }
    
    override init() {
        super.init()
        locationManager.delegate = self
        configureGPSForMode(.far) // Start with far-range settings
        setupBalloonTrackingSubscription()
        appLog("CurrentLocationService: GPS configured for FAR RANGE - 10m accuracy, 5m distance filter", category: .service, level: .info)
        appLog("CurrentLocationService: Initialized with dynamic proximity filtering", category: .service, level: .info)
    }
    
    private func setupBalloonTrackingSubscription() {
        // CurrentLocationService tracks balloon position for proximity-based GPS configuration
        // This should observe balloon position updates, not telemetry directly
        // TODO: Connect to appropriate balloon position updates
    }
    
    private func updateBalloonPosition(_ telemetry: TelemetryData) {
        let newBalloonPosition = CLLocationCoordinate2D(
            latitude: telemetry.latitude,
            longitude: telemetry.longitude
        )
        
        currentBalloonPosition = newBalloonPosition
        
        // Check if we need to switch GPS modes based on distance
        if let userLocation = locationData {
            evaluateProximityMode(userLocation: userLocation)
        }
    }
    
    private func evaluateProximityMode(userLocation: LocationData) {
        guard let balloonPosition = currentBalloonPosition else { return }
        
        let userCoordinate = CLLocationCoordinate2D(
            latitude: userLocation.latitude,
            longitude: userLocation.longitude
        )
        
        let distance = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
            .distance(from: CLLocation(latitude: balloonPosition.latitude, longitude: balloonPosition.longitude))
        
        let newMode: ProximityMode
        if distance < 100 { // <100m - CLOSE MODE per specification
            newMode = .close
        } else { // >100m - FAR MODE per specification
            newMode = .far
        }
        
        if newMode != currentProximityMode {
            currentProximityMode = newMode
            configureGPSForMode(newMode)
            
            let modeString = newMode == .close ? "CLOSE" : "FAR"
            appLog("CurrentLocationService: Switched to \(modeString) RANGE GPS (distance: \(Int(distance))m)", category: .service, level: .info)
        }
    }
    
    private func configureGPSForMode(_ mode: ProximityMode) {
        switch mode {
        case .close:
            // CLOSE MODE (<100m): kCLLocationAccuracyBest, no movement threshold, max 1 update/sec
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = kCLDistanceFilterNone // No movement threshold
            appLog("CurrentLocationService: CLOSE MODE - Best accuracy, no distance filter, 1Hz max", category: .service, level: .info)
            
        case .far:
            // FAR MODE (>100m): kCLLocationAccuracyNearestTenMeters, 20m movement threshold
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 20.0 // Only update on 20+ meter movement
            appLog("CurrentLocationService: FAR MODE - 10m accuracy, 20m distance filter", category: .service, level: .info)
        }
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        locationManager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            isLocationPermissionGranted = true
            locationManager.startUpdatingLocation()
            locationManager.startUpdatingHeading()
            publishHealthEvent(.healthy, message: "Location permission granted")
        case .denied, .restricted:
            isLocationPermissionGranted = false
            publishHealthEvent(.unhealthy("Location permission denied"), message: "Location permission denied")
        case .notDetermined:
            publishHealthEvent(.degraded("Location permission not determined"), message: "Location permission not determined")
        @unknown default:
            publishHealthEvent(.degraded("Unknown location authorization status"), message: "Unknown location authorization status")
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }
        let heading = lastHeading ?? location.course
        DispatchQueue.main.async {
            let now = Date()
            
            // Check if this is the first location update
            let isFirstUpdate = self.locationData == nil
            
            // Time-based filtering for CLOSE mode (max 1 update per second)
            if self.currentProximityMode == .close {
                if let lastUpdate = self.lastLocationUpdate {
                    let timeSinceLastUpdate = now.timeIntervalSince(lastUpdate)
                    if timeSinceLastUpdate < 1.0 && !isFirstUpdate {
                        // Skip this update - too soon for CLOSE mode
                        return
                    }
                }
            }
            
            // Calculate distance and time differences for filtering
            var distanceDiff: Double = 0
            var timeDiff: TimeInterval = 0
            
            if let previousLocation = self.locationData {
                let prevCLLocation = CLLocation(latitude: previousLocation.latitude, longitude: previousLocation.longitude)
                distanceDiff = location.distance(from: prevCLLocation)
                if let lastTime = self.lastLocationTime {
                    timeDiff = now.timeIntervalSince(lastTime)
                }
            }
            
            // Create new location data
            let newLocationData = LocationData(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.altitude,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy,
                heading: heading,
                timestamp: Date()
            )
            
            self.locationData = newLocationData
            self.lastLocationTime = now
            self.lastLocationUpdate = now
            
            // Location is now available through @Published locationData property
            // Services observe this directly instead of using EventBus
            
            if isFirstUpdate {
                appLog("Initial user location: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude)", category: .service, level: .info)
            } else if distanceDiff > 50 { // Only log significant movement (>50m)
                let modeString = self.currentProximityMode == .close ? "CLOSE" : "FAR"
                appLog("User location update [\(modeString)]: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude), dist=\(distanceDiff)m, timeDiff=\(timeDiff)s", category: .service, level: .debug)
            }
            
            // Re-evaluate proximity mode with new location
            self.evaluateProximityMode(userLocation: newLocationData)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        lastHeading = heading
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        appLog("CurrentLocationService: Location error: \(error.localizedDescription)", category: .service, level: .error)
        publishHealthEvent(.unhealthy("Location error: \(error.localizedDescription)"), message: "Location error: \(error.localizedDescription)")
    }
    
    private func publishHealthEvent(_ health: ServiceHealth, message: String) {
        // Service health events removed - health tracked internally only
        // Health status logging removed for log reduction
    }
}

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
    private let currentLocationService: CurrentLocationService
    private var currentUserLocation: LocationData?
    private var lastTelemetryTime: Date?
    private var cancellables = Set<AnyCancellable>()
    
    init(bleService: BLECommunicationService, currentLocationService: CurrentLocationService) {
        self.bleService = bleService
        self.currentLocationService = currentLocationService
        setupSubscriptions()
        // BalloonPositionService initialized
    }
    
    private func setupSubscriptions() {
        // Subscribe directly to BLE service telemetry stream (most reliable)
        bleService.telemetryData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] telemetry in
                self?.handleTelemetryUpdate(telemetry)
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
    
    private func handleTelemetryUpdate(_ telemetry: TelemetryData) {
        let now = Date()
        
        // Update current state
        currentTelemetry = telemetry
        currentPosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
        currentAltitude = telemetry.altitude
        currentVerticalSpeed = telemetry.verticalSpeed
        currentBalloonName = telemetry.sondeName
        hasReceivedTelemetry = true
        lastTelemetryTime = now
        
        // Update distance to user if location available
        updateDistanceToUser()
        
        // Position and telemetry are now available through @Published properties
        // Services observe these directly instead of using EventBus
        
        appLog("BalloonPositionService: Updated position for balloon \(telemetry.sondeName) at (\(telemetry.latitude), \(telemetry.longitude), \(telemetry.altitude)m)", category: .service, level: .debug)
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
    
    // Smoothed telemetry data (moved from DataPanelView for proper separation of concerns)
    @Published var smoothedHorizontalSpeed: Double = 0
    @Published var smoothedVerticalSpeed: Double = 0
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
    
    // Staleness detection (moved from DataPanelView for proper separation of concerns)
    private var stalenessTimer: Timer?
    private let stalenessThreshold: TimeInterval = 3.0 // 3 seconds threshold
    
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
        
        let trackPoint = BalloonTrackPoint(
            latitude: telemetryData.latitude,
            longitude: telemetryData.longitude,
            altitude: telemetryData.altitude,
            timestamp: telemetryData.timestamp,
            verticalSpeed: telemetryData.verticalSpeed,
            horizontalSpeed: telemetryData.horizontalSpeed
        )
        
        currentBalloonTrack.append(trackPoint)
        
        // Calculate effective descent rate from track history
        updateEffectiveDescentRate()
        
        // Update landing detection
        updateLandingDetection(telemetryData)
        
        // Publish track update
        trackUpdated.send()
        
        // Periodic persistence
        telemetryPointCounter += 1
        if telemetryPointCounter % saveInterval == 0 {
            saveCurrentTrack()
        }
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
        // Update speed buffers for smoothing
        verticalSpeedBuffer.append(telemetryData.verticalSpeed)
        if verticalSpeedBuffer.count > verticalSpeedBufferSize {
            verticalSpeedBuffer.removeFirst()
        }
        
        horizontalSpeedBuffer.append(telemetryData.horizontalSpeed)
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
        
        // Calculate smoothed speeds - require minimum buffer size for reliable detection
        let smoothedVerticalSpeed = verticalSpeedBuffer.count >= 10 ? verticalSpeedBuffer.reduce(0, +) / Double(verticalSpeedBuffer.count) : telemetryData.verticalSpeed
        let smoothedHorizontalSpeedKmh = horizontalSpeedBuffer.count >= 10 ? (horizontalSpeedBuffer.reduce(0, +) / Double(horizontalSpeedBuffer.count)) * 3.6 : telemetryData.horizontalSpeed * 3.6 // Convert m/s to km/h
        
        // Landing detection criteria with hysteresis to prevent false positives:
        // - Telemetry signal available during last 3 seconds
        // - Smoothed (10+) vertical speed < 2 m/s
        // - Smoothed (10+) horizontal speed < 2 km/h
        // - Require sufficient buffer for reliable smoothing
        let isLandedNow = hasRecentTelemetry && 
                         verticalSpeedBuffer.count >= 10 &&
                         horizontalSpeedBuffer.count >= 10 &&
                         abs(smoothedVerticalSpeed) < 2.0 && 
                         smoothedHorizontalSpeedKmh < 2.0
        
        // Update balloon flying/landed state
        let wasPreviouslyFlying = isBalloonFlying
        isBalloonFlying = hasRecentTelemetry && !isLandedNow
        
        if !isBalloonLanded && isLandedNow {
            // Balloon just landed
            isBalloonLanded = true
            
            // Use smoothed (100) position for landing point
            if landingPositionBuffer.count >= 50 { // Use at least 50 points for reasonable smoothing
                let avgLat = landingPositionBuffer.map { $0.latitude }.reduce(0, +) / Double(landingPositionBuffer.count)
                let avgLon = landingPositionBuffer.map { $0.longitude }.reduce(0, +) / Double(landingPositionBuffer.count)
                landingPosition = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            } else {
                landingPosition = currentPosition
            }
            
            appLog("BalloonTrackService: Balloon LANDED detected - vSpeed: \(smoothedVerticalSpeed)m/s, hSpeed: \(smoothedHorizontalSpeedKmh)km/h at \(landingPosition!)", category: .service, level: .info)
            
            // Landing event publishing removed - LandingPointService eliminated
        } else if wasPreviouslyFlying && isBalloonFlying {
            appLog("BalloonTrackService: Balloon FLYING - vSpeed: \(smoothedVerticalSpeed)m/s, hSpeed: \(smoothedHorizontalSpeedKmh)km/h", category: .service, level: .debug)
        }
        
        // Update smoothed speeds after processing telemetry (moved from DataPanelView)
        updateSmoothedSpeeds()
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
    
    // MARK: - Published State (merged from both services)
    @Published var isRunning: Bool = false
    @Published var hasValidPrediction: Bool = false
    @Published var lastPredictionTime: Date?
    @Published var predictionStatus: String = "Not started"
    @Published var latestPrediction: PredictionData?
    
    // Time calculations (moved from DataPanelView for proper separation of concerns)
    @Published var predictedLandingTimeString: String = "--:--"
    @Published var remainingFlightTimeString: String = "--:--"
    
    // MARK: - Private State
    private var internalTimer: Timer?
    private let predictionInterval: TimeInterval = 60.0
    private var lastProcessedTelemetry: TelemetryData?
    
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
        predictionStatus = "Running"
        startInternalTimer()
        
        appLog("PredictionService: Started automatic predictions with 60-second interval", category: .service, level: .info)
    }
    
    func stopAutomaticPredictions() {
        isRunning = false
        internalTimer?.invalidate()
        internalTimer = nil
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
    
    // MARK: - Private Timer Implementation
    
    private func startInternalTimer() {
        stopInternalTimer() // Ensure no duplicate timers
        
        internalTimer = Timer.scheduledTimer(withTimeInterval: predictionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleTimerTrigger()
            }
        }
        
        appLog("PredictionService: Internal 60-second timer started", category: .service, level: .info)
    }
    
    private func stopInternalTimer() {
        internalTimer?.invalidate()
        internalTimer = nil
    }
    
    private func handleTimerTrigger() async {
        guard let serviceCoordinator = serviceCoordinator,
              let telemetry = serviceCoordinator.balloonTelemetry else {
            appLog("PredictionService: Timer trigger - no telemetry available", category: .service, level: .debug)
            return
        }
        
        appLog("PredictionService: Timer trigger - performing prediction", category: .service, level: .info)
        await performPrediction(telemetry: telemetry, trigger: "timer")
    }
    
    // MARK: - Core Prediction Logic (merged from BalloonTrackPredictionService)
    
    private func performPrediction(telemetry: TelemetryData, trigger: String) async {
        predictionStatus = "Processing prediction..."
        
        do {
            // Determine if balloon is descending
            let balloonDescends = telemetry.verticalSpeed < 0
            appLog("PredictionService: Balloon descending: \(balloonDescends) (verticalSpeed: \(telemetry.verticalSpeed) m/s)", category: .service, level: .info)
            
            // Calculate effective descent rate
            let effectiveDescentRate = calculateEffectiveDescentRate(telemetry: telemetry)
            
            // Create cache key
            let cacheKey = createCacheKey(telemetry)
            
            // Check cache first
            if let cachedPrediction = await predictionCache.get(key: cacheKey) {
                appLog("PredictionService: Using cached prediction", category: .service, level: .info)
                await handlePredictionResult(cachedPrediction, trigger: trigger)
                return
            }
            
            // Call API
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
            predictionStatus = "Prediction failed: \(error.localizedDescription)"
            appLog("PredictionService: Prediction failed from \(trigger): \(error)", category: .service, level: .error)
        }
    }
    
    private func calculateEffectiveDescentRate(telemetry: TelemetryData) -> Double {
        if telemetry.altitude < 10000, let smoothedRate = serviceCoordinator?.smoothedDescentRate {
            appLog("PredictionService: Using smoothed descent rate: \(String(format: "%.2f", abs(smoothedRate))) m/s (below 10000m)", category: .service, level: .info)
            return abs(smoothedRate)
        } else {
            appLog("PredictionService: Using settings descent rate: \(String(format: "%.2f", userSettings.descentRate)) m/s (above 10000m or no smoothed rate)", category: .service, level: .info)
            return userSettings.descentRate
        }
    }
    
    private func createCacheKey(_ telemetry: TelemetryData) -> String {
        return PredictionCache.makeKey(
            balloonID: telemetry.sondeName,
            coordinate: CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude),
            altitude: telemetry.altitude,
            timeBucket: telemetry.timestamp
        )
    }
    
    private func handlePredictionResult(_ predictionData: PredictionData, trigger: String) async {
        await MainActor.run {
            latestPrediction = predictionData
            hasValidPrediction = true
            lastPredictionTime = Date()
            predictionStatus = "Prediction successful"
            
            // Update time calculations (moved from DataPanelView)
            updateTimeCalculations()
        }
        
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
        
        appLog("PredictionService: Updated ServiceCoordinator with prediction results", category: .service, level: .info)
    }
    
    func fetchPrediction(telemetry: TelemetryData, userSettings: UserSettings, measuredDescentRate: Double, cacheKey: String, balloonDescends: Bool = false) async throws -> PredictionData {
        appLog("PredictionService: Starting Sondehub v2 prediction fetch for \(telemetry.sondeName) at altitude \(telemetry.altitude)m", category: .service, level: .info)
        
        let request = try buildPredictionRequest(telemetry: telemetry, userSettings: userSettings, descentRate: abs(measuredDescentRate), balloonDescends: balloonDescends)
        
        do {
            appLog("PredictionService: Making GET request to Sondehub v2 API", category: .service, level: .debug)
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PredictionError.invalidResponse
            }
            
            // HTTP response received (log removed)
            
            guard httpResponse.statusCode == 200 else {
                publishHealthEvent(.degraded("HTTP \(httpResponse.statusCode)"), message: "HTTP \(httpResponse.statusCode)")
                throw PredictionError.httpError(httpResponse.statusCode)
            }
            
            // JSON decode (log removed)
            
            // First, let's see what we actually received
            if let _ = String(data: data, encoding: .utf8) {
                // Raw JSON response (log removed for reduction)
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
    
    private func buildPredictionRequest(telemetry: TelemetryData, userSettings: UserSettings, descentRate: Double, balloonDescends: Bool = false) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.v2.sondehub.org"
        components.path = "/tawhiri"
        
        // Burst altitude logic based on requirements:
        // - During ascent: use settings burst altitude (default 35000m)
        // - During descent: current altitude + 10m
        let effectiveBurstAltitude = if balloonDescends {
            telemetry.altitude + 10  // Requirements: current altitude + 10m for descent
        } else {
            max(userSettings.burstAltitude, telemetry.altitude + 100)  // Ensure above current for ascent
        }
        
        appLog("PredictionService: Burst altitude - descending: \(balloonDescends), effective: \(effectiveBurstAltitude)m", category: .service, level: .info)
        
        let queryItems = [
            URLQueryItem(name: "launch_latitude", value: String(telemetry.latitude)),
            URLQueryItem(name: "launch_longitude", value: String(telemetry.longitude)),
            URLQueryItem(name: "launch_altitude", value: String(telemetry.altitude)),
            URLQueryItem(name: "launch_datetime", value: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))), // Requirements: actual time + 1 minute
            URLQueryItem(name: "ascent_rate", value: String(userSettings.ascentRate)),
            URLQueryItem(name: "burst_altitude", value: String(effectiveBurstAltitude)),
            URLQueryItem(name: "descent_rate", value: String(abs(descentRate)))
        ]
        
        components.queryItems = queryItems
        
        guard let url = components.url else {
            throw PredictionError.invalidResponse
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Debug logging
        // Prediction API request (log removed)
        
        return request
    }
    
    private func convertSondehubToPredictionData(_ sondehubResponse: SondehubPredictionResponse) throws -> PredictionData {
        var trajectoryCoordinates: [CLLocationCoordinate2D] = []
        var burstPoint: CLLocationCoordinate2D?
        var landingPoint: CLLocationCoordinate2D?
        var landingTime: Date?
        
        // ISO8601 date formatter for parsing Sondehub datetime strings with fractional seconds
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        // Process ascent stage
        if let ascent = sondehubResponse.prediction.first(where: { $0.stage == "ascent" }) {
            for point in ascent.trajectory {
                let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                trajectoryCoordinates.append(coordinate)
            }
            
            // Burst point is the last point of ascent
            if let lastAscentPoint = ascent.trajectory.last {
                burstPoint = CLLocationCoordinate2D(latitude: lastAscentPoint.latitude, longitude: lastAscentPoint.longitude)
            }
        }
        
        // Process descent stage
        if let descent = sondehubResponse.prediction.first(where: { $0.stage == "descent" }) {
            appLog("PredictionService: Found descent stage with \(descent.trajectory.count) trajectory points", category: .service, level: .debug)
            
            for point in descent.trajectory {
                let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                trajectoryCoordinates.append(coordinate)
            }
            
            // Landing point and time are from the last point of descent
            if let lastDescentPoint = descent.trajectory.last {
                landingPoint = CLLocationCoordinate2D(latitude: lastDescentPoint.latitude, longitude: lastDescentPoint.longitude)
                appLog("PredictionService: Last descent point datetime string: '\(lastDescentPoint.datetime)'", category: .service, level: .debug)
                
                landingTime = dateFormatter.date(from: lastDescentPoint.datetime)
                
                if landingTime == nil {
                    appLog("PredictionService: Failed to parse landing time from: '\(lastDescentPoint.datetime)'", category: .service, level: .error)
                    appLog("PredictionService: DateFormatter expects ISO8601 format (e.g., '2024-03-15T10:30:45Z')", category: .service, level: .error)
                } else {
                    appLog("PredictionService: Successfully parsed landing time: \(landingTime!) from '\(lastDescentPoint.datetime)'", category: .service, level: .info)
                }
            } else {
                appLog("PredictionService: No trajectory points found in descent stage", category: .service, level: .error)
            }
        } else {
            appLog("PredictionService: No descent stage found in prediction response", category: .service, level: .error)
        }
        
        return PredictionData(
            path: trajectoryCoordinates,
            burstPoint: burstPoint,
            landingPoint: landingPoint,
            landingTime: landingTime,
            metadata: nil
        )
    }
    
    // MARK: - Time Calculations (moved from DataPanelView)
    
    private func updateTimeCalculations() {
        // Update predicted landing time string
        if let predictionData = latestPrediction, let landingTime = predictionData.landingTime {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            predictedLandingTimeString = formatter.string(from: landingTime)
        } else if let serviceCoordinator = serviceCoordinator,
                  let balloonTelemetry = serviceCoordinator.balloonTelemetry {
            // Fallback calculation for landing time
            predictedLandingTimeString = calculateFallbackLandingTime(telemetry: balloonTelemetry)
        } else {
            predictedLandingTimeString = "--:--"
        }
        
        // Update remaining flight time string
        if let predictionData = latestPrediction, let landingTime = predictionData.landingTime {
            let remainingSeconds = landingTime.timeIntervalSinceNow
            if remainingSeconds > 0 {
                let hours = Int(remainingSeconds) / 3600
                let minutes = Int(remainingSeconds) % 3600 / 60
                remainingFlightTimeString = String(format: "%d:%02d", hours, minutes)
            } else {
                remainingFlightTimeString = "--:--"
            }
        } else {
            remainingFlightTimeString = "--:--"
        }
    }
    
    private func calculateFallbackLandingTime(telemetry: TelemetryData) -> String {
        let currentAltitude = telemetry.altitude
        let descentRate: Double
        
        if telemetry.verticalSpeed < 0 {
            // Descending - use actual descent rate
            descentRate = abs(telemetry.verticalSpeed)
        } else {
            // Ascending - use smoothed/estimated descent rate
            descentRate = serviceCoordinator?.smoothedDescentRate != nil ? 
                abs(serviceCoordinator!.smoothedDescentRate!) : 5.0
        }
        
        guard descentRate > 0.1 else {
            return "--:--"
        }
        
        let timeToLandingSeconds = currentAltitude / descentRate
        let estimatedLandingTime = Date().addingTimeInterval(timeToLandingSeconds)
        
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: estimatedLandingTime)
    }
    
    private func publishHealthEvent(_ health: ServiceHealth, message: String) {
        serviceHealth = health
        // Service health events removed - health tracked internally only
        // Health status logging removed for log reduction
    }
}

// MARK: - Sondehub API Models

struct SondehubPredictionResponse: Codable {
    let prediction: [SondehubStage]
}

struct SondehubStage: Codable {
    let stage: String // "ascent" or "descent"
    let trajectory: [SondehubTrajectoryPoint]
}

struct SondehubTrajectoryPoint: Codable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let datetime: String
}

// MARK: - Route Calculation Service

@MainActor
final class RouteCalculationService: ObservableObject {
    private let currentLocationService: CurrentLocationService
    
    init(currentLocationService: CurrentLocationService) {
        self.currentLocationService = currentLocationService
        appLog("RouteCalculationService init", category: .service, level: .debug)
    }
    
    func calculateRoute(from userLocation: LocationData, to destination: CLLocationCoordinate2D, transportMode: TransportationMode) async throws -> RouteData {
        let request = MKDirections.Request()
        
        // Source
        let sourcePlacemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude))
        request.source = MKMapItem(placemark: sourcePlacemark)
        
        // Destination
        let destinationPlacemark = MKPlacemark(coordinate: destination)
        request.destination = MKMapItem(placemark: destinationPlacemark)
        
        // Transport mode per FSD: Use .cycling for bike, .automobile for car
        request.transportType = transportMode == .car ? .automobile : .cycling
        
        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        
        guard let route = response.routes.first else {
            throw RouteError.noRouteFound
        }
        
        // Apply 30% time reduction for bicycle mode per FSD requirement
        let adjustedTravelTime = transportMode == .bike ? route.expectedTravelTime * 0.7 : route.expectedTravelTime
        
        return RouteData(
            coordinates: extractCoordinates(from: route.polyline),
            distance: route.distance,
            expectedTravelTime: adjustedTravelTime,
            transportType: transportMode
        )
    }
    
    private func extractCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let coordinateCount = polyline.pointCount
        let coordinates = UnsafeMutablePointer<CLLocationCoordinate2D>.allocate(capacity: coordinateCount)
        defer { coordinates.deallocate() }
        
        polyline.getCoordinates(coordinates, range: NSRange(location: 0, length: coordinateCount))
        
        return Array(UnsafeBufferPointer(start: coordinates, count: coordinateCount))
    }
}


// MARK: - Persistence Service

@MainActor
final class PersistenceService: ObservableObject {
    private let userDefaults = UserDefaults.standard
    
    // Internal storage for cached data
    @Published var userSettings: UserSettings
    @Published var deviceSettings: DeviceSettings?
    private var internalTracks: [String: [BalloonTrackPoint]] = [:]
    private var internalLandingPoints: [String: CLLocationCoordinate2D] = [:]
    
    init() {
        // PersistenceService initializing (log removed for reduction)
        
        // Load user settings
        self.userSettings = Self.loadUserSettings()
        
        // Load device settings
        self.deviceSettings = Self.loadDeviceSettings()
        
        // Load tracks
        self.internalTracks = Self.loadAllTracks()
        
        // Load landing points
        self.internalLandingPoints = Self.loadAllLandingPoints()
        
        appLog("PersistenceService: Tracks loaded from UserDefaults. Total tracks: \(internalTracks.count)", category: .service, level: .info)
    }
    
    // MARK: - User Settings
    
    func save(userSettings: UserSettings) {
        self.userSettings = userSettings
        
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(userSettings) {
            userDefaults.set(encoded, forKey: "UserSettings")
            appLog("PersistenceService: UserSettings saved to UserDefaults.", category: .service, level: .debug)
        }
    }
    
    func readPredictionParameters() -> UserSettings? {
        return userSettings
    }
    
    private static func loadUserSettings() -> UserSettings {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "UserSettings"),
           let userSettings = try? decoder.decode(UserSettings.self, from: data) {
            appLog("PersistenceService: UserSettings loaded from UserDefaults.", category: .service, level: .debug)
            return userSettings
        } else {
            let defaultSettings = UserSettings()
            appLog("PersistenceService: UserSettings not found, using defaults.", category: .service, level: .debug)
            return defaultSettings
        }
    }
    
    // MARK: - Device Settings
    
    func save(deviceSettings: DeviceSettings) {
        self.deviceSettings = deviceSettings
        
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(deviceSettings) {
            userDefaults.set(encoded, forKey: "DeviceSettings")
            appLog("PersistenceService: deviceSettings saved: \(deviceSettings)", category: .service, level: .debug)
        }
    }
    
    private static func loadDeviceSettings() -> DeviceSettings? {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "DeviceSettings"),
           let deviceSettings = try? decoder.decode(DeviceSettings.self, from: data) {
            return deviceSettings
        }
        return nil
    }
    
    // MARK: - Track Management
    
    func saveBalloonTrack(sondeName: String, track: [BalloonTrackPoint]) {
        internalTracks[sondeName] = track
        saveAllTracks()
        appLog("PersistenceService: Saved balloon track for sonde '\(sondeName)'.", category: .service, level: .debug)
    }
    
    func loadTrackForCurrentSonde(sondeName: String) -> [BalloonTrackPoint]? {
        return internalTracks[sondeName]
    }
    
    func purgeAllTracks() {
        internalTracks.removeAll()
        userDefaults.removeObject(forKey: "BalloonTracks")
        appLog("PersistenceService: All balloon tracks purged.", category: .service, level: .debug)
    }
    
    func saveOnAppClose(balloonTrackService: BalloonTrackService) {
        if let currentName = balloonTrackService.currentBalloonName {
            let track = balloonTrackService.getAllTrackPoints()
            saveBalloonTrack(sondeName: currentName, track: track)
            appLog("PersistenceService: Saved current balloon track for sonde '\(currentName)' on app close.", category: .service, level: .info)
        }
    }
    
    private func saveAllTracks() {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(internalTracks) {
            // Save to both UserDefaults (for production) and Documents directory (for development persistence)
            userDefaults.set(encoded, forKey: "BalloonTracks")
            saveToDocumentsDirectory(data: encoded, filename: "BalloonTracks.json")
        }
    }
    
    private static func loadAllTracks() -> [String: [BalloonTrackPoint]] {
        let decoder = JSONDecoder()
        
        // Try Documents directory first (survives development installs)
        if let data = loadFromDocumentsDirectory(filename: "BalloonTracks.json"),
           let tracks = try? decoder.decode([String: [BalloonTrackPoint]].self, from: data) {
            appLog("PersistenceService: Loaded tracks from Documents directory", category: .service, level: .debug)
            return tracks
        }
        
        // Fallback to UserDefaults (for production)
        if let data = UserDefaults.standard.data(forKey: "BalloonTracks"),
           let tracks = try? decoder.decode([String: [BalloonTrackPoint]].self, from: data) {
            appLog("PersistenceService: Loaded tracks from UserDefaults", category: .service, level: .debug)
            return tracks
        }
        
        appLog("PersistenceService: No existing tracks found", category: .service, level: .debug)
        return [:]
    }
    
    // MARK: - Landing Points
    
    func saveLandingPoint(sondeName: String, coordinate: CLLocationCoordinate2D) {
        internalLandingPoints[sondeName] = coordinate
        saveAllLandingPoints()
    }
    
    func loadLandingPoint(sondeName: String) -> CLLocationCoordinate2D? {
        return internalLandingPoints[sondeName]
    }
    
    private func saveAllLandingPoints() {
        let landingPointsData = internalLandingPoints.mapValues { coord in
            ["latitude": coord.latitude, "longitude": coord.longitude]
        }
        userDefaults.set(landingPointsData, forKey: "LandingPoints")
    }
    
    private static func loadAllLandingPoints() -> [String: CLLocationCoordinate2D] {
        if let data = UserDefaults.standard.object(forKey: "LandingPoints") as? [String: [String: Double]] {
            return data.compactMapValues { dict in
                guard let lat = dict["latitude"], let lon = dict["longitude"] else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return [:]
    }
    
    // MARK: - Documents Directory Helpers
    
    private func saveToDocumentsDirectory(data: Data, filename: String) {
        do {
            let documentsURL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let fileURL = documentsURL.appendingPathComponent(filename)
            try data.write(to: fileURL)
            appLog("PersistenceService: Saved \(filename) to Documents directory", category: .service, level: .debug)
        } catch {
            appLog("PersistenceService: Failed to save \(filename) to Documents directory: \(error)", category: .service, level: .error)
        }
    }
    
    private static func loadFromDocumentsDirectory(filename: String) -> Data? {
        do {
            let documentsURL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let fileURL = documentsURL.appendingPathComponent(filename)
            let data = try Data(contentsOf: fileURL)
            appLog("PersistenceService: Loaded \(filename) from Documents directory", category: .service, level: .debug)
            return data
        } catch {
            appLog("PersistenceService: Failed to load \(filename) from Documents directory: \(error)", category: .service, level: .debug)
            return nil
        }
    }
}

// MARK: - Supporting Types and Extensions

// EventBus types removed - using direct telemetry communication


// Error types
enum PredictionError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case noData
    case networkUnavailable(String)
    case decodingError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from prediction service"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .noData:
            return "No data received"
        case .networkUnavailable(let reason):
            return "Network unavailable: \(reason)"
        case .decodingError(let description):
            return "JSON decoding failed: \(description)"
        }
    }
}

enum RouteError: Error, LocalizedError {
    case noRouteFound
    case invalidLocation
    
    var errorDescription: String? {
        switch self {
        case .noRouteFound:
            return "No route could be calculated"
        case .invalidLocation:
            return "Invalid location coordinates"
        }
    }
}

// MARK: - BalloonTrackPredictionService

@MainActor
// REMOVED: BalloonTrackPredictionService merged into PredictionService above
/* final class BalloonTrackPredictionService: ObservableObject {
    
    // MARK: - Dependencies (Direct References)
    
    private let predictionService: PredictionService
    private let predictionCache: PredictionCache
    private weak var serviceCoordinator: ServiceCoordinator?  // Weak reference to avoid retain cycle
    private let userSettings: UserSettings
    private let balloonTrackService: BalloonTrackService
    
    // MARK: - Service State
    
    @Published var isRunning: Bool = false
    @Published var hasValidPrediction: Bool = false
    @Published var lastPredictionTime: Date?
    @Published var predictionStatus: String = "Not started"
    
    private var internalTimer: Timer?
    private let predictionInterval: TimeInterval = 60.0  // 60 seconds per requirements
    private var lastProcessedTelemetry: TelemetryData?
    
    // MARK: - Initialization
    
    init(
        predictionService: PredictionService,
        predictionCache: PredictionCache,
        serviceCoordinator: ServiceCoordinator,
        userSettings: UserSettings,
        balloonTrackService: BalloonTrackService
    ) {
        self.predictionService = predictionService
        self.predictionCache = predictionCache
        self.serviceCoordinator = serviceCoordinator
        self.userSettings = userSettings
        self.balloonTrackService = balloonTrackService
        
        appLog("🎯 BalloonTrackPredictionService: Initialized as independent service", category: .service, level: .info)
    }
    
    // MARK: - Service Lifecycle
    
    func start() {
        guard !isRunning else {
            appLog("🎯 BalloonTrackPredictionService: Already running", category: .service, level: .debug)
            return
        }
        
        isRunning = true
        predictionStatus = "Running"
        startInternalTimer()
        
        appLog("🎯 BalloonTrackPredictionService: Service started with 60-second interval", category: .service, level: .info)
    }
    
    func stop() {
        isRunning = false
        predictionStatus = "Stopped"
        stopInternalTimer()
        
        appLog("🎯 BalloonTrackPredictionService: Service stopped", category: .service, level: .info)
    }
    
    // MARK: - Internal Timer Implementation
    
    private func startInternalTimer() {
        stopInternalTimer() // Ensure no duplicate timers
        
        internalTimer = Timer.scheduledTimer(withTimeInterval: predictionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleTimerTrigger()
            }
        }
        
        appLog("🎯 BalloonTrackPredictionService: Internal 60-second timer started", category: .service, level: .info)
    }
    
    private func stopInternalTimer() {
        internalTimer?.invalidate()
        internalTimer = nil
    }
    
    private func handleTimerTrigger() async {
        guard isRunning else { return }
        
        // Timer trigger: every 60 seconds
        guard let serviceCoordinator = serviceCoordinator,
              let telemetry = serviceCoordinator.balloonTelemetry else {
            predictionStatus = "No telemetry available"
            appLog("🎯 BalloonTrackPredictionService: Timer trigger - no telemetry", category: .service, level: .debug)
            return
        }
        
        appLog("🎯 BalloonTrackPredictionService: Timer trigger - performing prediction", category: .service, level: .info)
        await performPrediction(telemetry: telemetry, trigger: "60s_timer")
    }
    
    // MARK: - Public Trigger Methods
    
    /// Trigger: At startup after first valid telemetry
    func handleStartupTelemetry(_ telemetry: TelemetryData) async {
        guard isRunning else { return }
        
        // Check if this is first telemetry
        if lastProcessedTelemetry == nil {
            appLog("🎯 BalloonTrackPredictionService: Startup trigger - first telemetry received", category: .service, level: .info)
            await performPrediction(telemetry: telemetry, trigger: "startup")
        }
        
        lastProcessedTelemetry = telemetry
    }
    
    /// Trigger: Manual prediction request (balloon tap)
    func triggerManualPrediction() async {
        guard isRunning else {
            appLog("🎯 BalloonTrackPredictionService: Manual trigger ignored - service not running", category: .service, level: .debug)
            return
        }
        
        guard let serviceCoordinator = serviceCoordinator,
              let telemetry = serviceCoordinator.balloonTelemetry else {
            predictionStatus = "No telemetry for manual prediction"
            appLog("🎯 BalloonTrackPredictionService: Manual trigger - no telemetry", category: .service, level: .debug)
            return
        }
        
        appLog("🎯 BalloonTrackPredictionService: Manual trigger - performing prediction", category: .service, level: .info)
        await performPrediction(telemetry: telemetry, trigger: "manual")
    }
    
    /// Trigger: Significant movement or altitude changes
    func handleSignificantChange(_ telemetry: TelemetryData) async {
        guard isRunning else { return }
        
        // TODO: Implement movement/altitude thresholds
        // For now, let the timer handle regular updates
        
        lastProcessedTelemetry = telemetry
    }
    
    // MARK: - Core Prediction Logic
    
    private func performPrediction(telemetry: TelemetryData, trigger: String) async {
        predictionStatus = "Processing prediction..."
        
        do {
            // Determine if balloon is descending (balloonDescends flag)
            let balloonDescends = telemetry.verticalSpeed < 0
            appLog("🎯 BalloonTrackPredictionService: Balloon descending: \(balloonDescends) (verticalSpeed: \(telemetry.verticalSpeed) m/s)", category: .service, level: .info)
            
            // Calculate effective descent rate per requirements
            let effectiveDescentRate = calculateEffectiveDescentRate(telemetry: telemetry)
            
            // Create cache key for deduplication
            let cacheKey = createCacheKey(telemetry)
            
            // Check cache first for performance
            if let cachedPrediction = await predictionCache.get(key: cacheKey) {
                appLog("🎯 BalloonTrackPredictionService: Using cached prediction", category: .service, level: .info)
                await handlePredictionResult(cachedPrediction, trigger: trigger)
                return
            }
            
            // Call prediction service with all requirements implemented
            let predictionData = try await predictionService.fetchPrediction(
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
            predictionStatus = "Prediction failed: \(error.localizedDescription)"
            appLog("🎯 BalloonTrackPredictionService: Prediction failed from \(trigger): \(error)", category: .service, level: .error)
        }
    }
    
    private func calculateEffectiveDescentRate(telemetry: TelemetryData) -> Double {
        // Requirements: Use automatically adjusted descent rate below 10000m
        if telemetry.altitude < 10000, let smoothedRate = serviceCoordinator?.smoothedDescentRate {
            appLog("🎯 BalloonTrackPredictionService: Using smoothed descent rate: \(String(format: "%.2f", abs(smoothedRate))) m/s (below 10000m)", category: .service, level: .info)
            return abs(smoothedRate)
        } else {
            appLog("🎯 BalloonTrackPredictionService: Using settings descent rate: \(String(format: "%.2f", userSettings.descentRate)) m/s (above 10000m)", category: .service, level: .info)
            return userSettings.descentRate
        }
    }
    
    private func createCacheKey(_ telemetry: TelemetryData) -> String {
        // Simple cache key based on rounded coordinates and altitude
        let latRounded = round(telemetry.latitude * 1000) / 1000
        let lonRounded = round(telemetry.longitude * 1000) / 1000
        let altRounded = round(telemetry.altitude / 100) * 100 // Round to nearest 100m
        return "\(telemetry.sondeName)-\(latRounded)-\(lonRounded)-\(Int(altRounded))"
    }
    
    // MARK: - Result Handling & Direct Service Integration
    
    private func handlePredictionResult(_ predictionData: PredictionData, trigger: String) async {
        // Update service state
        hasValidPrediction = true
        lastPredictionTime = Date()
        predictionStatus = "Valid prediction available"
        
        // Direct ServiceCoordinator updates (no EventBus)
        updateServiceCoordinator(predictionData)
        
        // Landing point is already updated directly in ServiceCoordinator above
        
        appLog("🎯 BalloonTrackPredictionService: Prediction completed successfully from \(trigger)", category: .service, level: .info)
    }
    
    private func updateServiceCoordinator(_ predictionData: PredictionData) {
        guard let serviceCoordinator = serviceCoordinator else {
            appLog("🎯 BalloonTrackPredictionService: ServiceCoordinator is nil, cannot update", category: .service, level: .error)
            return
        }
        
        // Convert prediction path to polyline
        if let path = predictionData.path, !path.isEmpty {
            let polyline = MKPolyline(coordinates: path, count: path.count)
            serviceCoordinator.predictionPath = polyline
        }
        
        // Update burst point
        if let burstPoint = predictionData.burstPoint {
            serviceCoordinator.burstPoint = CLLocationCoordinate2D(latitude: burstPoint.latitude, longitude: burstPoint.longitude)
        }
        
        // Update landing point
        if let landingPoint = predictionData.landingPoint {
            serviceCoordinator.landingPoint = CLLocationCoordinate2D(latitude: landingPoint.latitude, longitude: landingPoint.longitude)
        }
        
        appLog("🎯 BalloonTrackPredictionService: Updated ServiceCoordinator directly", category: .service, level: .info)
    }
    
    
    // MARK: - Service Status & Monitoring
    
    var statusSummary: String {
        let status = isRunning ? "Running" : "Stopped"
        let prediction = hasValidPrediction ? "Valid" : "None"
        let lastTime = lastPredictionTime?.timeIntervalSinceNow ?? 0
        return "🎯 BalloonTrackPredictionService: \(status), Prediction: \(prediction), Last: \(String(format: "%.0f", abs(lastTime)))s ago"
    }
    
    deinit {
        internalTimer?.invalidate()
        internalTimer = nil
    }
*/ // End of removed BalloonTrackPredictionService

// MARK: - Manual Trigger Integration

extension Notification.Name {
    static let manualPredictionRequested = Notification.Name("manualPredictionRequested")
    static let startupCompleted = Notification.Name("startupCompleted")
    static let locationReady = Notification.Name("locationReady")
}
