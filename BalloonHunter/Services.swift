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

// UserSettings moved to Settings.swift

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

enum LandingPredictionSource: String, Codable {
    case sondehub
    case manual
}

struct LandingPredictionPoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let predictedAt: Date
    let landingEta: Date?
    let source: LandingPredictionSource

    init(coordinate: CLLocationCoordinate2D, predictedAt: Date, landingEta: Date?, source: LandingPredictionSource) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.predictedAt = predictedAt
        self.landingEta = landingEta
        self.source = source
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distance(from other: LandingPredictionPoint) -> CLLocationDistance {
        coordinate.distance(from: other.coordinate)
    }
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


// AppSettings moved to Settings.swift

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
    @Published var significantMovementLocation: LocationData? = nil // Only updates on 10m+ movement
    @Published var distanceOverlayText: String = "--" // Formatted distance text for overlay display
    @Published var isWithin200mOfBalloon: Bool = false // For navigation logic

    // Dual location managers for different operational modes
    private let backgroundLocationManager = CLLocationManager() // 30-second updates, standard accuracy
    private let precisionLocationManager = CLLocationManager()  // 1-2 second updates, best accuracy

    private var lastHeading: Double? = nil
    private var lastLocationTime: Date? = nil
    private var lastLocationUpdate: Date? = nil
    private var lastSignificantMovementLocation: CLLocationCoordinate2D? = nil
    private var currentBalloonDisplayPosition: CLLocationCoordinate2D?
    private var isHeadingModeActive: Bool = false
    private var backgroundTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // Location service operational modes
    enum LocationMode {
        case background  // 30-second updates, standard accuracy for tracking
        case precision   // 1-2 second updates, best accuracy for heading mode
    }

    
    override init() {
        super.init()
        setupLocationManagers()
        startBackgroundLocationService()
        appLog("CurrentLocationService: Initialized with dual-mode architecture (background active)", category: .service, level: .info)
    }

    private func setupLocationManagers() {
        // Configure background location manager
        backgroundLocationManager.delegate = self
        backgroundLocationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters // ~10m accuracy
        backgroundLocationManager.distanceFilter = 10.0 // Update on 10m movement

        // Configure precision location manager
        precisionLocationManager.delegate = self
        precisionLocationManager.desiredAccuracy = kCLLocationAccuracyBest // ~3-5m accuracy
        precisionLocationManager.distanceFilter = 2.0 // Update on 2m movement
    }
    
    // MARK: - Mode Switching

    func enableHeadingMode() {
        guard !isHeadingModeActive else { return }
        isHeadingModeActive = true

        appLog("CurrentLocationService: Enabling precision mode for heading view", category: .service, level: .info)
        precisionLocationManager.startUpdatingLocation()
    }

    func disableHeadingMode() {
        guard isHeadingModeActive else { return }
        isHeadingModeActive = false

        appLog("CurrentLocationService: Disabling precision mode, returning to background mode", category: .service, level: .info)
        precisionLocationManager.stopUpdatingLocation()
    }

    private func startBackgroundLocationService() {
        // Start 30-second timer for background location updates
        backgroundTimer?.invalidate()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestSingleBackgroundUpdate()
            }
        }

        // Get initial location immediately
        requestSingleBackgroundUpdate()
        appLog("CurrentLocationService: Background location service started (30-second intervals)", category: .service, level: .info)
    }

    private func requestSingleBackgroundUpdate() {
        backgroundLocationManager.requestLocation()
    }

    func requestPermission() {
        backgroundLocationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        backgroundLocationManager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse:
            isLocationPermissionGranted = true
            backgroundLocationManager.startUpdatingLocation()

            // Request "Always" permission for better background operation
            backgroundLocationManager.requestAlwaysAuthorization()
            publishHealthEvent(.healthy, message: "Location permission granted (when in use)")

        case .authorizedAlways:
            isLocationPermissionGranted = true
            backgroundLocationManager.startUpdatingLocation()

            // Enable significant location changes for background updates
            backgroundLocationManager.startMonitoringSignificantLocationChanges()
            publishHealthEvent(.healthy, message: "Location permission granted (always)")

        case .denied, .restricted:
            isLocationPermissionGranted = false
            publishHealthEvent(.unhealthy("Location permission denied"), message: "Location permission denied")
        case .notDetermined:
            // Request when-in-use first, then upgrade to always
            backgroundLocationManager.requestWhenInUseAuthorization()
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
            let isFirstUpdate = self.locationData == nil

            // Determine which manager provided this update
            let isFromPrecisionManager = manager === self.precisionLocationManager
            let modeString = isFromPrecisionManager ? "PRECISION" : "BACKGROUND"

            // Rate limiting for precision mode (1-2 second intervals)
            if isFromPrecisionManager {
                if let lastUpdate = self.lastLocationUpdate {
                    let timeSinceLastUpdate = now.timeIntervalSince(lastUpdate)
                    if timeSinceLastUpdate < 1.0 && !isFirstUpdate {
                        return // Skip update - too frequent for precision mode
                    }
                }
            }

            // Calculate movement distance for logging
            var distanceDiff: Double = 0
            if let previousLocation = self.locationData {
                let prevCLLocation = CLLocation(latitude: previousLocation.latitude, longitude: previousLocation.longitude)
                distanceDiff = location.distance(from: prevCLLocation)
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

            // Update significant movement location (10m threshold)
            self.updateSignificantMovementLocation(newLocationData)

            // Update distance overlay and proximity status
            self.updateDistanceOverlay()
            self.updateProximityStatus()

            if isFirstUpdate {
                appLog("Initial user location [\(modeString)]: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude)", category: .service, level: .info)
            } else if distanceDiff > 20 { // Log significant movement (>20m)
                appLog("User location update [\(modeString)]: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude), dist=\(Int(distanceDiff))m", category: .service, level: .debug)
            }
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

    private func updateSignificantMovementLocation(_ newLocation: LocationData) {
        // Check if this is the first location or movement exceeds 10m threshold
        guard let lastSignificantLocation = lastSignificantMovementLocation else {
            // First location update - always record
            significantMovementLocation = newLocation
            lastSignificantMovementLocation = CLLocationCoordinate2D(
                latitude: newLocation.latitude,
                longitude: newLocation.longitude
            )
            return
        }

        let currentCoordinate = CLLocationCoordinate2D(
            latitude: newLocation.latitude,
            longitude: newLocation.longitude
        )

        let movementDistance = CLLocation(
            latitude: lastSignificantLocation.latitude,
            longitude: lastSignificantLocation.longitude
        ).distance(from: CLLocation(
            latitude: currentCoordinate.latitude,
            longitude: currentCoordinate.longitude
        ))

        if movementDistance >= 10.0 {
            // Update significant movement location when 10m+ movement detected
            significantMovementLocation = newLocation
            lastSignificantMovementLocation = currentCoordinate
            appLog("CurrentLocationService: Significant movement detected (\(Int(movementDistance))m) - updating significant movement location", category: .service, level: .debug)
        }
    }

    // MARK: - Distance and Proximity Calculations

    private func updateDistanceOverlay() {
        guard let userLocation = locationData,
              let balloonPosition = currentBalloonDisplayPosition else {
            distanceOverlayText = "--"
            return
        }

        let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let distance = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            .distance(from: CLLocation(latitude: balloonPosition.latitude, longitude: balloonPosition.longitude))

        if distance < 1000 {
            distanceOverlayText = "\(Int(distance))m"
        } else {
            distanceOverlayText = String(format: "%.1fkm", distance / 1000)
        }
    }

    private func updateProximityStatus() {
        guard let userLocation = locationData,
              let balloonPosition = currentBalloonDisplayPosition else {
            isWithin200mOfBalloon = false
            return
        }

        let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let distance = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            .distance(from: CLLocation(latitude: balloonPosition.latitude, longitude: balloonPosition.longitude))

        isWithin200mOfBalloon = distance < 200
    }

    func updateBalloonDisplayPosition(_ position: CLLocationCoordinate2D?) {
        currentBalloonDisplayPosition = position
        updateDistanceOverlay()
        updateProximityStatus()
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

        // Debug landing detection criteria
        appLog(String(format: "🎯 LANDING: points=%d altSpread=%.1fm radius=%.1fm speed=%.1fkm/h confidence=%.1f%% → landed=%@",
                      window30.count, altSpread30, radius30, smoothedHorizontalSpeedKmh, landingConfidence * 100, isLandedNow ? "YES" : "NO"),
               category: .general, level: .info)

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

            appLog("BalloonTrackService: Balloon LANDED — altSpread30=\(String(format: "%.2f", altSpread30))m, radius30=\(String(format: "%.1f", radius30))m", category: .service, level: .info)

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

// MARK: - Prediction Service (moved)
/* PredictionService moved to BalloonHunter/PredictionService.swift */

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


// MARK: - Persistence Service

@MainActor
final class PersistenceService: ObservableObject {
    private let userDefaults = UserDefaults.standard
    
    // Internal storage for cached data
    @Published var userSettings: UserSettings
    @Published var deviceSettings: DeviceSettings?
    private var internalTracks: [String: [BalloonTrackPoint]] = [:]
    private var internalLandingHistories: [String: [LandingPredictionPoint]] = [:]
    
    init() {
        // PersistenceService initializing (log removed for reduction)
        
        // Load user settings
        self.userSettings = Self.loadUserSettings()
        
        // Load device settings
        self.deviceSettings = Self.loadDeviceSettings()
        
        // Load tracks
        self.internalTracks = Self.loadAllTracks()
        
        // Load landing point histories
        self.internalLandingHistories = Self.loadAllLandingHistories()
        
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
    
    func saveOnAppClose(balloonTrackService: BalloonTrackService,
                        landingPointTrackingService: LandingPointTrackingService) {
        if let currentName = balloonTrackService.currentBalloonName {
            let track = balloonTrackService.getAllTrackPoints()
            saveBalloonTrack(sondeName: currentName, track: track)
            appLog("PersistenceService: Saved current balloon track for sonde '\(currentName)' on app close.", category: .service, level: .info)
        }
        landingPointTrackingService.persistCurrentHistory()
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
    
    func saveLandingHistory(sondeName: String, history: [LandingPredictionPoint]) {
        internalLandingHistories[sondeName] = history
        saveAllLandingHistories()
    }

    func loadLandingHistory(sondeName: String) -> [LandingPredictionPoint]? {
        internalLandingHistories[sondeName]
    }

    func removeLandingHistory(for sondeName: String) {
        internalLandingHistories.removeValue(forKey: sondeName)
        saveAllLandingHistories()
    }

    func purgeAllLandingHistories() {
        internalLandingHistories.removeAll()
        userDefaults.removeObject(forKey: "LandingPointHistories")
        removeFromDocumentsDirectory(filename: "LandingPointHistories.json")
        appLog("PersistenceService: Purged all landing point histories", category: .service, level: .debug)
    }

    private func saveAllLandingHistories() {
        let encoder = JSONEncoder()
        guard let encoded = try? encoder.encode(internalLandingHistories) else { return }
        userDefaults.set(encoded, forKey: "LandingPointHistories")
        saveToDocumentsDirectory(data: encoded, filename: "LandingPointHistories.json")
    }

    private static func loadAllLandingHistories() -> [String: [LandingPredictionPoint]] {
        let decoder = JSONDecoder()

        if let data = loadFromDocumentsDirectory(filename: "LandingPointHistories.json"),
           let histories = try? decoder.decode([String: [LandingPredictionPoint]].self, from: data) {
            appLog("PersistenceService: Loaded landing histories from Documents directory", category: .service, level: .debug)
            return histories
        }

        if let data = UserDefaults.standard.data(forKey: "LandingPointHistories"),
           let histories = try? decoder.decode([String: [LandingPredictionPoint]].self, from: data) {
            appLog("PersistenceService: Loaded landing histories from UserDefaults", category: .service, level: .debug)
            return histories
        }

        // Legacy support for single landing point storage
        if let legacy = UserDefaults.standard.object(forKey: "LandingPoints") as? [String: [String: Double]] {
            let converted = legacy.compactMapValues { dict -> [LandingPredictionPoint]? in
                guard let lat = dict["latitude"], let lon = dict["longitude"] else { return nil }
                let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                let legacyPoint = LandingPredictionPoint(coordinate: coordinate, predictedAt: Date.distantPast, landingEta: nil, source: .sondehub)
                return [legacyPoint]
            }
            return converted
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
    
    private func removeFromDocumentsDirectory(filename: String) {
        do {
            let documentsURL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let fileURL = documentsURL.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            appLog("PersistenceService: Failed to remove \(filename) from Documents directory: \(error)", category: .service, level: .debug)
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

extension CLLocationCoordinate2D {
    func distance(from other: CLLocationCoordinate2D) -> CLLocationDistance {
        let loc1 = CLLocation(latitude: latitude, longitude: longitude)
        let loc2 = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return loc1.distance(from: loc2)
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
