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
    let persistenceService: PersistenceService
    let predictionCache: PredictionCache
    let routingCache: RoutingCache

    // MARK: - Published Properties

    // Startup sequence state
    @Published var startupProgress: String = "Initializing services..."
    @Published var currentStartupStep: Int = 0
    @Published var isStartupComplete: Bool = false
    @Published var showLogo: Bool = true
    @Published var showTrackingMap: Bool = false


    // Core services
    let currentLocationService: CurrentLocationService
    let bleCommunicationService: BLECommunicationService
    let predictionService: PredictionService

    // Domain services
    let balloonPositionService: BalloonPositionService
    let balloonTrackService: BalloonTrackService
    let landingPointTrackingService: LandingPointTrackingService
    let navigationService: NavigationService

    private var cancellables = Set<AnyCancellable>()

    // User settings reference (shared instance from AppServices)
    let userSettings: UserSettings

    // App settings reference (for transport mode and other app-level settings)
    var appSettings: AppSettings?

    // Frequency sync proposal forwarded from APRS service
    @Published var frequencySyncProposal: FrequencySyncProposal? = nil

    // 60-second prediction timer (as referenced in comments)
    private var predictionTimer: Timer? = nil

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

    deinit {
        // Clean up prediction timer
        predictionTimer?.invalidate()
    }

    private func configurePredictionService() {
        predictionService.setServiceCoordinator(self)
        predictionService.setBalloonPositionService(balloonPositionService)
        // Shared dependencies (predictionCache, userSettings) now passed via constructor
    }

    // MARK: - Frequency Sync Interface

    /// Accept the frequency sync proposal
    func acceptFrequencySyncProposal() {
        guard let proposal = frequencySyncProposal else { return }

        // Delegate to BLE service for frequency sync
        bleCommunicationService.acceptFrequencySync(frequency: proposal.frequency, probeType: proposal.probeType, source: "ServiceCoordinator-UserAccepted")

        // Clear the proposal
        frequencySyncProposal = nil

        appLog("ServiceCoordinator: Frequency sync proposal accepted and executed", category: .service, level: .info)
    }

    /// Reject the frequency sync proposal
    func rejectFrequencySyncProposal() {
        guard let proposal = frequencySyncProposal else { return }

        // Delegate to BLE service for rejection handling
        bleCommunicationService.rejectFrequencySync(frequency: proposal.frequency, probeType: proposal.probeType)

        // Clear the proposal
        frequencySyncProposal = nil

        appLog("ServiceCoordinator: Frequency sync proposal rejected", category: .service, level: .info)
    }

    /// Evaluate frequency sync when APRS data is received and RadioSondyGo is connected
    private func evaluateFrequencySync(with radioData: RadioChannelData) {

        // Only evaluate frequency sync when BLE is ready for commands
        guard bleCommunicationService.connectionState.canReceiveCommands else {
            appLog("ServiceCoordinator: BLE not ready for commands (state: \(bleCommunicationService.connectionState)) - skipping frequency sync evaluation", category: .service, level: .debug)
            return
        }

        let aprsFreq = radioData.frequency
        let bleFreq = bleCommunicationService.radioSettings.frequency
        let freqDifference = abs(aprsFreq - bleFreq)
        let freqMismatch = freqDifference > 0.01

        let aprsProbeType = radioData.probeType.isEmpty ? "RS41" : radioData.probeType
        let bleProbeType = bleCommunicationService.radioSettings.probeType
        let probeTypeMismatch = aprsProbeType != bleProbeType

        appLog("ServiceCoordinator: Frequency comparison - APRS: \(String(format: "%.2f", aprsFreq)) MHz, BLE: \(String(format: "%.2f", bleFreq)) MHz, difference: \(String(format: "%.2f", freqDifference)) MHz, mismatch: \(freqMismatch)", category: .service, level: .info)
        appLog("ServiceCoordinator: Probe type comparison - APRS: '\(aprsProbeType)', BLE: '\(bleProbeType)', mismatch: \(probeTypeMismatch)", category: .service, level: .info)

        guard freqMismatch || probeTypeMismatch else {
            appLog("ServiceCoordinator: APRS-BLE frequency/probe match, no sync needed", category: .service, level: .debug)
            return
        }

        appLog("ServiceCoordinator: APRS-BLE frequency sync needed - creating user proposal", category: .service, level: .info)
        createFrequencySyncProposal(aprsFreq: aprsFreq, aprsProbeType: aprsProbeType, bleFreq: bleFreq, bleProbeType: bleProbeType)
    }

    private func createFrequencySyncProposal(aprsFreq: Double, aprsProbeType: String, bleFreq: Double, bleProbeType: String) {
        // Create proposal for user confirmation
        frequencySyncProposal = FrequencySyncProposal(frequency: aprsFreq, probeType: aprsProbeType)

        appLog("ServiceCoordinator: Frequency sync proposal created - APRS: \(String(format: "%.2f", aprsFreq)) MHz \(aprsProbeType) vs BLE: \(String(format: "%.2f", bleFreq)) MHz \(bleProbeType)", category: .service, level: .info)
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


    // MARK: - Startup Sequence

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
        while !bleCommunicationService.connectionState.canReceiveCommands && Date() < connectionTimeout {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second checks
        }
        
        if bleCommunicationService.connectionState.canReceiveCommands {
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
            if bleCommunicationService.latestPosition != nil ||
               bleCommunicationService.latestRadioChannel != nil ||
               bleCommunicationService.latestSettings != nil ||
               !bleCommunicationService.radioSettings.probeType.isEmpty ||
               bleCommunicationService.radioSettings.frequency != 434.0 {
                hasReceivedFirstMessage = true

                // Publish telemetry availability status
                appLog("ServiceCoordinator: First BLE package received, telemetry available: \(bleCommunicationService.latestPosition != nil)", category: .general, level: .info)
                break
            }
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second checks
        }
        
        if !hasReceivedFirstMessage {
            appLog("ServiceCoordinator: No BLE package received within timeout", category: .general, level: .info)
        }
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
        // Position data subscription for potential future coordinator needs
        // Currently position data is accessed directly by consumers

        // Frequency sync evaluation: Listen for APRS radio data changes
        balloonPositionService.aprsService.$latestRadioChannel
            .sink { [weak self] radioData in
                if let radioData = radioData, radioData.telemetrySource == .aprs {
                    self?.evaluateFrequencySync(with: radioData)
                }
            }
            .store(in: &cancellables)

        // Monitor state changes to control 60-second prediction timer
        balloonPositionService.$currentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleStateChangeForPredictionTimer(state)
            }
            .store(in: &cancellables)

        // Landing point coordination: Monitor state changes to determine landing point source
        balloonPositionService.$currentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateLandingPointForState(state)
            }
            .store(in: &cancellables)

        // Landing point coordination: Monitor position data changes for landed states
        balloonPositionService.$currentPositionData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] position in
                self?.handlePositionUpdateForLandingPoint(position)
            }
            .store(in: &cancellables)

        // Landing point coordination: Monitor prediction changes for flying states
        predictionService.$latestPrediction
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prediction in
                self?.handlePredictionUpdateForLandingPoint(prediction)
            }
            .store(in: &cancellables)

        // Sonde change coordination: Monitor balloon name changes
        balloonTrackService.$currentBalloonName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newName in
                self?.handleBalloonNameChange(newName)
            }
            .store(in: &cancellables)

        // Direct subscriptions setup complete
    }



    // MARK: - 60-Second Prediction Timer

    /// Handle state changes to control prediction timer
    private func handleStateChangeForPredictionTimer(_ state: DataState) {
        switch state {
        case .liveBLEFlying, .aprsFallbackFlying:
            // Flying states: start 60-second prediction timer
            startPredictionTimer()
        case .startup, .liveBLELanded, .waitingForAPRS, .aprsFallbackLanded, .noTelemetry:
            // Non-flying states: stop timer to save API quota
            stopPredictionTimer()
        }
    }

    /// Start the 60-second prediction timer for flying states
    private func startPredictionTimer() {
        // Don't start if already running
        guard predictionTimer == nil else { return }

        appLog("ServiceCoordinator: Starting 60-second prediction timer for flying state", category: .service, level: .info)
        predictionService.startAutomaticPredictions()

        predictionTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.predictionTimerFired()
            }
        }
    }

    /// Stop the prediction timer
    private func stopPredictionTimer() {
        guard predictionTimer != nil else { return }

        appLog("ServiceCoordinator: Stopping prediction timer", category: .service, level: .info)
        predictionTimer?.invalidate()
        predictionTimer = nil
        predictionService.stopAutomaticPredictions()
    }

    /// Timer callback: trigger prediction with current position data
    private func predictionTimerFired() {
        guard let position = balloonPositionService.currentPositionData else {
            appLog("ServiceCoordinator: Prediction timer fired but no position data available", category: .service, level: .debug)
            return
        }

        Task {
            await predictionService.triggerPredictionWithPosition(position, trigger: "60s-timer")
        }
    }

    // MARK: - Landing Point Coordination

    /// Determine landing point source based on current state
    private func updateLandingPointForState(_ state: DataState) {
        switch state {
        case .liveBLEFlying, .aprsFallbackFlying, .waitingForAPRS:
            // Flying states: use prediction landing point
            if let prediction = predictionService.latestPrediction,
               let landingPoint = prediction.landingPoint {
                Task {
                    await landingPointTrackingService.updateLandingPoint(landingPoint, source: .prediction)
                }
                appLog("ServiceCoordinator: Landing point updated from prediction for state \(state)", category: .service, level: .debug)
            }

        case .liveBLELanded, .aprsFallbackLanded:
            // Landed states: use current position as landing point
            if let position = balloonPositionService.currentPositionData,
               position.latitude != 0.0, position.longitude != 0.0 {
                let currentPosition = CLLocationCoordinate2D(
                    latitude: position.latitude,
                    longitude: position.longitude
                )
                Task {
                    await landingPointTrackingService.updateLandingPoint(currentPosition, source: .currentPosition)
                }
                appLog("ServiceCoordinator: Landing point updated from current position for state \(state)", category: .service, level: .debug)
            }

        case .startup, .noTelemetry:
            // No landing point available
            appLog("ServiceCoordinator: No landing point for state \(state)", category: .service, level: .debug)
        }
    }

    /// Handle position data updates for landed states
    private func handlePositionUpdateForLandingPoint(_ position: PositionData?) {
        guard let position = position else { return }

        // Only update from position if we're in a landed state
        let state = balloonPositionService.currentState
        guard state == .liveBLELanded || state == .aprsFallbackLanded else {
            return
        }

        // Validate coordinates
        guard position.latitude != 0.0, position.longitude != 0.0 else {
            return
        }

        let currentPosition = CLLocationCoordinate2D(
            latitude: position.latitude,
            longitude: position.longitude
        )

        Task {
            await landingPointTrackingService.updateLandingPoint(currentPosition, source: .currentPosition)
        }
    }

    /// Handle prediction updates for flying states
    private func handlePredictionUpdateForLandingPoint(_ prediction: PredictionData?) {
        guard let prediction = prediction,
              let landingPoint = prediction.landingPoint else {
            return
        }

        // Only update from prediction if we're in a flying state
        let state = balloonPositionService.currentState
        guard state == .liveBLEFlying || state == .aprsFallbackFlying || state == .waitingForAPRS else {
            return
        }

        Task {
            await landingPointTrackingService.updateLandingPoint(landingPoint, source: .prediction)
        }
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
    // MARK: - Sonde Change Orchestration

    private var lastSeenSondeName: String? = nil

    private func handleBalloonNameChange(_ newName: String?) {
        guard let newName = newName, !newName.isEmpty else { return }

        // Check if this is a different sonde
        if let lastSeen = lastSeenSondeName, lastSeen != newName {
            // New sonde detected!
            handleNewSondeDetected(oldName: lastSeen, newName: newName)
        }

        // Update tracking
        lastSeenSondeName = newName
    }

    private func handleNewSondeDetected(oldName: String?, newName: String) {
        appLog("🎈 ServiceCoordinator: New sonde detected - \(oldName ?? "none") → \(newName)", category: .service, level: .info)

        // 1. Reset all services (order: leaf services first)
        navigationService.resetForNewSonde()
        routeCalculationService.resetForNewSonde()
        landingPointTrackingService.resetForNewSonde()
        balloonTrackService.resetForNewSonde()
        predictionService.resetForNewSonde()
        balloonPositionService.resetForNewSonde()

        // 2. Clear caches
        Task {
            await predictionCache.purgeAll()
            await routingCache.purgeAll()
        }

        appLog("✅ ServiceCoordinator: Reset complete for new sonde \(newName)", category: .service, level: .info)
    }

    // MARK: - UI Support Methods


    func openInAppleMaps() {
        // Use single source of truth from LandingPointTrackingService
        guard let landingPoint = landingPointTrackingService.currentLandingPoint else {
            appLog("ServiceCoordinator: Cannot open Apple Maps - no landing point available for state \(balloonPositionService.currentState)", category: .general, level: .error)
            return
        }

        appLog("ServiceCoordinator: Opening Apple Maps with landing point [\(String(format: "%.4f", landingPoint.latitude)), \(String(format: "%.4f", landingPoint.longitude))] from state \(balloonPositionService.currentState)", category: .general, level: .info)
        navigationService.openInAppleMaps(landingPoint: landingPoint)
    }
}
