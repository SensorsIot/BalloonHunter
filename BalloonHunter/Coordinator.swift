import Foundation
import Combine
import SwiftUI
import CoreLocation
import CoreBluetooth
import MapKit
import OSLog
import UIKit

// MARK: - Coordinator
// Central coordinator that wires services together and exposes app-facing intents

@MainActor
final class ServiceCoordinator: ObservableObject {
    // KEEP: Core services that provide real value
    let persistenceService: PersistenceService
    let predictionCache: PredictionCache  // Keep: has real performance value
    let routingCache: RoutingCache       // Keep: has real performance value
    
    // MARK: - Published Properties (moved from MapState)
    
    // Map visual elements
    @Published var predictionPath: MKPolyline? = nil
    @Published var userRoute: MKPolyline? = nil
    
    // Data state
    @Published var balloonTelemetry: TelemetryData? = nil
    @Published var userLocation: LocationData? = nil
    @Published var landingPoint: CLLocationCoordinate2D? = nil
    @Published var burstPoint: CLLocationCoordinate2D? = nil
    @Published var balloonDisplayPosition: CLLocationCoordinate2D? = nil
    
    // Additional data for DataPanelView
    @Published var predictionData: PredictionData? = nil
    @Published var routeData: RouteData? = nil
    @Published var balloonTrackHistory: [TelemetryData] = []
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var smoothedDescentRate: Double? = nil
    @Published var predictionUsesSmoothedDescent: Bool = false
    @Published var smoothedVerticalSpeed: Double = 0.0
    @Published var smoothedHorizontalSpeed: Double = 0.0
    @Published var isTelemetryStale: Bool = false
    // Flight/landing time strings provided directly by PredictionService; UI binds there
    @Published var deviceSettings: DeviceSettings?
    
    // AFC tracking (moved from SettingsView for proper separation of concerns)
    @Published var afcFrequencies: [Int] = []
    @Published var afcMovingAverage: Int = 0
    @Published var aprsTelemetryIsAvailable: Bool = false

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
    
    // Phase 3: Prediction Service (injected from AppServices)
    let predictionService: PredictionService
    
    // REQUIRED: Services that generate the events and manage data (injected from AppServices)
    let balloonPositionService: BalloonPositionService
    let balloonTrackService: BalloonTrackService
    let landingPointTrackingService: LandingPointTrackingService
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
    private var lastAprsSyncCommandTime: Date?
    private var lastAprsSyncPromptTime: Date?
    private var userLocationLogCount: Int = 0

    // Simple timing constants (replace complex mode machine)
    private let routeUpdateInterval: TimeInterval = 60  // Always 60 seconds
    private let predictionInterval: TimeInterval = 60  // Every 60 seconds per requirements
    private let significantMovementThreshold: Double = 100  // meters
    
    // User settings reference (for external access)
    var userSettings = UserSettings()

    // App settings reference (for transport mode and other app-level settings)
    var appSettings: AppSettings?

    // Frequency sync proposal from APRS fallback
    @Published var frequencySyncProposal: FrequencySyncProposal? = nil

    // Transport mode kept in sync with AppSettings persistence
    @Published var transportMode: TransportationMode = .car {
        didSet {
            if appSettings?.transportMode != transportMode {
                appSettings?.transportMode = transportMode
            }
        }
    }

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
        return balloonPositionService.balloonPhase != .landed &&
               balloonPositionService.balloonPhase != .unknown
    }

    private var isLanded: Bool {
        return balloonPositionService.balloonPhase == .landed
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
        predictionService: PredictionService,
        balloonPositionService: BalloonPositionService,
        balloonTrackService: BalloonTrackService,
        landingPointTrackingService: LandingPointTrackingService
    ) {
        // ServiceCoordinator initialized (logged at AppServices level)
        
        // Use injected services instead of creating new ones
        self.bleCommunicationService = bleCommunicationService
        self.currentLocationService = currentLocationService
        self.persistenceService = persistenceService
        self.predictionCache = predictionCache
        self.routingCache = routingCache
        self.predictionService = predictionService
        self.balloonPositionService = balloonPositionService
        self.balloonTrackService = balloonTrackService
        self.landingPointTrackingService = landingPointTrackingService

        // Set up circular reference for PredictionService
        configurePredictionService()

        setupDirectSubscriptions()

        // Architecture setup complete
    }

    private func configurePredictionService() {
        predictionService.setServiceCoordinator(self)
        predictionService.configureSharedDependencies(predictionCache: predictionCache, userSettings: userSettings)
    }

    func initialize() {
        appLog("========================================", category: .general, level: .info)
        // Start core services
        _ = currentLocationService
        _ = bleCommunicationService

        // Initialize the services that create events and manage data
        _ = balloonPositionService
        _ = balloonTrackService
        _ = landingPointTrackingService
        _ = routeCalculationService

        // Phase 3: Prediction timer will be controlled by state machine
        appLog("STARTUP: Prediction timer will be controlled by state machine", category: .general, level: .info)


        // Services initialized - startup sequence will be triggered by BalloonHunterApp
    }

    func setAppSettings(_ settings: AppSettings) {
        appSettings = settings
        transportMode = settings.transportMode
        settings.$transportMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard let self = self, self.transportMode != mode else { return }
                self.transportMode = mode
            }
            .store(in: &cancellables)
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
        while !bleCommunicationService.telemetryState.canReceiveCommands && Date() < connectionTimeout {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second checks
        }
        
        if bleCommunicationService.telemetryState.canReceiveCommands {
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
        
                // Subscribe to balloon track service for motion metrics
        balloonTrackService.$motionMetrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                guard let self = self else { return }
                self.smoothedVerticalSpeed = metrics.smoothedVerticalSpeedMS
                self.smoothedHorizontalSpeed = metrics.smoothedHorizontalSpeedMS
                self.smoothedDescentRate = metrics.adjustedDescentRateMS
                // predictionUsesSmoothedDescent is controlled by PredictionService logic only
            }
            .store(in: &cancellables)

        // Automatic frequency sync now handled during startup - no user prompts needed

        balloonPositionService.$isTelemetryStale
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stale in
                self?.isTelemetryStale = stale
            }
            .store(in: &cancellables)

        balloonPositionService.$aprsTelemetryIsAvailable
            .receive(on: DispatchQueue.main)
            .assign(to: &self.$aprsTelemetryIsAvailable)

        // Subscribe to balloon phase updates for landing handling
        balloonPositionService.$balloonPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (phase: BalloonPhase) in
                guard let self = self else { return }
                if phase == .landed, let position = self.balloonTrackService.landingPosition {
                    // Advanced landing detection triggered - update landing point
                    self.landingPoint = position
                    self.balloonDisplayPosition = position
                    self.currentLocationService.updateBalloonDisplayPosition(position)
                    appLog("ServiceCoordinator: Advanced landing detection - landing point set to [\(String(format: "%.4f", position.latitude)), \(String(format: "%.4f", position.longitude))]", category: .general, level: .info)

                    // Trigger route calculation now that landing point is available
                    Task {
                        await self.updateRoute()
                    }
                } else if let telemetry = self.balloonTelemetry {
                    let livePosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
                    self.balloonDisplayPosition = livePosition
                    self.currentLocationService.updateBalloonDisplayPosition(livePosition)
                }
            }
            .store(in: &cancellables)

        // UI binds directly to PredictionService for time strings
            
        // Subscribe to device settings changes
        bleCommunicationService.$deviceSettings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                self?.deviceSettings = settings
            }
            .store(in: &cancellables)


        // Subscribe to APRS sonde names for display

        // Frequency sync scenarios per FSD requirements
        // Scenario 2: RadioSondyGo connects when APRS data already available - sync immediately
        bleCommunicationService.$telemetryState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bleTelemetryState in
                if bleTelemetryState.canReceiveCommands {
                    self?.handleBLEConnectionWithAPRSSync()
                }
            }
            .store(in: &cancellables)

        // APRS frequency sync now handled by state machine transitions

        // Subscribe to state machine prediction control
        balloonPositionService.$shouldEnablePredictions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldEnable in
                self?.updatePredictionTimer(enabled: shouldEnable)
            }
            .store(in: &cancellables)

        // Subscribe to frequency sync proposals
        balloonPositionService.$frequencySyncProposal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proposal in
                self?.frequencySyncProposal = proposal
            }
            .store(in: &cancellables)

        // Direct subscriptions setup complete
    }

    // MARK: - Frequency Sync Handlers

    private func handleBLEConnectionWithAPRSSync() {
        // Scenario 2: RadioSondyGo connects when APRS data already available
        guard aprsTelemetryIsAvailable,
              let telemetry = balloonPositionService.currentTelemetry,
              telemetry.telemetrySource == .aprs else {
            appLog("ServiceCoordinator: RadioSondyGo connected but no APRS telemetry for frequency sync", category: .general, level: .debug)
            return
        }

        // Check if frequency sync is needed
        let aprsFreq = telemetry.frequency
        let bleFreq = bleCommunicationService.deviceSettings.frequency
        let freqMismatch = abs(aprsFreq - bleFreq) > 0.01 // 0.01 MHz tolerance

        guard freqMismatch, aprsFreq > 0 else {
            appLog("ServiceCoordinator: RadioSondyGo connected - frequencies already match", category: .general, level: .info)
            return
        }

        // Delegate to state machine for frequency sync decisions
        appLog("ServiceCoordinator: RadioSondyGo connected with APRS data - requesting state machine to evaluate frequency sync", category: .general, level: .info)
        balloonPositionService.evaluateFrequencySyncFromAPRS()
    }

    // APRS frequency sync logic moved to BalloonPositionService state machine

    /// Accept the APRS frequency sync proposal
    func acceptFrequencySyncProposal() {
        balloonPositionService.acceptFrequencySyncProposal()
    }

    /// Reject the APRS frequency sync proposal
    func rejectFrequencySyncProposal() {
        balloonPositionService.rejectFrequencySyncProposal()
    }

    // MARK: - High-Level UI Methods for View Actions
    
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
    
    // MARK: - Simplified Event Handlers
    
    // Direct telemetry handling with prediction timing
    private func handleBalloonTelemetry(_ telemetry: TelemetryData) {
        // Suppress verbose per-packet telemetry summary in debug logs

        // Update ServiceCoordinator with telemetry data (direct subscription)
        balloonTelemetry = telemetry
        // Keep frequency visible without waiting for device settings
        if telemetry.frequency > 0 {
        }

        // Update AFC frequency tracking (moved from SettingsView for proper separation of concerns)
        updateAFCTracking(telemetry)

        // Update display position: use landing point when landed, otherwise live telemetry
        if isLanded, let landingPosition = balloonTrackService.landingPosition {
            balloonDisplayPosition = landingPosition
            currentLocationService.updateBalloonDisplayPosition(landingPosition)
        } else {
            let livePosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
            balloonDisplayPosition = livePosition
            currentLocationService.updateBalloonDisplayPosition(livePosition)
        }

        // Adjusted descent rate is computed by BalloonTrackService; subscription updates UI
        
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

        // Throttle user location logging to avoid spam
        userLocationLogCount += 1
        if userLocationLogCount % 10 == 1 {
            appLog(String(format: "User (\(userLocationLogCount), every 10th): lat=%.5f lon=%.5f alt=%.0f acc=%.1f/%.1f",
                           locationData.latitude,
                           locationData.longitude,
                           locationData.altitude,
                           locationData.horizontalAccuracy,
                           locationData.verticalAccuracy),
                   category: .general, level: .debug)
        }
        
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
        appLog(String(format: "ServiceCoordinator: Timer prediction check: %.1fs/%.0fs -> %@",
                      timeSinceLastAttempt,
                      predictionInterval,
                      shouldTrigger ? "TRIGGERED" : "waiting"),
               category: .general, level: .debug)
        
        return shouldTrigger
    }

    private func updatePredictionTimer(enabled: Bool) {
        if enabled {
            startCoordinatorPredictionTimer()
        } else {
            stopCoordinatorPredictionTimer()
        }
    }

    private func startCoordinatorPredictionTimer() {
        // Only start if not already running
        guard predictionTimer == nil else {
            appLog("ServiceCoordinator: Prediction timer already running", category: .general, level: .debug)
            return
        }

        predictionTimer = Timer.scheduledTimer(withTimeInterval: predictionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let telemetry = self.balloonTelemetry else {
                    appLog("ServiceCoordinator: Timer tick - no telemetry yet", category: .general, level: .debug)
                    return
                }
                if self.shouldRequestPrediction(telemetry) {
                    await self.executePrediction(telemetry: telemetry, measuredDescentRate: self.smoothedDescentRate, force: false)
                }
            }
        }
        appLog("ServiceCoordinator: Prediction timer started (state machine enabled)", category: .general, level: .info)
    }

    private func stopCoordinatorPredictionTimer() {
        predictionTimer?.invalidate()
        predictionTimer = nil
        appLog("ServiceCoordinator: Prediction timer stopped (state machine disabled)", category: .general, level: .info)
    }
    
    private func executePrediction(telemetry: TelemetryData, measuredDescentRate: Double?, force: Bool) async {
        // Skip predictions for landed balloons
        if balloonPositionService.balloonPhase == .landed {
            appLog("ServiceCoordinator: Skipping prediction - balloon is already landed", category: .general, level: .info)
            return
        }

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
            
            // Check if this is first prediction (before updating)
            let wasFirstPrediction = isStartupComplete && landingPoint == nil

            // Update ServiceCoordinator directly with prediction data
            updateMapWithPrediction(predictionData)

            // Trigger map zoom for first prediction after startup
            if wasFirstPrediction {
                appLog("ServiceCoordinator: First prediction after startup - triggering map zoom", category: .general, level: .info)
                triggerStartupMapZoom()
            }

            appLog("ServiceCoordinator: Prediction completed successfully", category: .general, level: .info)
            
        } catch {
            appLog("ServiceCoordinator: Prediction failed: \(error.localizedDescription)", category: .general, level: .error)
        }
    }
    
    // UIEvent handling removed - now handled directly by AppServices
    
    // MARK: - Simplified Business Logic
    
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

        // Trigger route calculation for updated landing point
        Task {
            await updateRoute()
        }

        if let landingCoordinate = prediction.landingPoint {
            landingPointTrackingService.recordLandingPrediction(
                coordinate: landingCoordinate,
                predictedAt: Date(),
                landingEta: prediction.landingTime
            )
        }

        // Check for navigation update after setting new landing point
        if let newLandingPoint = prediction.landingPoint {
            checkForNavigationUpdate(previousLandingPoint: previousLandingPoint, newLandingPoint: newLandingPoint)
        }
        
        // Phase 2: Mirror landing point in DomainModel
        // Landing point already updated in ServiceCoordinator state above
        
        // MapPresenter consumes updated coordinator state to refresh annotations

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
        // Don't calculate routes during startup state - wait for state machine to transition
        guard balloonPositionService.currentTelemetryState != .startup else {
            appLog("ServiceCoordinator: Route calculation skipped - state machine in startup", category: .general, level: .debug)
            return
        }

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
                } else {
                    userRoute = nil
                    isRouteVisible = false
                    routeData = nil
                }
                return
            }
        }
        
        // Calculating route (logged on completion)
        
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
    
    
    // MARK: - Persistence Data Loading (Per FSD)
    
    func loadPersistenceData() {
        appLog("ServiceCoordinator: Loading persistence data per FSD requirements", category: .general, level: .info)
        
        // 1. Prediction parameters - already loaded in UserSettings ✅
        
        // 2. Historic track data - load and add to current track if sonde matches
        // Note: This will be handled by BalloonTrackService when first telemetry arrives
        
        // Landing point state is supplied by BalloonTrackService and persistence caches.
        
        appLog("ServiceCoordinator: Persistence data loading complete", category: .general, level: .info)
        
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
    

    // MARK: - UI Support Methods

    /// Trigger map zoom to show all overlays (startup final step)
    func triggerStartupMapZoom() {
        showAllAnnotations = true
        appLog("ServiceCoordinator: Triggered startup map zoom to show all overlays", category: .general, level: .info)

        // Reset flag after brief delay to allow for future triggers
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showAllAnnotations = false
        }
    }

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
                appLog("ServiceCoordinator: Cycling directions require iOS 14+. Falling back to walking mode", category: .general, level: .info)
            }
        }

        let launchOptions = [
            MKLaunchOptionsDirectionsModeKey: directionsMode
        ]

        mapItem.openInMaps(launchOptions: launchOptions)
        appLog("ServiceCoordinator: Opened Apple Maps navigation to landing point", category: .general, level: .info)

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

    // Frequency sync prompt methods removed - automatic sync only

    func logZoomChange(_ description: String, span: MKCoordinateSpan, center: CLLocationCoordinate2D? = nil) {
        let zoomKm = Int(span.latitudeDelta * 111) // Approximate km conversion
        if let center = center {
            appLog("🔍 ZOOM: \(description) - \(zoomKm)km (\(String(format: "%.3f", span.latitudeDelta))°) at [\(String(format: "%.4f", center.latitude)), \(String(format: "%.4f", center.longitude))]", category: .general, level: .info)
        } else {
            appLog("🔍 ZOOM: \(description) - \(zoomKm)km (\(String(format: "%.3f", span.latitudeDelta))°)", category: .general, level: .info)
        }
    }

    // MARK: - Prediction Logic Now Handled by Independent BalloonTrackPredictionService
    // All prediction functionality moved to BalloonTrackPredictionService for better separation of concerns
}
