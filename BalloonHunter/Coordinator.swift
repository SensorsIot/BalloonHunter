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


    // Startup sequence state
    @Published var startupProgress: String = "Initializing services..."
    @Published var currentStartupStep: Int = 0
    @Published var isStartupComplete: Bool = false
    @Published var showLogo: Bool = true
    @Published var showTrackingMap: Bool = false


    // Core services (initialized in init for MapState dependencies)
    let currentLocationService: CurrentLocationService
    let bleCommunicationService: BLECommunicationService
    
    // Phase 3: Prediction Service (injected from AppServices)
    let predictionService: PredictionService
    
    // REQUIRED: Services that generate the events and manage data (injected from AppServices)
    let balloonPositionService: BalloonPositionService
    let balloonTrackService: BalloonTrackService
    let landingPointTrackingService: LandingPointTrackingService
    let navigationService: NavigationService
    
    
    private var cancellables = Set<AnyCancellable>()
    private var lastPredictionTime = Date.distantPast
    private var lastPredictionAttemptTime = Date.distantPast
    private var isPredictionInFlight: Bool = false
    private var predictionTimer: Timer? = nil
    private var hasTriggeredStartupPrediction: Bool = false
    private var lastUserLocation: CLLocationCoordinate2D?
    private var lastLandingPoint: CLLocationCoordinate2D?
    private var lastUserLocationUpdateTime = Date.distantPast

    // Simple timing constants (replace complex mode machine)
    private let predictionInterval: TimeInterval = 60  // Every 60 seconds per requirements
    
    // User settings reference (shared instance from AppServices)
    let userSettings: UserSettings

    // App settings reference (for transport mode and other app-level settings)
    var appSettings: AppSettings?

    // Frequency sync proposal from APRS fallback
    @Published var frequencySyncProposal: FrequencySyncProposal? = nil



    // MARK: - Flight State Computed Properties
    private var isFlying: Bool {
        return balloonPositionService.balloonPhase != .landed &&
               balloonPositionService.balloonPhase != .unknown
    }

    private var isLanded: Bool {
        return balloonPositionService.balloonPhase == .landed
    }


    
    init(
        bleCommunicationService: BLECommunicationService,
        currentLocationService: CurrentLocationService,
        persistenceService: PersistenceService,
        predictionCache: PredictionCache,
        routingCache: RoutingCache,
        predictionService: PredictionService,
        balloonPositionService: BalloonPositionService,
        balloonTrackService: BalloonTrackService,
        landingPointTrackingService: LandingPointTrackingService,
        navigationService: NavigationService,
        userSettings: UserSettings
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
        self.navigationService = navigationService
        self.userSettings = userSettings

        // Set up circular reference for PredictionService
        configurePredictionService()

        setupDirectSubscriptions()

        // Architecture setup complete
    }

    private func configurePredictionService() {
        predictionService.setServiceCoordinator(self)
        predictionService.setBalloonPositionService(balloonPositionService)
        // Shared dependencies (predictionCache, userSettings) now passed via constructor
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

        // Phase 3: Prediction timer will be controlled by state machine
        appLog("STARTUP: Prediction timer will be controlled by state machine", category: .general, level: .info)


        // Services initialized - startup sequence will be triggered by BalloonHunterApp
    }

    func setAppSettings(_ settings: AppSettings) {
        appSettings = settings
        appLog("ServiceCoordinator: AppSettings reference set", category: .general, level: .debug)
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
        

        // Subscribe to frequency sync proposals
        balloonPositionService.$frequencySyncProposal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proposal in
                self?.frequencySyncProposal = proposal
            }
            .store(in: &cancellables)

        // Direct subscriptions setup complete
    }


    /// Accept the APRS frequency sync proposal
    func acceptFrequencySyncProposal() {
        balloonPositionService.acceptFrequencySyncProposal()
    }

    /// Reject the APRS frequency sync proposal
    func rejectFrequencySyncProposal() {
        balloonPositionService.rejectFrequencySyncProposal()
    }

    // MARK: - High-Level UI Methods for View Actions
    
    
    // MARK: - Simplified Event Handlers
    
    // Direct telemetry handling with prediction timing
    private func handleBalloonTelemetry(_ telemetry: TelemetryData) {
        // Suppress verbose per-packet telemetry summary in debug logs

        // Telemetry now accessed directly from BalloonPositionService by consumers
        // Keep frequency visible without waiting for device settings
        if telemetry.frequency > 0 {
        }


        // Display position now managed by BalloonPositionService

        // Adjusted descent rate is computed by BalloonTrackService; subscription updates UI
        
    }
    

    // MARK: - Prediction Logic
    
    // Manual prediction trigger for UI (balloon annotation tap)
    // Note: there is already a high-level triggerPrediction() earlier; keep single definition
    

    
    
    // UIEvent handling removed - now handled directly by AppServices
    
    // MARK: - Simplified Business Logic
    
    // Prediction logic now handled directly in ServiceCoordinator
    
    
    
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
        
        return distance > 100.0  // 100m threshold for significant user movement
    }
    
    private func shouldUpdateRouteForUserMovement() -> Bool {
        let now = Date()
        let timeSinceLastUserUpdate = now.timeIntervalSince(lastUserLocationUpdateTime)
        
        // Check every minute for user movement
        return timeSinceLastUserUpdate > 60.0
    }
    
    
    
    // MARK: - Persistence Data Loading (Per FSD)
    
    func loadPersistenceData() {
        appLog("ServiceCoordinator: Loading persistence data per FSD requirements", category: .general, level: .info)

        // 1. Prediction parameters - already loaded in UserSettings ✅

        // 2. Historic track data - already loaded in PersistenceService and will be automatically
        //    restored by BalloonTrackService when matching sonde telemetry arrives ✅
        let allTracks = persistenceService.getAllTracks()
        appLog("ServiceCoordinator: Found \(allTracks.count) stored balloon tracks ready for automatic restoration", category: .general, level: .info)
        for (sondeName, trackPoints) in allTracks {
            appLog("ServiceCoordinator: Track available for '\(sondeName)' with \(trackPoints.count) points", category: .general, level: .debug)
        }

        // 3. Landing point histories - already loaded in PersistenceService and accessible via methods ✅

        // 4. Device settings - already loaded in PersistenceService ✅

        appLog("ServiceCoordinator: Persistence data loading complete - UserSettings, tracks, and histories restored", category: .general, level: .info)

    }
    
    // MARK: - Helper Methods
    
    
    
    // MARK: - Automatic Descent Rate Calculation moved to BalloonTrackService

    
    // MARK: - Landing Point Management (moved from LandingPointService)
    

    // MARK: - UI Support Methods


    func openInAppleMaps() {
        // Check multiple sources for landing point in new architecture
        var landingPoint: CLLocationCoordinate2D?

        // 1. Try prediction service (for flying states)
        if let predictionLanding = predictionService.latestPrediction?.landingPoint {
            landingPoint = predictionLanding
        }
        // 2. Fallback to balloon position service (for landed states)
        else if let positionLanding = balloonPositionService.landingPoint {
            landingPoint = positionLanding
        }

        guard let finalLandingPoint = landingPoint else {
            appLog("ServiceCoordinator: Cannot open Apple Maps - no landing point available from any source", category: .general, level: .error)
            return
        }

        appLog("ServiceCoordinator: Opening Apple Maps with landing point [\(String(format: "%.4f", finalLandingPoint.latitude)), \(String(format: "%.4f", finalLandingPoint.longitude))]", category: .general, level: .info)
        navigationService.openInAppleMaps(landingPoint: finalLandingPoint)
    }




}
