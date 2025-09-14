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

// Flight phase of the balloon
enum BalloonPhase: String, Codable {
    case ascending
    case descendingAbove10k
    case descendingBelow10k
    case landed
    case unknown
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
            probeType = normalizeProbeType(components[1])
            frequency = Double(components[2]) ?? 0.0
            signalStrength = Int(Double(components[3]) ?? 0.0)
            batteryPercentage = Int(components[4]) ?? 0
            batteryVoltage = Double(components[5]) ?? 0.0
            buzmute = components[6] == "1"
            softwareVersion = components[7]
            
        case "1":
            // Type 1: Probe Telemetry (20 fields)
            guard components.count >= 20 else { return }
            probeType = normalizeProbeType(components[1])
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
            probeType = normalizeProbeType(components[1])
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
    
    /// Normalize probe type string to handle device abbreviations
    private func normalizeProbeType(_ input: String) -> String {
        let upperCaseType = input.uppercased()
        switch upperCaseType {
        case "PIL":
            return "PILOT"
        default:
            return upperCaseType
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
    let launchPoint: CLLocationCoordinate2D?
    let burstAltitude: Double?
    let flightTime: TimeInterval?
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
    case service = "Service"
    case ui = "UI"
    case cache = "Cache"
    case general = "General"
    case persistence = "Persistence"
    case ble = "BLE"
    case lifecycle = "Lifecycle"
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
        // Suppress verbose position update log in debug output
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

        // Development CSV logging (DEBUG only)
        #if DEBUG
        DebugCSVLogger.shared.logTelemetry(telemetryData)
        #endif

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
        let window10 = currentBalloonTrack.filter { now.timeIntervalSince($0.timestamp) <= 10.0 }

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
        
        // Landed decision (≤30s worst-case): altitude hardly changes and horizontal drift tiny
        // Relaxed thresholds to account for GPS jitter
        let isLandedNow = hasRecentTelemetry && window30.count >= 10 && altSpread30 < 2.0 && radius30 < 10.0 && smoothedHorizontalSpeedKmh < 2.0
        
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
            
            appLog("BalloonTrackService: Balloon LANDED — altSpread30=\(String(format: "%.2f", altSpread30))m, radius30=\(String(format: "%.1f", radius30))m", category: .service, level: .info)
            
        } else if wasPreviouslyFlying && isBalloonFlying {
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

        // Hysteresis to clear landed: if recent movement is clear in last 10s
        if isBalloonLanded {
            let altSpread10 = altSpread(window10)
            let radius10 = p95Radius(window10)
            if altSpread10 > 3.0 || radius10 > 12.0 || smoothedHorizontalSpeedKmh > 3.0 {
                isBalloonLanded = false
                appLog("BalloonTrackService: Landed CLEARED — altSpread10=\(String(format: "%.2f", altSpread10))m, radius10=\(String(format: "%.1f", radius10))m, hSpeed(avg)=\(String(format: "%.2f", smoothedHorizontalSpeedKmh)) km/h", category: .service, level: .info)
            }
        }
        
        // Periodic debug metrics while not landed (compile-time gated)
        #if DEBUG
        if !isBalloonLanded && window30.count >= 10 {
            let nowT = Date()
            if lastMetricsLog == nil || nowT.timeIntervalSince(lastMetricsLog!) > 10.0 {
                lastMetricsLog = nowT
                appLog("BalloonTrackService: Metrics — altSpread30=\(String(format: "%.2f", altSpread30))m, radius30=\(String(format: "%.1f", radius30))m, hSpeed(avg)=\(String(format: "%.2f", smoothedHorizontalSpeedKmh)) km/h", category: .service, level: .debug)
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

// MARK: - Prediction Service (moved)
/* PredictionService moved to BalloonHunter/PredictionService.swift */

// MARK: - Route Calculation Service

@MainActor
final class RouteCalculationService: ObservableObject {
    private let currentLocationService: CurrentLocationService
    
    init(currentLocationService: CurrentLocationService) {
        self.currentLocationService = currentLocationService
        appLog("RouteCalculationService init", category: .service, level: .debug)
    }
    
    func calculateRoute(from userLocation: LocationData, to destination: CLLocationCoordinate2D, transportMode: TransportationMode) async throws -> RouteData {
        // Log inputs
        appLog(String(format: "RouteCalculationService: Request src=(%.5f,%.5f) dst=(%.5f,%.5f) mode=%@",
                      userLocation.latitude, userLocation.longitude, destination.latitude, destination.longitude, transportMode.rawValue),
               category: .service, level: .debug)

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
        let preferredType: MKDirectionsTransportType = (transportMode == .car) ? .automobile : .cycling
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
