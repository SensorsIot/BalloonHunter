import Foundation
import Combine
import SwiftUI
import CoreLocation
import CoreBluetooth
import MapKit
import OSLog
import UIKit

// MARK: - Service Coordinator
// Transitional class for service coordination and dependency injection
// EventBus architecture has been fully removed

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
    @Published var burstPoint: CLLocationCoordinate2D? = nil
    
    // Additional data for DataPanelView
    @Published var predictionData: PredictionData? = nil
    @Published var routeData: RouteData? = nil
    @Published var balloonTrackHistory: [TelemetryData] = []
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var smoothedDescentRate: Double? = nil
    @Published var smoothedVerticalSpeed: Double = 0.0
    @Published var smoothedHorizontalSpeed: Double = 0.0
    @Published var isTelemetryStale: Bool = false
    @Published var remainingFlightTimeString: String = "--:--"
    @Published var predictedLandingTimeString: String = "--:--"
    
    // AFC tracking (moved from SettingsView for proper separation of concerns)
    @Published var afcFrequencies: [Int] = []
    
    // Startup sequence state
    @Published var startupProgress: String = "Initializing services..."
    @Published var currentStartupStep: Int = 0
    @Published var isStartupComplete: Bool = false
    @Published var showLogo: Bool = true
    @Published var showTrackingMap: Bool = false
    
    // UI state
    @Published var transportMode: TransportationMode = .car
    @Published var isHeadingMode: Bool = false
    @Published var isPredictionPathVisible: Bool = true
    @Published var isRouteVisible: Bool = true
    @Published var isBuzzerMuted: Bool = false
    @Published var showAllAnnotations: Bool = false
    
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
    
    // REMOVE: Policy architecture, ModeStateMachine, PolicyScheduler
    // REPLACE: With direct service communication
    
    private var cancellables = Set<AnyCancellable>()
    private var lastRouteCalculationTime = Date.distantPast
    private var lastPredictionTime = Date.distantPast
    private var lastUserLocation: CLLocationCoordinate2D?
    private var lastLandingPoint: CLLocationCoordinate2D?
    private var lastUserLocationUpdateTime = Date.distantPast
    
    // Simple timing constants (replace complex mode machine)
    private let routeUpdateInterval: TimeInterval = 60  // Always 60 seconds
    private let predictionInterval: TimeInterval = 60  // Every 60 seconds per requirements
    private let significantMovementThreshold: Double = 100  // meters
    
    // User settings reference (for external access)
    var userSettings = UserSettings()
    
    // Automatic descent rate calculation
    private var descentRateHistory: [Double] = [] // Store up to 20 values for smoothing
    
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
        // NOTE: predictionService is lazy-initialized only when first telemetry is received
        
        // Initialize the services that create events and manage data
        _ = balloonPositionService
        _ = balloonTrackService  
        _ = routeCalculationService
        
        // Phase 3: Start independent prediction service
        appLog("STARTUP: Starting automatic prediction service with 60-second intervals", category: .general, level: .info)
        predictionService.startAutomaticPredictions()
        
        // Setup manual prediction listener
        setupManualPredictionListener()
        
        // Services initialized - startup sequence will be triggered by BalloonHunterApp
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
    
    private func waitForSettingsResponse() async {
        appLog("ServiceCoordinator: Waiting for settings response from MySondyGo", category: .general, level: .info)
        
        let initialDeviceSettings = bleCommunicationService.deviceSettings
        let timeout = Date().addingTimeInterval(3) // 3 seconds for settings response
        
        while Date() < timeout {
            // Check if device settings have been updated (different from initial)
            if bleCommunicationService.deviceSettings.frequency != initialDeviceSettings.frequency ||
               !bleCommunicationService.deviceSettings.probeType.isEmpty {
                appLog("ServiceCoordinator: Settings response received and stored locally", category: .general, level: .info)
                return
            }
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second checks
        }
        
        appLog("ServiceCoordinator: Settings response timeout - proceeding with defaults", category: .general, level: .info)
    }
    
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
        if let telemetry = balloonTelemetry, telemetry.verticalSpeed >= -0.5 && telemetry.altitude < 500 {
            let currentPosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
            landingPoint = currentPosition
            appLog("ServiceCoordinator: Landing point set from current balloon position (landed)", category: .general, level: .info)
            return
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
        triggerShowAllAnnotations()
        
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds for map to update
        appLog("ServiceCoordinator: Initial map display complete with all annotations", category: .general, level: .info)
    }
    
    // MARK: - Direct Event Handling (No Policy Layers)
    
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
            
        // Subscribe to prediction service for time strings
        predictionService.$remainingFlightTimeString
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.remainingFlightTimeString = time
            }
            .store(in: &cancellables)
            
        predictionService.$predictedLandingTimeString
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.predictedLandingTimeString = time
            }
            .store(in: &cancellables)
        
        appLog("ServiceCoordinator: Setup direct telemetry, location, and BLE connection subscriptions", category: .general, level: .debug)
    }
        
    // MARK: - High-Level UI Methods for View Actions
    
    func triggerShowAllAnnotations() {
        showAllAnnotations = true
        appLog("ServiceCoordinator: Triggered show all annotations", category: .general, level: .debug)
    }
    
    func triggerPrediction() {
        appLog("ServiceCoordinator: Manual prediction triggered from UI", category: .general, level: .info)
        
        guard let telemetry = balloonTelemetry else {
            appLog("ServiceCoordinator: No telemetry available for prediction", category: .general, level: .error)
            return
        }
        
        Task {
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
    
    func saveDataOnAppClose() {
        appLog("ServiceCoordinator: Saving data on app close", category: .general, level: .info)
        persistenceService.saveOnAppClose(balloonTrackService: balloonTrackService)
    }
    
    private func setupManualPredictionListener() {
        NotificationCenter.default.addObserver(
            forName: .manualPredictionRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleManualPredictionRequest()
            }
        }
    }
    
    // MARK: - Simplified Event Handlers
    
    // REMOVED: handleBalloonPosition method - EventBus eliminated
    
    
    // Direct telemetry handling with prediction timing (replaces PredictionPolicy)
    private func handleBalloonTelemetry(_ telemetry: TelemetryData) {
        // Processing telemetry (log removed for reduction)
        
        // Update ServiceCoordinator with telemetry data (direct subscription)
        balloonTelemetry = telemetry
        
        // Update AFC frequency tracking (moved from SettingsView for proper separation of concerns)
        updateAFCTracking(telemetry)
        
        // Calculate smoothed descent rate for data panel
        calculateAutomaticDescentRate(telemetry)
        
        // Update map with balloon position and annotations
        updateMapWithBalloonPosition(telemetry)
        
        // Check if we should request a prediction based on timing
        if shouldRequestPrediction(telemetry) {
            appLog("ServiceCoordinator: Prediction needed - executing directly", category: .general, level: .info)
            
            Task {
                await executePrediction(
                    telemetry: telemetry,
                    measuredDescentRate: smoothedDescentRate,
                    force: false
                )
            }
        } else {
            appLog("ServiceCoordinator: Prediction not needed yet", category: .general, level: .debug)
        }
    }
    
    // Direct location handling (replaces MapState subscription)
    private func handleUserLocation(_ locationData: LocationData?) {
        // Update ServiceCoordinator with location data (direct subscription)
        userLocation = locationData
        
        guard let locationData = locationData else { return }
        
        // Processing user location update
        
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
    
    // Manual prediction request handler
    func handleManualPredictionRequest() {
        appLog("ServiceCoordinator: Manual prediction requested", category: .general, level: .info)
        
        guard let telemetry = balloonTelemetry else {
            appLog("ServiceCoordinator: No telemetry available for manual prediction", category: .general, level: .error)
            return
        }
        
        Task {
            await executePrediction(
                telemetry: telemetry,
                measuredDescentRate: smoothedDescentRate,
                force: true
            )
        }
    }
    
    // MARK: - Prediction Logic (moved from PredictionPolicy)
    
    private func shouldRequestPrediction(_ telemetry: TelemetryData, force: Bool = false) -> Bool {
        if force {
            appLog("ServiceCoordinator: Prediction forced", category: .general, level: .debug)
            return true
        }
        
        // Simple time-based trigger
        let timeSinceLastPrediction = Date().timeIntervalSince(lastPredictionTime)
        let shouldTrigger = timeSinceLastPrediction > predictionInterval
        
        // shouldRequestPrediction evaluation (log removed)
        
        return shouldTrigger
    }
    
    private func executePrediction(telemetry: TelemetryData, measuredDescentRate: Double?, force: Bool) async {
        // Check cache first
        let cacheKey = generateCacheKey(telemetry)
        if let cachedPrediction = await predictionCache.get(key: cacheKey), !force {
            appLog("ServiceCoordinator: Using cached prediction for \(telemetry.sondeName)", category: .general, level: .info)
            updateMapWithPrediction(cachedPrediction)
            return
        }
        
        do {
            // Determine if balloon is descending based on vertical speed
            let balloonDescends = telemetry.verticalSpeed < 0
            appLog("ServiceCoordinator: Balloon descending: \(balloonDescends) (verticalSpeed: \(telemetry.verticalSpeed) m/s)", category: .general, level: .info)
            
            // Determine effective descent rate based on altitude
            let effectiveDescentRate: Double
            if telemetry.altitude < 10000, let smoothedRate = measuredDescentRate {
                // Below 10000m: Use automatically calculated smoothed descent rate
                effectiveDescentRate = abs(smoothedRate)
                appLog("ServiceCoordinator: Using smoothed descent rate: \(String(format: "%.2f", effectiveDescentRate)) m/s (below 10000m)", category: .general, level: .info)
            } else {
                // Above 10000m: Use user settings default
                effectiveDescentRate = userSettings.descentRate
                appLog("ServiceCoordinator: Using settings descent rate: \(String(format: "%.2f", effectiveDescentRate)) m/s (above 10000m or no smoothed rate)", category: .general, level: .info)
            }
            
            appLog("ServiceCoordinator: Calling prediction service for \(telemetry.sondeName)", category: .general, level: .info)
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
        // Update balloon annotation directly
        let balloonAnnotation = MapAnnotationItem(
            coordinate: CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude),
            title: "Balloon",
            type: .balloon
        )
        
        // Update user annotation if available
        var annotations: [MapAnnotationItem] = [balloonAnnotation]
        if let userLocation = userLocation {
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
           let telemetryData = balloonTelemetry,
           telemetryData.verticalSpeed >= 0 { // Only show when ascending
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
    
    // Prediction logic now handled directly in ServiceCoordinator (PredictionPolicy removed)
    
    func updateMapWithPrediction(_ prediction: PredictionData) {
        // Update prediction data for DataPanelView (flight time, landing time)
        predictionData = prediction
        appLog("ServiceCoordinator: Set predictionData - landingTime: \(prediction.landingTime?.description ?? "N/A")", category: .general, level: .debug)
        
        // Update prediction path
        if let path = prediction.path, !path.isEmpty {
            predictionPath = MKPolyline(coordinates: path, count: path.count)
            isPredictionPathVisible = true
        }
        
        // Check if landing point moved significantly (trigger route update)
        let shouldUpdateRouteFromLandingChange = checkLandingPointMovement(newLandingPoint: prediction.landingPoint)
        
        // Update landing and burst points
        landingPoint = prediction.landingPoint
        burstPoint = prediction.burstPoint
        
        // Phase 2: Mirror landing point in DomainModel
        // Landing point already updated in ServiceCoordinator state above
        
        // Update map annotations to include landing and burst points
        if let telemetry = bleCommunicationService.latestTelemetry {
            updateMapWithBalloonPosition(telemetry)
        }
        
        // Per FSD: Use maximum zoom level to show all annotations after data loading
        updateCameraToShowAllAnnotations()
        
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
        guard let userLocation = userLocation,
              let landingPoint = landingPoint else {
            appLog("ServiceCoordinator: Cannot calculate route - missing user location or landing point", category: .general, level: .debug)
            return
        }
        
        // Check distance gating (don't show route if balloon is too close to iPhone)
        let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
        
        // Use balloon position if available, otherwise fall back to landing point
        let referencePoint: CLLocationCoordinate2D
        if let balloonTelemetry = balloonTelemetry {
            referencePoint = CLLocationCoordinate2D(latitude: balloonTelemetry.latitude, longitude: balloonTelemetry.longitude)
        } else {
            referencePoint = landingPoint
        }
        
        let distance = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            .distance(from: CLLocation(latitude: referencePoint.latitude, longitude: referencePoint.longitude))
        
        if distance < 100 { // 100m rule - too close to balloon/landing point
            userRoute = nil
            isRouteVisible = false
            let referenceType = balloonTelemetry != nil ? "balloon" : "landing point"
            appLog("ServiceCoordinator: Route hidden - too close to \(referenceType) (\(Int(distance))m < 100m)", category: .general, level: .debug)
            return
        }
        
        // Generate cache key including transport mode (keep this valuable optimization)
        let routeKey = generateRouteCacheKey(userCoord, landingPoint, transportMode)
        
        // Check cache first
        if let cachedRoute = await routingCache.get(key: routeKey) {
            appLog("ServiceCoordinator: Using cached route", category: .general, level: .debug)
            if !cachedRoute.coordinates.isEmpty {
                userRoute = MKPolyline(coordinates: cachedRoute.coordinates, count: cachedRoute.coordinates.count)
                isRouteVisible = true
                routeData = cachedRoute  // Fix: Set route data for arrival time
            } else {
                userRoute = nil
                isRouteVisible = false
                routeData = nil
            }
            return
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
    
    private func updateCameraToShowAllAnnotations() {
        // Camera update to show all annotations with appropriate zoom level
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
        let latSpan = max((maxLat - minLat) * 1.4, 0.01) // Add 40% padding, minimum 0.01 degrees
        let lonSpan = max((maxLon - minLon) * 1.4, 0.01) // Add 40% padding, minimum 0.01 degrees
        
        let span = MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
        
        region = MKCoordinateRegion(center: center, span: span)
        
        appLog("ServiceCoordinator: Updated camera to show \(coordinates.count) points - center: \(center), span: \(span)", category: .general, level: .info)
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
        
        // Add user annotation if available
        if let userLocation = userLocation {
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
        // Keep the valuable cache key generation logic
        let lat = round(telemetry.latitude * 10) / 10  // 0.1 degree precision
        let lon = round(telemetry.longitude * 10) / 10
        let alt = round(telemetry.altitude / 500) * 500  // 500m altitude buckets
        let timeSlot = Int(Date().timeIntervalSince1970 / 600) * 600  // 10-minute slots
        
        return "\(telemetry.sondeName)-\(lat)-\(lon)-\(Int(alt))-\(timeSlot)"
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
    
    // MARK: - Automatic Descent Rate Calculation
    
    private func calculateAutomaticDescentRate(_ telemetry: TelemetryData) {
        // Only calculate if below 10000m altitude
        guard telemetry.altitude < 10000 else {
            return
        }
        
        // Get current balloon track from the track service
        let trackPoints = balloonTrackService.getAllTrackPoints()
        
        // Find historical reference point (60 seconds ago)
        let currentTime = Date() // Use current time since telemetry doesn't have timestamp
        let targetHistoricalTime = currentTime.addingTimeInterval(-60.0) // 60 seconds ago
        
        // Find the first point that is older than 60 seconds
        var historicalPoint: BalloonTrackPoint? = nil
        for point in trackPoints.reversed() { // Start from most recent
            if point.timestamp < targetHistoricalTime {
                historicalPoint = point
                break
            }
        }
        
        guard let historical = historicalPoint else {
            appLog("ServiceCoordinator: No historical point found from 60 seconds ago - need more track history", category: .general, level: .debug)
            return
        }
        
        // Calculate descent rate: (current_altitude - historical_altitude) / time_difference
        let altitudeDiff = telemetry.altitude - historical.altitude
        let timeDiff = currentTime.timeIntervalSince(historical.timestamp)
        
        guard timeDiff > 0 else {
            appLog("ServiceCoordinator: Invalid time difference for descent rate calculation", category: .general, level: .error)
            return
        }
        
        let instantDescentRate = altitudeDiff / timeDiff // m/s (negative when descending)
        
        appLog("ServiceCoordinator: Calculated instant descent rate: \(String(format: "%.2f", instantDescentRate)) m/s (alt: \(Int(telemetry.altitude))m -> \(Int(historical.altitude))m over \(String(format: "%.1f", timeDiff))s)", category: .general, level: .debug)
        
        // Add to history for smoothing (keep up to 20 values)
        descentRateHistory.append(instantDescentRate)
        if descentRateHistory.count > 20 {
            descentRateHistory.removeFirst()
        }
        
        // Calculate smoothed descent rate (average of up to 20 values)
        let smoothedRate = descentRateHistory.reduce(0.0, +) / Double(descentRateHistory.count)
        
        appLog("ServiceCoordinator: Smoothed descent rate: \(String(format: "%.2f", smoothedRate)) m/s (based on \(descentRateHistory.count) values)", category: .general, level: .info)
        
        // Update map state with smoothed descent rate
        smoothedDescentRate = smoothedRate
        
        // Sync smoothed descent rate to DomainModel for better ascent/descent detection
        // Smoothed rate already stored in ServiceCoordinator property above
    }
    
    // MARK: - AFC Frequency Tracking (moved from SettingsView for proper separation of concerns)
    
    private func updateAFCTracking(_ telemetry: TelemetryData) {
        let afc = telemetry.afcFrequency
        afcFrequencies.append(afc)
        
        // Keep only the last 20 values for moving average
        if afcFrequencies.count > 20 {
            afcFrequencies.removeFirst()
        }
        
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

    // MARK: - Prediction Logic Now Handled by Independent BalloonTrackPredictionService
    // All prediction functionality moved to BalloonTrackPredictionService for better separation of concerns
}
