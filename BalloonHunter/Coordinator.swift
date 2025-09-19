import Foundation
import Combine
import SwiftUI
import CoreLocation
import CoreBluetooth
import MapKit
import OSLog
import UIKit


// MARK: - Landed Position Smoother
// Handles adaptive position smoothing for landed balloon display

@MainActor
class LandedPositionSmoother: ObservableObject {
    private var landedPositionBuffer: [CLLocationCoordinate2D] = []
    private let maxBufferSize = 60 // 60 seconds of data
    private let minSmoothingPoints = 5 // Minimum points for smoothing

    @Published var displayPosition: CLLocationCoordinate2D?
    @Published var smoothedPosition: CLLocationCoordinate2D?

    func updateLandedPosition(newPosition: CLLocationCoordinate2D, isLanded: Bool) {
        if isLanded {
            // Add to smoothing buffer
            landedPositionBuffer.append(newPosition)
            if landedPositionBuffer.count > maxBufferSize {
                landedPositionBuffer.removeFirst()
            }

            // Immediate display (no delay)
            if displayPosition == nil {
                displayPosition = newPosition
            }

            // Progressive smoothing
            updateSmoothedPosition()

        } else {
            // Not landed - clear buffer and use real-time position
            landedPositionBuffer.removeAll()
            displayPosition = newPosition
            smoothedPosition = nil
        }
    }

    private func updateSmoothedPosition() {
        guard landedPositionBuffer.count >= minSmoothingPoints else {
            // Not enough points yet - use weighted average of available data
            displayPosition = weightedAverage()
            return
        }

        // Full smoothing with available data
        let smoothed = calculateSmoothedPosition()
        smoothedPosition = smoothed

        // Gradually transition display position toward smoothed position
        displayPosition = interpolatePosition(
            from: displayPosition ?? smoothed,
            to: smoothed,
            factor: 0.1 // 10% step toward smoothed position each update
        )
    }

    private func weightedAverage() -> CLLocationCoordinate2D {
        let recent = landedPositionBuffer.suffix(min(landedPositionBuffer.count, 10))
        let lat = recent.map { $0.latitude }.reduce(0, +) / Double(recent.count)
        let lon = recent.map { $0.longitude }.reduce(0, +) / Double(recent.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func calculateSmoothedPosition() -> CLLocationCoordinate2D {
        // Use all available data (up to 60 points)
        let lat = landedPositionBuffer.map { $0.latitude }.reduce(0, +) / Double(landedPositionBuffer.count)
        let lon = landedPositionBuffer.map { $0.longitude }.reduce(0, +) / Double(landedPositionBuffer.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func interpolatePosition(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, factor: Double) -> CLLocationCoordinate2D {
        let lat = from.latitude + (to.latitude - from.latitude) * factor
        let lon = from.longitude + (to.longitude - from.longitude) * factor
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func reset() {
        landedPositionBuffer.removeAll()
        displayPosition = nil
        smoothedPosition = nil
    }
}

// MARK: - Coordinator
// Transitional class for service coordination and dependency injection

@MainActor
final class ServiceCoordinator: ObservableObject {
    // KEEP: Core services that provide real value
    let persistenceService: PersistenceService
    let predictionCache: PredictionCache  // Keep: has real performance value
    let routingCache: RoutingCache       // Keep: has real performance value
    
    // MARK: - Published Properties (moved from MapState)
    
    // Map visual elements
    @Published var annotations: [MapAnnotationItem] = []
    @Published var balloonTrackPath: MKPolyline? = nil
    @Published var predictionPath: MKPolyline? = nil
    @Published var userRoute: MKPolyline? = nil
    @Published var region: MKCoordinateRegion? = nil
    
    // Data state
    @Published var balloonTelemetry: TelemetryData? = nil
    @Published var userLocation: LocationData? = nil
    @Published var landingPoint: CLLocationCoordinate2D? = nil
    @Published var isBalloonLanded: Bool = false
    @Published var burstPoint: CLLocationCoordinate2D? = nil
    @Published var balloonDisplayPosition: CLLocationCoordinate2D? = nil // Smoothed position for display
    
    // Additional data for DataPanelView
    @Published var predictionData: PredictionData? = nil
    @Published var routeData: RouteData? = nil
    @Published var formattedRouteDistance: String = "--" // Formatted distance for UI display
    @Published var balloonTrackHistory: [TelemetryData] = []
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var smoothedDescentRate: Double? = nil
    @Published var smoothedVerticalSpeed: Double = 0.0
    @Published var smoothedHorizontalSpeed: Double = 0.0
    @Published var isTelemetryStale: Bool = false
    // Flight/landing time strings provided directly by PredictionService; UI binds there
    @Published var frequencyString: String = "0.000"
    @Published var deviceSettings: DeviceSettings?
    @Published var displayDescentRateString: String = "--"
    
    // AFC tracking (moved from SettingsView for proper separation of concerns)
    @Published var afcFrequencies: [Int] = []
    @Published var afcMovingAverage: Int = 0

    // Apple Maps navigation tracking
    private var hasStartedAppleMapsNavigation: Bool = false
    private var lastAppleMapsDestination: CLLocationCoordinate2D?
    
    // Startup sequence state
    @Published var startupProgress: String = "Initializing services..."
    @Published var currentStartupStep: Int = 0
    @Published var isStartupComplete: Bool = false
    @Published var showLogo: Bool = true
    @Published var showTrackingMap: Bool = false

    // UI state
    @Published var isHeadingMode: Bool = false {
        didSet {
            updateLocationServiceMode()
        }
    }
    @Published var isRouteVisible: Bool = true
    @Published var isBuzzerMuted: Bool = false
    @Published var showAllAnnotations: Bool = false
    @Published var suspendCameraUpdates: Bool = false
    
    // Core services (initialized in init for MapState dependencies)  
    let currentLocationService: CurrentLocationService
    let bleCommunicationService: BLECommunicationService
    
    // Phase 3: Prediction Service (lazy to avoid retain cycle)
    // Full-featured PredictionService with scheduling capabilities
    lazy var predictionService: PredictionService = {
        return PredictionService(
            predictionCache: self.predictionCache,
            serviceCoordinator: self,
            userSettings: self.userSettings,
            balloonTrackService: self.balloonTrackService
        )
    }()
    
    // REQUIRED: Services that generate the events and manage data (injected from AppServices)
    let balloonPositionService: BalloonPositionService
    let balloonTrackService: BalloonTrackService
    lazy var routeCalculationService = RouteCalculationService(currentLocationService: self.currentLocationService)
    
        // REPLACE: With direct service communication
    
    private var cancellables = Set<AnyCancellable>()
    private var lastRouteCalculationTime = Date.distantPast
    private var lastPredictionTime = Date.distantPast
    private var lastPredictionAttemptTime = Date.distantPast
    private var isPredictionInFlight: Bool = false
    private var predictionTimer: Timer? = nil
    private var hasTriggeredStartupPrediction: Bool = false
    private var lastUserLocation: CLLocationCoordinate2D?
    private var lastLandingPoint: CLLocationCoordinate2D?
    private var lastUserLocationUpdateTime = Date.distantPast
    
    // Simple timing constants (replace complex mode machine)
    private let routeUpdateInterval: TimeInterval = 60  // Always 60 seconds
    private let predictionInterval: TimeInterval = 60  // Every 60 seconds per requirements
    private let significantMovementThreshold: Double = 100  // meters
    
    // User settings reference (for external access)
    var userSettings = UserSettings()

    // App settings reference (for transport mode and other app-level settings)
    var appSettings: AppSettings?

    // Transport mode computed property (delegates to AppSettings)
    var transportMode: TransportationMode {
        get { appSettings?.transportMode ?? .car }
        set { appSettings?.transportMode = newValue }
    }

    // Adaptive position smoothing for landed balloons
    private let landedPositionSmoother = LandedPositionSmoother()

    // MARK: - Location Service Mode Management

    private func updateLocationServiceMode() {
        if isHeadingMode {
            currentLocationService.enableHeadingMode()
            appLog("ServiceCoordinator: Enabled precision location mode for heading view", category: .general, level: .info)
        } else {
            currentLocationService.disableHeadingMode()
            appLog("ServiceCoordinator: Disabled precision location mode, using background mode", category: .general, level: .info)
        }
    }

    // Adjusted descent rate now computed by BalloonTrackService

    // MARK: - Flight State Computed Properties
    private var isFlying: Bool {
        return balloonTrackService.balloonPhase != .landed &&
               balloonTrackService.balloonPhase != .unknown
    }

    private var isLanded: Bool {
        return balloonTrackService.balloonPhase == .landed
    }

    private var shouldShowNavigation: Bool {
        // Show navigation elements when flying OR when landed but more than 200m away
        if !isLanded { return true } // Always show when flying

        // When landed, check distance
        guard let userLocation = userLocation,
              let balloonPosition = balloonDisplayPosition ?? (balloonTelemetry != nil ?
                  CLLocationCoordinate2D(latitude: balloonTelemetry!.latitude, longitude: balloonTelemetry!.longitude) : nil) else {
            return false
        }

        let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let distance = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            .distance(from: CLLocation(latitude: balloonPosition.latitude, longitude: balloonPosition.longitude))

        return distance >= 200
    }

    // Phase 2: Telemetry counter for comparison logging
    private var telemetryCounter = 0
    
    init(
        bleCommunicationService: BLECommunicationService,
        currentLocationService: CurrentLocationService,
        persistenceService: PersistenceService,
        predictionCache: PredictionCache,
        routingCache: RoutingCache,
        balloonPositionService: BalloonPositionService,
        balloonTrackService: BalloonTrackService
    ) {
        appLog("ServiceCoordinator: Initializing simplified architecture with injected services", category: .general, level: .info)
        
        // Use injected services instead of creating new ones
        self.bleCommunicationService = bleCommunicationService
        self.currentLocationService = currentLocationService
        self.persistenceService = persistenceService
        self.predictionCache = predictionCache
        self.routingCache = routingCache
        self.balloonPositionService = balloonPositionService
        self.balloonTrackService = balloonTrackService
        
        setupDirectSubscriptions()
        
        appLog("ServiceCoordinator: Simplified architecture initialized", category: .general, level: .info)
    }
    
    func initialize() {
        appLog("========================================", category: .general, level: .info)
        // Start core services
        _ = currentLocationService
        _ = bleCommunicationService

        // Initialize the services that create events and manage data
        _ = balloonPositionService
        _ = balloonTrackService
        _ = routeCalculationService

        // Phase 3: Start 60-second coordinator timer for predictions
        appLog("STARTUP: Coordinator owns 60-second prediction timer", category: .general, level: .info)
        startCoordinatorPredictionTimer()


        // Services initialized - startup sequence will be triggered by BalloonHunterApp
    }

    func setAppSettings(_ settings: AppSettings) {
        appSettings = settings
        setupTransportModeSubscription()
        appLog("ServiceCoordinator: AppSettings reference set for transport mode persistence", category: .general, level: .debug)
    }

    private func setupTransportModeSubscription() {
        // Subscribe to transport mode changes for route recalculation
        NotificationCenter.default.publisher(for: .transportModeChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.updateRoute()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Startup Sequence (moved to CoordinatorServices.swift)
    
    // setupInitialMapView moved to CoordinatorServices.swift
    
    private func startBLEConnectionWithTimeout() async -> (connected: Bool, hasMessage: Bool) {
        appLog("ServiceCoordinator: BLE communication service connects to device", category: .general, level: .info)
        
        // Wait for Bluetooth to be powered on (reasonable timeout)
        let bluetoothTimeout = Date().addingTimeInterval(5) // 5 seconds for Bluetooth
        while bleCommunicationService.centralManager.state != .poweredOn && Date() < bluetoothTimeout {
            appLog("ServiceCoordinator: Waiting for Bluetooth to power on", category: .general, level: .info)
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second check interval
        }
        
        guard bleCommunicationService.centralManager.state == .poweredOn else {
            appLog("ServiceCoordinator: Bluetooth not powered on - display message and wait for connection", category: .general, level: .info)
            return (connected: false, hasMessage: false)
        }
        
        // Start scanning for MySondyGo devices
        appLog("ServiceCoordinator: Starting BLE scanning for MySondyGo devices", category: .general, level: .info)
        bleCommunicationService.startScanning()
        
        // Try to establish connection with 5-second timeout as per revised FSD
        let connectionTimeout = Date().addingTimeInterval(5) // 5 seconds to find and connect
        while !bleCommunicationService.isReadyForCommands && Date() < connectionTimeout {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second checks
        }
        
        if bleCommunicationService.isReadyForCommands {
            appLog("ServiceCoordinator: Connection established, ready for commands", category: .general, level: .info)
            return (connected: true, hasMessage: true)
        } else {
            appLog("ServiceCoordinator: No connection established - display message and wait", category: .general, level: .info)
            return (connected: false, hasMessage: false)
        }
    }
    
    private func waitForFirstBLEPackageAndPublishTelemetryStatus() async {
        appLog("ServiceCoordinator: Waiting for first BLE package to determine telemetry availability", category: .general, level: .info)
        
        // Wait up to 3 seconds for the first BLE message of any type
        let timeout = Date().addingTimeInterval(3)
        var hasReceivedFirstMessage = false
        
        while Date() < timeout && !hasReceivedFirstMessage {
            // Check if we've received any BLE messages (Type 0, 1, 2, or 3)
            if bleCommunicationService.latestTelemetry != nil || 
               !bleCommunicationService.deviceSettings.probeType.isEmpty ||
               bleCommunicationService.deviceSettings.frequency != 434.0 {
                hasReceivedFirstMessage = true
                
                // Publish telemetry availability status
                let telemetryAvailable = bleCommunicationService.latestTelemetry != nil
                appLog("ServiceCoordinator: First BLE package received, telemetry available: \(telemetryAvailable)", category: .general, level: .info)
                break
            }
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second checks
        }
        
        if !hasReceivedFirstMessage {
            appLog("ServiceCoordinator: No BLE package received within timeout", category: .general, level: .info)
        }
    }
    
    // Settings response handling removed from startup; BLE will fetch opportunistically
    
    // loadAllPersistenceData moved to CoordinatorServices.swift
    
    private func waitForBLEPacketsAndDetermineLandingPoint(bleConnected: Bool) async {
        appLog("ServiceCoordinator: Wait max 5 seconds for BLE packet signals", category: .general, level: .info)
        
        if !bleConnected {
            // No BLE connection - go straight to landing point determination
            appLog("ServiceCoordinator: No BLE connection - proceeding to landing point determination", category: .general, level: .info)
            await determineLandingPoint()
            return
        }
        
        // Use the BLE service's published telemetry availability state
        let isTelemetryAvailable = bleCommunicationService.telemetryAvailabilityState
        
        if isTelemetryAvailable {
            appLog("ServiceCoordinator: Telemetry available - BLE service confirms Type 1 message received", category: .general, level: .info)
            
            // Get telemetry data and process it
            if let telemetry = bleCommunicationService.latestTelemetry {
                balloonTelemetry = telemetry

                // Update balloon display position for flying balloons (landed balloons use position smoother)
                if !balloonTrackService.isBalloonLanded {
                    let telemetryPosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
                    balloonDisplayPosition = telemetryPosition
                    currentLocationService.updateBalloonDisplayPosition(telemetryPosition)
                }

                // Call balloon prediction service and routing service and wait for completion
                await processBalloonTelemetry()
            }
        } else {
            appLog("ServiceCoordinator: No telemetry available - BLE service reports no Type 1 messages", category: .general, level: .info)
        }
        
        // Determine valid landing point with FSD priority
        await determineLandingPoint()
    }
    
    private func processBalloonTelemetry() async {
        guard balloonTelemetry != nil else { return }
        
        appLog("ServiceCoordinator: Processing balloon telemetry - calling prediction and routing services", category: .general, level: .info)
        
        // Call balloon prediction service
        await predictionService.triggerManualPrediction()
        
        // Call routing service if we have user location
        if userLocation != nil {
            await updateRoute()
        }
        
        // Wait for completion
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second for services to complete
    }
    
    private func determineLandingPoint() async {
        appLog("ServiceCoordinator: Determining landing point per FSD priority order", category: .general, level: .info)
        
        // Priority 1: If telemetry received and balloon has landed, current position is landing point
        // Use simple criteria: low altitude OR low vertical speed (more permissive than original)
        if let telemetry = balloonTelemetry {
            let altitudeCheck = telemetry.altitude < 1000 && abs(telemetry.verticalSpeed) < 2.0
            let lowAltitudeCheck = telemetry.altitude < 500
            appLog("ServiceCoordinator: Landing check - altitude: \(Int(telemetry.altitude))m, vSpeed: \(String(format: "%.1f", telemetry.verticalSpeed))m/s, lowAlt: \(lowAltitudeCheck), combined: \(altitudeCheck)", category: .general, level: .info)
            
            if altitudeCheck || lowAltitudeCheck {
                let currentPosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
                landingPoint = currentPosition
                appLog("ServiceCoordinator: Landing point set from current balloon position (landed)", category: .general, level: .info)
                return
            }
        }
        
        // Priority 2: If balloon in flight, wait for and use predicted landing position
        if balloonTelemetry != nil {
            appLog("ServiceCoordinator: Telemetry available - waiting for prediction to complete", category: .general, level: .info)
            
            // Wait up to 10 seconds for prediction to complete
            let predictionTimeout = Date().addingTimeInterval(10)
            while Date() < predictionTimeout {
                if let predictedLanding = predictionData?.landingPoint {
                    landingPoint = predictedLanding
                    appLog("ServiceCoordinator: Landing point set from prediction", category: .general, level: .info)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second checks
            }
            
            appLog("ServiceCoordinator: Prediction timeout - falling back to other sources", category: .general, level: .info)
        }
        
        // Priority 3: Parse from clipboard
        await parseClipboardForLandingPoint()
        
        if landingPoint != nil {
            appLog("ServiceCoordinator: Landing point set from clipboard", category: .general, level: .info)
            return
        }
        
        // Priority 4: Use persisted landing point (already loaded in loadPersistenceData())
        if landingPoint != nil {
            appLog("ServiceCoordinator: Landing point set from persistence", category: .general, level: .info)
            return
        }
        
        appLog("ServiceCoordinator: No valid landing point available", category: .general, level: .info)
    }
    
    private func parseClipboardForLandingPoint() async {
        appLog("ServiceCoordinator: Attempting to parse landing point from clipboard", category: .general, level: .info)
        
        // Use existing clipboard parsing logic
        let _ = setLandingPointFromClipboard()
    }
    
    private func setupInitialMapDisplay() async {
        appLog("ServiceCoordinator: Display initial map with maximum zoom level showing all annotations", category: .general, level: .info)
        
        // Per FSD: Initial map uses maximum zoom level to show:
        // - The user position
        // - The landing position  
        // - If a balloon is flying, the route and predicted path
        
        // Map display setup complete (zoom handled at end of startup sequence)
        appLog("ServiceCoordinator: Initial map display setup complete", category: .general, level: .info)
    }
    
    // MARK: - Direct Event Handling
    
    private func setupDirectSubscriptions() {
        // Subscribe to telemetry changes for automatic predictions  
        balloonPositionService.$currentTelemetry
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }  // Filter out nil values
            .sink { [weak self] telemetryData in
                self?.handleBalloonTelemetry(telemetryData)
            }
            .store(in: &cancellables)
        
        // Subscribe to location changes and update MapState
        currentLocationService.$locationData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locationData in
                self?.handleUserLocation(locationData)
            }
            .store(in: &cancellables)
        
        // Subscribe to BLE connection status changes
        bleCommunicationService.$connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.connectionStatus = status
            }
            .store(in: &cancellables)
        
        // Subscribe to balloon track service for smoothed values
        balloonTrackService.$smoothedVerticalSpeed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speed in
                self?.smoothedVerticalSpeed = speed
            }
            .store(in: &cancellables)
            
        balloonTrackService.$smoothedHorizontalSpeed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speed in
                self?.smoothedHorizontalSpeed = speed
            }
            .store(in: &cancellables)
            
        balloonTrackService.$isTelemetryStale
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stale in
                self?.isTelemetryStale = stale
            }
            .store(in: &cancellables)
            
        // Subscribe to advanced landing detection from BalloonTrackService
        balloonTrackService.$isBalloonLanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasLanded in
                self?.isBalloonLanded = hasLanded
                if hasLanded, let position = self?.balloonTrackService.landingPosition {
                    // Advanced landing detection triggered - update landing point
                    self?.landingPoint = position
                    appLog("ServiceCoordinator: Advanced landing detection - landing point set to [\(String(format: "%.4f", position.latitude)), \(String(format: "%.4f", position.longitude))]", category: .general, level: .info)
                }
            }
            .store(in: &cancellables)

        // Subscribe to adjusted descent rate from BalloonTrackService
        balloonTrackService.$adjustedDescentRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                guard let self = self else { return }
                if let r = rate {
                    self.smoothedDescentRate = r
                    self.displayDescentRateString = String(format: "%.1f", abs(r))
                } else {
                    self.smoothedDescentRate = nil
                    self.displayDescentRateString = String(format: "%.1f", self.userSettings.descentRate)
                }
            }
            .store(in: &cancellables)
            
        // UI binds directly to PredictionService for time strings
            
        // Subscribe to device settings changes
        bleCommunicationService.$deviceSettings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                self?.deviceSettings = settings
                self?.frequencyString = String(format: "%.3f", settings.frequency)
            }
            .store(in: &cancellables)

        // Subscribe to landed position smoother for display position
        landedPositionSmoother.$displayPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] smoothedPos in
                self?.balloonDisplayPosition = smoothedPos
                self?.currentLocationService.updateBalloonDisplayPosition(smoothedPos)
            }
            .store(in: &cancellables)

        appLog("ServiceCoordinator: Setup direct telemetry, location, and BLE connection subscriptions", category: .general, level: .debug)
    }
        
    // MARK: - High-Level UI Methods for View Actions
    
    func triggerShowAllAnnotations() {
        appLog("🔍 ZOOM: ServiceCoordinator triggerShowAllAnnotations called (computing region)", category: .general, level: .info)
        updateCameraToShowAllAnnotations()
    }
    
    func triggerPrediction() {
        appLog("ServiceCoordinator: Manual prediction triggered from UI", category: .general, level: .info)

        // Don't make prediction API calls when balloon is landed
        guard !isLanded else {
            appLog("ServiceCoordinator: Skipping prediction - balloon is landed", category: .general, level: .info)
            return
        }

        guard let telemetry = balloonTelemetry else {
            appLog("ServiceCoordinator: No telemetry available for prediction", category: .general, level: .error)
            return
        }
        Task { @MainActor in
            await executePrediction(
                telemetry: telemetry,
                measuredDescentRate: smoothedDescentRate,
                force: true
            )
        }
    }
    
    func requestDeviceParameters() {
        appLog("ServiceCoordinator: Requesting device parameters from BLE device", category: .general, level: .info)
        bleCommunicationService.getParameters()
    }
    
    func setMuteState(_ muted: Bool) {
        appLog("ServiceCoordinator: Setting mute state to \(muted)", category: .general, level: .info)
        isBuzzerMuted = muted
        bleCommunicationService.setMute(muted)
    }
    
    func sendFrequencyAndTypeToDevice(frequency: Double, probeType: String) {
        appLog("ServiceCoordinator: Sending frequency \(frequency) MHz and type \(probeType) to device", category: .ble, level: .info)
        
        // Map probe type to command value (matching BLEService.ProbeType enum)
        let sondeTypeMapping = [
            "RS41": 1, "M20": 2, "M10": 3, "PILOT": 4, "DFM": 5
        ]
        let probeTypeNumber = sondeTypeMapping[probeType] ?? 1
        
        // Generate and send command
        let commandString = "o{f=\(String(format: "%.2f", frequency))/tipo=\(probeTypeNumber)}o"
        bleCommunicationService.sendCommand(command: commandString)
    }
    
    func saveDataOnAppClose() {
        appLog("ServiceCoordinator: Saving data on app close", category: .general, level: .info)
        persistenceService.saveOnAppClose(balloonTrackService: balloonTrackService)
    }
    
    
    // MARK: - Simplified Event Handlers
    
    
    
    // Direct telemetry handling with prediction timing
    private func handleBalloonTelemetry(_ telemetry: TelemetryData) {
        // Suppress verbose per-packet telemetry summary in debug logs

        // Update ServiceCoordinator with telemetry data (direct subscription)
        balloonTelemetry = telemetry
        // Keep frequency visible without waiting for device settings
        if telemetry.frequency > 0 {
            frequencyString = String(format: "%.3f", telemetry.frequency)
        }

        // Update AFC frequency tracking (moved from SettingsView for proper separation of concerns)
        updateAFCTracking(telemetry)

        // Update landed position smoother with new position
        let balloonPosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
        landedPositionSmoother.updateLandedPosition(newPosition: balloonPosition, isLanded: isBalloonLanded)

        // Adjusted descent rate is computed by BalloonTrackService; subscription updates UI

        // Update map with balloon position and annotations
        updateMapWithBalloonPosition(telemetry)
        
        // Startup trigger: first telemetry after launch -> immediate prediction once (but not if landed)
        if !hasTriggeredStartupPrediction && !isLanded {
            hasTriggeredStartupPrediction = true
            Task {
                await executePrediction(
                    telemetry: telemetry,
                    measuredDescentRate: smoothedDescentRate,
                    force: true
                )
            }
        }
    }
    
    // Direct location handling (replaces MapState subscription)
    private func handleUserLocation(_ locationData: LocationData?) {
        // Update ServiceCoordinator with location data (direct subscription)
        userLocation = locationData

        guard let locationData = locationData else { return }

        appLog(String(format: "User: lat=%.5f lon=%.5f alt=%.0f hAcc=%.1f vAcc=%.1f heading=%.0f",
                       locationData.latitude,
                       locationData.longitude,
                       locationData.altitude,
                       locationData.horizontalAccuracy,
                       locationData.verticalAccuracy,
                       locationData.heading),
               category: .general, level: .debug)
        
        // Direct ServiceCoordinator update - no parallel state needed
        
        // Check if route needs updating due to user movement
        let userCoord = CLLocationCoordinate2D(
            latitude: locationData.latitude, 
            longitude: locationData.longitude
        )
        
        let shouldUpdateForMovement = hasUserMovedSignificantly(to: userCoord)
        let shouldUpdateForTime = shouldUpdateRouteForUserMovement()
        
        if shouldUpdateForMovement && shouldUpdateForTime {
            appLog("ServiceCoordinator: User moved significantly after 1+ minute - triggering route update", category: .general, level: .info)
            lastUserLocationUpdateTime = Date()
            Task {
                await updateRoute()
            }
        }
        
        lastUserLocation = userCoord
        
        // Update map annotations to include user location
        if let telemetry = balloonTelemetry {
            updateMapWithBalloonPosition(telemetry)
        }
    }
    
    
    // MARK: - Prediction Logic
    
    // Manual prediction trigger for UI (balloon annotation tap)
    // Note: there is already a high-level triggerPrediction() earlier; keep single definition
    
    private func shouldRequestPrediction(_ telemetry: TelemetryData, force: Bool = false) -> Bool {
        // Never make prediction API calls when balloon is landed
        if isLanded {
            appLog("ServiceCoordinator: shouldRequestPrediction? landed=YES -> NO", category: .general, level: .debug)
            return false
        }

        if force {
            appLog("ServiceCoordinator: Prediction forced", category: .general, level: .debug)
            return true
        }

        // Time-based trigger with in-flight guard and attempt-based cooldown
        if isPredictionInFlight {
            appLog("ServiceCoordinator: shouldRequestPrediction? inFlight=YES -> NO", category: .general, level: .debug)
            return false
        }
        let timeSinceLastAttempt = Date().timeIntervalSince(lastPredictionAttemptTime)
        let shouldTrigger = timeSinceLastAttempt > predictionInterval
        appLog(String(format: "ServiceCoordinator: shouldRequestPrediction? sinceLastAttempt=%.1fs interval=%.0fs -> %@",
                      timeSinceLastAttempt,
                      predictionInterval,
                      shouldTrigger ? "YES" : "NO"),
               category: .general, level: .debug)
        
        return shouldTrigger
    }

    private func startCoordinatorPredictionTimer() {
        // Ensure only one timer
        predictionTimer?.invalidate()
        predictionTimer = Timer.scheduledTimer(withTimeInterval: predictionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let telemetry = self.balloonTelemetry else {
                    appLog("ServiceCoordinator: Timer tick - no telemetry yet", category: .general, level: .debug)
                    return
                }
                appLog("ServiceCoordinator: Timer tick - evaluating prediction trigger", category: .general, level: .debug)
                if self.shouldRequestPrediction(telemetry) {
                    await self.executePrediction(telemetry: telemetry, measuredDescentRate: self.smoothedDescentRate, force: false)
                }
            }
        }
    }
    
    private func executePrediction(telemetry: TelemetryData, measuredDescentRate: Double?, force: Bool) async {
        // Check cache first
        let cacheKey = generateCacheKey(telemetry)
        if let cachedPrediction = await predictionCache.get(key: cacheKey), !force {
            appLog("ServiceCoordinator: Using cached prediction (source=Coordinator) key=\(cacheKey)", category: .general, level: .info)
            updateMapWithPrediction(cachedPrediction)
            return
        } else if !force {
            appLog("ServiceCoordinator: Cache miss (source=Coordinator) key=\(cacheKey)", category: .general, level: .debug)
        }
        
        do {
            let sinceLast = String(format: "%.1f", Date().timeIntervalSince(lastPredictionTime))
            appLog("ServiceCoordinator: executePrediction start (sinceLast=\(sinceLast)s)", category: .general, level: .debug)
            // Mark attempt start and prevent overlap
            lastPredictionAttemptTime = Date()
            isPredictionInFlight = true
            defer { isPredictionInFlight = false }
            // Determine if balloon is descending based on vertical speed
            let balloonDescends = telemetry.verticalSpeed < 0
            if balloonDescends {
                appLog("ServiceCoordinator: Balloon descending (verticalSpeed: \(telemetry.verticalSpeed) m/s)", category: .general, level: .info)
            } else {
                appLog("ServiceCoordinator: Balloon ascending (verticalSpeed: \(telemetry.verticalSpeed) m/s)", category: .general, level: .info)
            }

            // Determine effective descent rate based on altitude
            let effectiveDescentRate: Double
            if telemetry.altitude < 10000, let smoothedRate = measuredDescentRate {
                // Below 10000m: Use automatically calculated smoothed descent rate
                effectiveDescentRate = abs(smoothedRate)
                if balloonDescends {
                    appLog("ServiceCoordinator: Using smoothed descent rate: \(String(format: "%.2f", effectiveDescentRate)) m/s (below 10000m)", category: .general, level: .info)
                }
            } else {
                // Above 10000m: Use user settings default
                effectiveDescentRate = userSettings.descentRate
                if balloonDescends {
                    appLog("ServiceCoordinator: Using settings descent rate: \(String(format: "%.2f", effectiveDescentRate)) m/s (above 10000m or no smoothed rate)", category: .general, level: .info)
                }
            }
            
            // Suppress verbose log for calling prediction service
            // Debug: show cache key components and miss/hit outcome
            appLog("ServiceCoordinator: Triggering prediction (source=Coordinator) key=\(cacheKey)", category: .general, level: .debug)
            let predictionData = try await predictionService.fetchPrediction(
                telemetry: telemetry,
                userSettings: userSettings,
                measuredDescentRate: effectiveDescentRate,
                cacheKey: cacheKey,
                balloonDescends: balloonDescends
            )
            
            // Cache the result
            await predictionCache.set(key: cacheKey, value: predictionData)
            
            // Update last prediction time
            lastPredictionTime = Date()
            
            // Update ServiceCoordinator directly with prediction data
            updateMapWithPrediction(predictionData)
            
            appLog("ServiceCoordinator: Prediction completed successfully", category: .general, level: .info)
            
        } catch {
            appLog("ServiceCoordinator: Prediction failed: \(error.localizedDescription)", category: .general, level: .error)
        }
    }
    
    // UIEvent handling removed - now handled directly by AppServices
    
    // MARK: - Simplified Business Logic
    
    private func updateMapWithBalloonPosition(_ telemetry: TelemetryData) {
        // Use smoothed position for display if available (for landed balloons), otherwise use raw telemetry
        let displayCoordinate = balloonDisplayPosition ?? CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)

        // Update balloon annotation directly
        let balloonAnnotation = MapAnnotationItem(
            coordinate: displayCoordinate,
            title: "Balloon",
            type: .balloon
        )
        
        // Update user annotation if available (when navigation is needed)
        var annotations: [MapAnnotationItem] = [balloonAnnotation]
        if shouldShowNavigation, let userLocation = userLocation {
            let userAnnotation = MapAnnotationItem(
                coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
                title: "You",
            type: .user
            )
            annotations.append(userAnnotation)
        }
        
        // Add landing point if available
        if let landingPoint = getCurrentLandingPoint() {
            let landingAnnotation = MapAnnotationItem(coordinate: landingPoint, title: "Landing",
                type: .landing)
            annotations.append(landingAnnotation)
        }
        
        // Add burst point if available AND balloon is ascending
        if let burstPoint = burstPoint,
           balloonTrackService.balloonPhase == .ascending {
            let burstAnnotation = MapAnnotationItem(coordinate: burstPoint, title: "Burst",
                type: .burst)
            annotations.append(burstAnnotation)
        }
        
        // Update balloon track using the track service
        let trackPoints = balloonTrackService.getAllTrackPoints()
        var balloonTrackPolyline: MKPolyline? = nil
        if !trackPoints.isEmpty {
            let coordinates = trackPoints.map { point in
                CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
            balloonTrackPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            balloonTrackPolyline?.title = "balloonTrack"
        }
        
        // Direct map state update (no versioning complexity)
        self.annotations = annotations
        balloonTrackPath = balloonTrackPolyline
        balloonTelemetry = telemetry
        
        // Updated map annotations (log removed)
    }
    
    // Prediction logic now handled directly in ServiceCoordinator
    
    func updateMapWithPrediction(_ prediction: PredictionData) {
        // Update prediction data
        predictionData = prediction
        
        // Update prediction path (flight mode only)
        if isFlying, let path = prediction.path, !path.isEmpty {
            predictionPath = MKPolyline(coordinates: path, count: path.count)
        } else if isLanded {
            predictionPath = nil
        }
        
        // Check if landing point moved significantly (trigger route update)
        let shouldUpdateRouteFromLandingChange = checkLandingPointMovement(newLandingPoint: prediction.landingPoint)

        // Check if Apple Maps navigation needs updating
        let previousLandingPoint = landingPoint

        // Update landing and burst points
        landingPoint = prediction.landingPoint
        burstPoint = prediction.burstPoint

        // Check for navigation update after setting new landing point
        if let newLandingPoint = prediction.landingPoint {
            checkForNavigationUpdate(previousLandingPoint: previousLandingPoint, newLandingPoint: newLandingPoint)
        }
        
        // Phase 2: Mirror landing point in DomainModel
        // Landing point already updated in ServiceCoordinator state above
        
        // Update map annotations to include landing and burst points
        if let telemetry = bleCommunicationService.latestTelemetry {
            updateMapWithBalloonPosition(telemetry)
        }
        
        // Map annotations updated (no automatic zoom change)
        
        // Trigger route update if landing point moved significantly
        if shouldUpdateRouteFromLandingChange {
            Task {
                await updateRoute()
            }
        }
    }
    
    private func shouldUpdateRoute() -> Bool {
        let timeSinceLastRoute = Date().timeIntervalSince(lastRouteCalculationTime)
        return timeSinceLastRoute > routeUpdateInterval
    }
    
    private func checkLandingPointMovement(newLandingPoint: CLLocationCoordinate2D?) -> Bool {
        defer { lastLandingPoint = newLandingPoint }
        
        guard let newPoint = newLandingPoint else { return false }
        guard let lastPoint = lastLandingPoint else { return true } // First time
        
        let distance = CLLocation(latitude: lastPoint.latitude, longitude: lastPoint.longitude)
            .distance(from: CLLocation(latitude: newPoint.latitude, longitude: newPoint.longitude))
        
        let landingPointMovementThreshold: Double = 100 // meters
        let moved = distance > landingPointMovementThreshold
        
        if moved {
            appLog("ServiceCoordinator: Landing point moved \(Int(distance))m - triggering route update", category: .general, level: .info)
        }
        
        return moved
    }
    
    private func hasUserMovedSignificantly(to newLocation: CLLocationCoordinate2D) -> Bool {
        guard let lastLocation = lastUserLocation else { return true }
        
        let distance = CLLocation(latitude: lastLocation.latitude, longitude: lastLocation.longitude)
            .distance(from: CLLocation(latitude: newLocation.latitude, longitude: newLocation.longitude))
        
        return distance > significantMovementThreshold
    }
    
    private func shouldUpdateRouteForUserMovement() -> Bool {
        let now = Date()
        let timeSinceLastUserUpdate = now.timeIntervalSince(lastUserLocationUpdateTime)
        
        // Check every minute for user movement
        return timeSinceLastUserUpdate > 60.0
    }
    
    func updateRoute() async {
        // When landed, only hide route if user is very close (200m), otherwise continue showing route to landing position
        if isLanded {
            if let userLocation = userLocation,
               let balloonPosition = balloonDisplayPosition ?? (balloonTelemetry != nil ? CLLocationCoordinate2D(latitude: balloonTelemetry!.latitude, longitude: balloonTelemetry!.longitude) : nil) {

                let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
                let distance = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                    .distance(from: CLLocation(latitude: balloonPosition.latitude, longitude: balloonPosition.longitude))

                if distance < 200 {
                    userRoute = nil
                    isRouteVisible = false
                    appLog("ServiceCoordinator: Route hidden - within 200m of landed balloon (\(Int(distance))m)", category: .general, level: .debug)
                    return
                }
                appLog("ServiceCoordinator: Continuing route to landed balloon (\(Int(distance))m away)", category: .general, level: .debug)
            }
        }

        guard let userLocation = userLocation,
              let landingPoint = landingPoint else {
            appLog("ServiceCoordinator: Cannot calculate route - missing user location or landing point", category: .general, level: .debug)
            return
        }
        
        // Distance gating now handled above for landed balloons (200m threshold)
        // For flying balloons, continue showing route regardless of distance
        let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
        
        // Generate cache key including transport mode (keep this valuable optimization)
        let routeKey = generateRouteCacheKey(userCoord, landingPoint, transportMode)
        
        // Check cache first
        if let cachedRoute = await routingCache.get(key: routeKey) {
            // If bike-mode cached route is just a straight segment (fallback), prefer recalculation
            if transportMode == .bike && cachedRoute.coordinates.count <= 2 {
                appLog("ServiceCoordinator: Ignoring cached bike straight-line route; recalculating", category: .general, level: .info)
            } else {
                appLog("ServiceCoordinator: Using cached route", category: .general, level: .debug)
                if !cachedRoute.coordinates.isEmpty {
                    userRoute = MKPolyline(coordinates: cachedRoute.coordinates, count: cachedRoute.coordinates.count)
                    isRouteVisible = true
                    routeData = cachedRoute  // Fix: Set route data for arrival time
                    updateFormattedRouteDistance()
                } else {
                    userRoute = nil
                    isRouteVisible = false
                    routeData = nil
                    updateFormattedRouteDistance()
                }
                return
            }
        }
        
        appLog("ServiceCoordinator: Calculating new route", category: .general, level: .info)
        
        // Calculate route using Apple Maps
        do {
            let routeData = try await routeCalculationService.calculateRoute(
                from: userLocation,
                to: landingPoint,
                transportMode: transportMode
            )
            
            // Update map state with route
            if !routeData.coordinates.isEmpty {
                userRoute = MKPolyline(coordinates: routeData.coordinates, count: routeData.coordinates.count)
                isRouteVisible = true
                self.routeData = routeData
                updateFormattedRouteDistance()
                
                // Cache the route
                await routingCache.set(key: routeKey, value: routeData)
                
                appLog("ServiceCoordinator: Route calculated successfully - \(String(format: "%.1f", routeData.distance/1000))km, \(Int(routeData.expectedTravelTime/60))min", category: .general, level: .info)
            } else {
                userRoute = nil
                isRouteVisible = false
                appLog("ServiceCoordinator: Route calculation returned empty path", category: .general, level: .error)
            }
            
        } catch {
            appLog("ServiceCoordinator: Route calculation failed: \(error)", category: .general, level: .error)
            userRoute = nil
            isRouteVisible = false
        }
        
        lastRouteCalculationTime = Date()
    }
    
    func updateCameraToShowAllAnnotations() {
        if suspendCameraUpdates {
            appLog("ServiceCoordinator: Camera update suspended (settings open)", category: .general, level: .debug)
            return
        }
        // Don't override zoom when in heading mode - let TrackingMapView handle it
        if isHeadingMode {
            appLog("ServiceCoordinator: Skipping camera update - heading mode active", category: .general, level: .debug)
            return
        }
        
        // Camera update to show all annotations and overlay paths with appropriate zoom level
        let allCoordinates = annotations.map { $0.coordinate }
        guard !allCoordinates.isEmpty else { 
            appLog("ServiceCoordinator: No annotations to show on map", category: .general, level: .debug)
            return 
        }
        
        // Include user location in calculations if available
        var coordinates = allCoordinates
        if let userLocation = userLocation {
            coordinates.append(CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude))
        }
        // Include balloon track points
        let trackPoints = balloonTrackService.getAllTrackPoints()
        if !trackPoints.isEmpty {
            coordinates.append(contentsOf: trackPoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
        }
        // Include prediction path points (if available)
        if let path = predictionData?.path, !path.isEmpty {
            coordinates.append(contentsOf: path)
        }
        
        // Calculate bounding region
        let minLat = coordinates.map { $0.latitude }.min()!
        let maxLat = coordinates.map { $0.latitude }.max()!
        let minLon = coordinates.map { $0.longitude }.min()!
        let maxLon = coordinates.map { $0.longitude }.max()!
        
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        
        // Calculate span with padding and minimum zoom constraints
        // Use consistent minimum zoom level with heading mode
        let latSpan = max((maxLat - minLat) * 1.4, 0.1) // Add 40% padding, minimum 0.1 degrees (~10km)
        let lonSpan = max((maxLon - minLon) * 1.4, 0.1) // Add 40% padding, minimum 0.1 degrees (~10km)
        
        let span = MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
        let zoomKm = Int(span.latitudeDelta * 111) // Approximate km conversion
        
        region = MKCoordinateRegion(center: center, span: span)
        
        appLog("🔍 ZOOM: ServiceCoordinator updateCameraToShowAllAnnotations - \(zoomKm)km (\(String(format: "%.3f", span.latitudeDelta))°) for \(coordinates.count) points at [\(String(format: "%.4f", center.latitude)), \(String(format: "%.4f", center.longitude))]", category: .general, level: .info)
    }

    
    // MARK: - Persistence Data Loading (Per FSD)
    
    func loadPersistenceData() {
        appLog("ServiceCoordinator: Loading persistence data per FSD requirements", category: .general, level: .info)
        
        // 1. Prediction parameters - already loaded in UserSettings ✅
        
        // 2. Historic track data - load and add to current track if sonde matches
        // Note: This will be handled by BalloonTrackService when first telemetry arrives
        
        // 3. Landing point (if available) - load for current sonde if available
        if let savedLandingPoint = persistenceService.loadLandingPoint(sondeName: "current") {
            landingPoint = savedLandingPoint
            appLog("ServiceCoordinator: Loaded saved landing point: \(savedLandingPoint)", category: .general, level: .debug)
            
            // Phase 2: Mirror in DomainModel
            // Landing point already set in ServiceCoordinator state above
        }
        
        // 4. Clipboard parsing removed from startup - now handled in determineLandingPoint() per FSD priority
        // Priority 3 (clipboard) only runs if Priority 1 (telemetry) and Priority 2 (prediction) fail
        
        appLog("ServiceCoordinator: Persistence data loading complete", category: .general, level: .info)
        
        // Update annotations with current data (user location + landing point, even without telemetry)
        updateAnnotationsWithoutTelemetry()
    }
    
    // determineLandingPointWithPriorities moved to CoordinatorServices.swift
    
    private func updateAnnotationsWithoutTelemetry() {
        var annotations: [MapAnnotationItem] = []
        
        // Add user annotation if available (when navigation is needed)
        if shouldShowNavigation, let userLocation = userLocation {
            let userAnnotation = MapAnnotationItem(
                coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
                title: "You",
            type: .user
            )
            annotations.append(userAnnotation)
        }
        
        // Add landing point if available
        if let landingPoint = getCurrentLandingPoint() {
            let landingAnnotation = MapAnnotationItem(coordinate: landingPoint, title: "Landing",
                type: .landing)
            annotations.append(landingAnnotation)
        }
        
        self.annotations = annotations
        appLog("ServiceCoordinator: Updated annotations without telemetry - \(annotations.count) annotations", category: .general, level: .info)
    }
    
    // MARK: - Helper Methods
    
    private func generateCacheKey(_ telemetry: TelemetryData) -> String {
        // Unify with PredictionService: use PredictionCache.makeKey with 5-min buckets and 2dp rounding
        return PredictionCache.makeKey(
            balloonID: telemetry.sondeName,
            coordinate: CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude),
            altitude: telemetry.altitude,
            timeBucket: Date()
        )
    }
    
    private func generateRouteCacheKey(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D, _ transportMode: TransportationMode) -> String {
        // Keep the valuable route cache key generation
        let fromLat = round(from.latitude * 100) / 100  // 0.01 degree precision
        let fromLon = round(from.longitude * 100) / 100
        let toLat = round(to.latitude * 100) / 100
        let toLon = round(to.longitude * 100) / 100
        let mode = transportMode == .car ? "car" : "bike"
        
        return "route-\(fromLat)-\(fromLon)-\(toLat)-\(toLon)-\(mode)"
    }
    
    private func getCurrentLandingPoint() -> CLLocationCoordinate2D? {
        return landingPoint
    }
    
    func getAllBalloonTrackPoints() -> [BalloonTrackPoint] {
        // Get from balloon track service
        return balloonTrackService.getAllTrackPoints()
    }
    
    // MARK: - Automatic Descent Rate Calculation moved to BalloonTrackService

    // MARK: - AFC Frequency Tracking (moved from SettingsView for proper separation of concerns)
    
    private func updateAFCTracking(_ telemetry: TelemetryData) {
        let afc = telemetry.afcFrequency
        afcFrequencies.append(afc)

        // Keep only the last 20 values for moving average
        if afcFrequencies.count > 20 {
            afcFrequencies.removeFirst()
        }

        // Update moving average
        afcMovingAverage = afcFrequencies.isEmpty ? 0 : afcFrequencies.reduce(0, +) / afcFrequencies.count
        
        // AFC tracking updated (log removed)
    }
    
    // MARK: - Landing Point Management (moved from LandingPointService)
    
    @discardableResult
    func setLandingPointFromClipboard() -> Bool {
        appLog("ServiceCoordinator: Attempting to set landing point from clipboard", category: .service, level: .info)
        if let clipboardLanding = parseClipboardForLandingPoint() {
            landingPoint = clipboardLanding
            
            // Persist the landing point
            if let sondeName = balloonTrackService.currentBalloonName {
                persistenceService.saveLandingPoint(sondeName: sondeName, coordinate: clipboardLanding)
                appLog("ServiceCoordinator: Successfully set and persisted landing point from clipboard", category: .service, level: .info)
            }

            // Set balloon as landed since we have a manual landing point from clipboard
            balloonTrackService.setBalloonAsLanded(at: clipboardLanding)
            appLog("ServiceCoordinator: Balloon set as landed due to clipboard landing point", category: .service, level: .info)

            // Update DomainModel
            // Landing point already set in ServiceCoordinator state above
            
            return true
        }
        return false
    }
    
    private func parseClipboardForLandingPoint() -> CLLocationCoordinate2D? {
        let clipboardString = UIPasteboard.general.string ?? ""
        
        appLog("ServiceCoordinator: Clipboard content: '\(clipboardString)' (\(clipboardString.count) chars)", category: .service, level: .info)
        
        guard !clipboardString.isEmpty else {
            return nil
        }
        
        // First validate that clipboard content looks like a URL
        let trimmedString = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedString.hasPrefix("http://") || trimmedString.hasPrefix("https://") else {
            appLog("ServiceCoordinator: Clipboard content is not a URL (no http/https prefix)", category: .service, level: .debug)
            return nil
        }
        
        // Check if it's an OpenStreetMap URL (expected format per FSD)
        guard trimmedString.contains("openstreetmap.org") else {
            appLog("ServiceCoordinator: URL is not an OpenStreetMap URL as expected per FSD", category: .service, level: .debug)
            return nil
        }
        
        appLog("ServiceCoordinator: Attempting to parse clipboard URL: '\(trimmedString)'", category: .service, level: .debug)
        
        // Try to parse as URL with coordinates
        if let url = URL(string: trimmedString),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            
            var lat: Double? = nil
            var lon: Double? = nil
            
            for item in queryItems {
                switch item.name {
                case "lat", "latitude":
                    lat = Double(item.value ?? "")
                case "lon", "lng", "longitude":
                    lon = Double(item.value ?? "")
                case "route":
                    // Parse OpenStreetMap route format: "47.4738%2C7.75929%3B47.4987%2C7.667"
                    // Second coordinate (after %3B which is ";") is the landing point
                    if let routeValue = item.value {
                        let decodedRoute = routeValue.removingPercentEncoding ?? routeValue
                        let coordinates = decodedRoute.components(separatedBy: ";")
                        if coordinates.count >= 2 {
                            let landingCoordParts = coordinates[1].components(separatedBy: ",")
                            if landingCoordParts.count == 2 {
                                lat = Double(landingCoordParts[0])
                                lon = Double(landingCoordParts[1])
                                appLog("ServiceCoordinator: Parsed OpenStreetMap route format: \(landingCoordParts[0]), \(landingCoordParts[1])", category: .service, level: .debug)
                            }
                        }
                    }
                default:
                    break
                }
            }
            
            if let latitude = lat, let longitude = lon {
                appLog("ServiceCoordinator: ✅ Parsed coordinates from clipboard URL", category: .service, level: .info)
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
        }
        
        appLog("ServiceCoordinator: Invalid URL format", category: .service, level: .debug)
        appLog("ServiceCoordinator: ❌ Clipboard content could not be parsed as coordinates", category: .service, level: .debug)
        return nil
    }

    // MARK: - UI Support Methods

    func openInAppleMaps() {
        guard let landingPoint = landingPoint else {
            appLog("ServiceCoordinator: Cannot open Apple Maps - no landing point available", category: .general, level: .error)
            return
        }

        let placemark = MKPlacemark(coordinate: landingPoint)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = "Balloon Landing Site"

        let directionsMode: String
        switch transportMode {
        case .car:
            directionsMode = MKLaunchOptionsDirectionsModeDriving
        case .bike:
            if #available(iOS 14.0, *) {
                directionsMode = MKLaunchOptionsDirectionsModeCycling
            } else {
                directionsMode = MKLaunchOptionsDirectionsModeWalking // Fallback for older iOS
            }
        }

        let launchOptions = [
            MKLaunchOptionsDirectionsModeKey: directionsMode
        ]

        mapItem.openInMaps(launchOptions: launchOptions)
        appLog("ServiceCoordinator: Opened Apple Maps navigation to landing point", category: .general, level: .info)

        // Track that navigation was started for update notifications
        hasStartedAppleMapsNavigation = true
        lastAppleMapsDestination = landingPoint
    }

    private func checkForNavigationUpdate(previousLandingPoint: CLLocationCoordinate2D?, newLandingPoint: CLLocationCoordinate2D) {
        // Check if we have a previous landing point to compare against
        guard let previousPoint = previousLandingPoint else {
            // First landing point - no notification needed
            return
        }

        // Calculate distance between old and new landing points
        let oldLocation = CLLocation(latitude: previousPoint.latitude, longitude: previousPoint.longitude)
        let newLocation = CLLocation(latitude: newLandingPoint.latitude, longitude: newLandingPoint.longitude)
        let distanceChange = oldLocation.distance(from: newLocation)

        // Trigger update notification if change is significant (>100m)
        if distanceChange > 100 {
            appLog("ServiceCoordinator: Landing point changed by \(Int(distanceChange))m - sending navigation update notification", category: .general, level: .info)
            sendNavigationUpdateNotification(newDestination: newLandingPoint, distanceChange: distanceChange)
        }
    }

    private func sendNavigationUpdateNotification(newDestination: CLLocationCoordinate2D, distanceChange: Double) {
        // Simple notification for navigation update
        let content = UNMutableNotificationContent()
        content.title = "Landing Prediction Updated"
        content.body = "Balloon moved \(Int(distanceChange))m. Tap to open Apple Maps with new location."
        content.sound = .default

        // Store destination for when user taps notification
        content.userInfo = [
            "latitude": newDestination.latitude,
            "longitude": newDestination.longitude
        ]

        let request = UNNotificationRequest(
            identifier: "navigation_update_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                appLog("ServiceCoordinator: Failed to send navigation notification: \(error)", category: .general, level: .error)
            } else {
                appLog("ServiceCoordinator: Sent navigation update notification", category: .general, level: .info)
            }
        }
    }

    func updateLastAppleMapsDestination(_ destination: CLLocationCoordinate2D) {
        lastAppleMapsDestination = destination
        appLog("ServiceCoordinator: Updated last Apple Maps destination", category: .general, level: .debug)
    }

    func logZoomChange(_ description: String, span: MKCoordinateSpan, center: CLLocationCoordinate2D? = nil) {
        let zoomKm = Int(span.latitudeDelta * 111) // Approximate km conversion
        if let center = center {
            appLog("🔍 ZOOM: \(description) - \(zoomKm)km (\(String(format: "%.3f", span.latitudeDelta))°) at [\(String(format: "%.4f", center.latitude)), \(String(format: "%.4f", center.longitude))]", category: .general, level: .info)
        } else {
            appLog("🔍 ZOOM: \(description) - \(zoomKm)km (\(String(format: "%.3f", span.latitudeDelta))°)", category: .general, level: .info)
        }
    }

    private func updateFormattedRouteDistance() {
        if let distanceMeters = routeData?.distance {
            let distanceKm = distanceMeters / 1000.0
            formattedRouteDistance = String(format: "%.1f", distanceKm)
        } else {
            formattedRouteDistance = "--"
        }
    }

    // MARK: - Prediction Logic Now Handled by Independent BalloonTrackPredictionService
    // All prediction functionality moved to BalloonTrackPredictionService for better separation of concerns
}
