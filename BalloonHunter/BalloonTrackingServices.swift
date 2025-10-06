import Foundation
import Combine
import CoreLocation
import MapKit
import OSLog

// MARK: - Telemetry State Machine Types

enum DataState: CustomStringConvertible, Equatable {
    case startup
    case liveBLEFlying
    case liveBLELanded
    case waitingForAPRS  // Intermediate state when BLE lost, waiting for APRS response
    case aprsFallbackFlying
    case aprsFallbackLanded
    case noTelemetry

    var description: String {
        switch self {
        case .startup: return "startup"
        case .liveBLEFlying: return "liveBLEFlying"
        case .liveBLELanded: return "liveBLELanded"
        case .waitingForAPRS: return "waitingForAPRS"
        case .aprsFallbackFlying: return "aprsFallbackFlying"
        case .aprsFallbackLanded: return "aprsFallbackLanded"
        case .noTelemetry: return "noTelemetry"
        }
    }

    var requiresAPRSPolling: Bool {
        switch self {
        case .startup, .noTelemetry, .waitingForAPRS, .aprsFallbackFlying, .aprsFallbackLanded:
            return true
        case .liveBLEFlying, .liveBLELanded:
            return false
        }
    }
}

struct TelemetryInputs {
    let bleConnectionState: BLEConnectionState
    let aprsDataAvailable: Bool
    let balloonPhase: BalloonPhase
}

enum LandingPointSource {
    case prediction      // From PredictionService
    case currentPosition // From current balloon telemetry
}

// MARK: - Balloon Position Service

@MainActor
final class BalloonPositionService: ObservableObject {
    // Three-channel data architecture
    @Published var currentPositionData: PositionData?
    @Published var currentRadioChannel: RadioChannelData?

    @Published var currentBalloonName: String?
    @Published var dataSource: TelemetrySource = .ble
    
    var hasReceivedTelemetry: Bool = false

    @Published var aprsDataAvailable: Bool = false

    // State machine
    @Published var currentState: DataState = .startup

    // Balloon flight state (moved from BalloonTrackService)
    @Published var balloonPhase: BalloonPhase = .unknown

    // Display position: shows landing point when landed, live position when flying
    @Published var balloonDisplayPosition: CLLocationCoordinate2D? = nil

    // Cached prediction data for flying state landing point determination

    private var stateEntryTime: Date = Date()
    private var startupTime: Date = Date()
    private var balloonTrackService: BalloonTrackService?
    private var isStartupComplete: Bool = false

    // Sonde change handling - stash new packet while clearing old sonde data
    private var sondeChangePosition: PositionData?
    private var sondeChangeSource: String?

    private let bleService: BLECommunicationService
    let aprsService: APRSDataService
    private let currentLocationService: CurrentLocationService
    private let persistenceService: PersistenceService
    private let predictionService: PredictionService
    private let routeCalculationService: RouteCalculationService
    private var landingPointTrackingService: LandingPointTrackingService?
    private weak var serviceCoordinator: ServiceCoordinator?
    private var currentUserLocation: LocationData?
    private var lastTelemetryTime: Date?
    private var lastLoggedBurstKillerTime: Int?
    private var processingCount: Int = 0
    private var landingLogCount: Int = 0
    private var speedCheckLogCount: Int = 0
    private var cancellables = Set<AnyCancellable>()
    private let bleVisualStalenessThreshold: TimeInterval = 3.0 // 3 seconds for red icon
    private let aprsStalenessThreshold: TimeInterval = 30.0 // 30 seconds for APRS


    init(bleService: BLECommunicationService,
         aprsService: APRSDataService,
         currentLocationService: CurrentLocationService,
         persistenceService: PersistenceService,
         predictionService: PredictionService,
         routeCalculationService: RouteCalculationService) {
        self.bleService = bleService
        self.aprsService = aprsService
        self.currentLocationService = currentLocationService
        self.persistenceService = persistenceService
        self.predictionService = predictionService
        self.routeCalculationService = routeCalculationService
        setupSubscriptions()
        // BalloonPositionService initialized
    }

    // Set reference to BalloonTrackService for landing detection
    func setBalloonTrackService(_ balloonTrackService: BalloonTrackService) {
        self.balloonTrackService = balloonTrackService

        // Trigger initial state evaluation
        evaluateDataState()
    }

    // Set reference to LandingPointTrackingService for service chain
    func setLandingPointTrackingService(_ landingPointTrackingService: LandingPointTrackingService) {
        self.landingPointTrackingService = landingPointTrackingService
        appLog("BalloonPositionService: LandingPointTrackingService configured", category: .service, level: .info)
    }

    // Set reference to ServiceCoordinator for sonde change coordination
    func setServiceCoordinator(_ coordinator: ServiceCoordinator) {
        self.serviceCoordinator = coordinator
        appLog("BalloonPositionService: ServiceCoordinator configured", category: .service, level: .info)
    }
    
    private func setupSubscriptions() {
        // Legacy telemetry subscriptions removed - using three-channel architecture

        // MARK: - Three-Channel Architecture Subscriptions

        // Subscribe to BLE position data stream
        bleService.$latestPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] positionData in
                self?.handlePositionUpdate(positionData, source: "BLE")
            }
            .store(in: &cancellables)

        // Subscribe to BLE radio channel data stream (for frequency sync only)
        bleService.$latestRadioChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] radioData in
                self?.handleRadioChannelUpdate(radioData, source: "BLE")
            }
            .store(in: &cancellables)

        // Subscribe to APRS position data stream (position only from APRS)
        aprsService.$latestPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] positionData in
                // Process APRS data when: already in APRS mode, waiting for APRS, or no BLE data available
                guard let self = self else { return }
                if self.currentState == .waitingForAPRS ||
                   self.currentState == .aprsFallbackFlying ||
                   self.currentState == .aprsFallbackLanded ||
                   self.currentPositionData == nil {
                    self.handlePositionUpdate(positionData, source: "APRS")
                }
            }
            .store(in: &cancellables)


        // Note: Frequency sync is now handled in three-channel data handlers

        // Monitor BLE connection state for state machine evaluation
        bleService.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateDataState()
            }
            .store(in: &cancellables)




    }


    // MARK: - Three-Channel Data Handlers

    private func handlePositionUpdate(_ positionData: PositionData?, source: String) {
        guard let position = positionData else { return }

        // Debug: Always log when APRS position arrives
        if source == "APRS" {
            appLog("BalloonPositionService: APRS position received for \(position.sondeName) - BLE available: \(bleService.connectionState.hasTelemetry)", category: .service, level: .info)
        }

        // Only process APRS position when BLE telemetry is not available (arbitration)
        if source == "APRS" && bleService.connectionState.hasTelemetry {
            appLog("BalloonPositionService: APRS position received but BLE telemetry is available - ignoring", category: .service, level: .debug)
            return
        }

        let now = Date()

        // Log every APRS position for tracking
        appLog("BalloonPositionService: Processing \(source) position for \(position.sondeName) at [\(String(format: "%.5f", position.latitude)), \(String(format: "%.5f", position.longitude))] alt=\(Int(position.altitude))m", category: .service, level: .info)

        // Detect sonde change BEFORE updating anything (Per FSD: Sonde Change Flow)
        let incomingName = position.sondeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !incomingName.isEmpty, let currentName = currentBalloonName, currentName != incomingName {
            appLog("🎈 BalloonPositionService: Sonde name change detected: \(currentName) → \(incomingName)", category: .service, level: .info)

            // Sequential steps per FSD:
            // 1. Detect - done above
            // 2. Stash the new telemetry packet
            sondeChangePosition = position
            sondeChangeSource = source
            appLog("BalloonPositionService: Stashed new sonde telemetry from \(source)", category: .service, level: .info)

            // 3. Call coordinator.clearAllSondeData() - wait for completion
            if let coordinator = serviceCoordinator {
                coordinator.clearAllSondeData()
            } else {
                appLog("BalloonPositionService: WARNING - No ServiceCoordinator available for sonde change", category: .service, level: .error)
            }

            // 4. Trigger async APRS track fetch (don't wait)
            balloonTrackService?.fillTrackGapsFromAPRS()

            // 5. Process stashed packet normally (updates currentBalloonName, publishes to subscribers)
            if let stashedPosition = sondeChangePosition, let stashedSource = sondeChangeSource {
                appLog("BalloonPositionService: Processing stashed telemetry for new sonde \(stashedPosition.sondeName)", category: .service, level: .info)

                // Clear stash
                sondeChangePosition = nil
                sondeChangeSource = nil

                // Process as if it just arrived (recursive call with fresh state)
                handlePositionUpdate(stashedPosition, source: stashedSource)
            }

            // 6. Return - processing complete
            return
        }

        // Update position data
        currentPositionData = position

        // Update balloon phase based on new position
        updateBalloonPhase()

        // Update current state
        currentBalloonName = position.sondeName
        hasReceivedTelemetry = true
        lastTelemetryTime = now
        dataSource = (source == "APRS") ? .aprs : .ble

        // Update balloon display position based on state
        updateBalloonDisplayPosition()
        if source == "APRS" {
            aprsDataAvailable = true
        }

        // Update APRS service with BLE sonde name for mismatch detection
        if source == "BLE" {
            aprsService.updateBLESondeName(position.sondeName)
        }


        // Trigger state machine evaluation when telemetry source changes
        evaluateDataState()

        // Position data now available through @Published properties
    }

    private func handleRadioChannelUpdate(_ radioData: RadioChannelData?, source: String) {
        guard let radio = radioData else { return }

        // Update radio channel for frequency sync logic
        currentRadioChannel = radio
    }

    
    

    // MARK: - Telemetry State Machine

    private func evaluateDataState() {

        let inputs = TelemetryInputs(
            bleConnectionState: bleService.connectionState,
            aprsDataAvailable: aprsDataAvailable,
            balloonPhase: balloonPhase
        )


        let newState = determineNextState(inputs: inputs)

        if newState != currentState {
            let timeInState = Date().timeIntervalSince(stateEntryTime)

            // Comprehensive system state logging with all decision factors
            let deviceInfo = bleService.connectionState.isConnected ? "connected" : "disconnected"
            let msgAge = bleService.lastMessageTimestamp != nil ? "\(Int(Date().timeIntervalSince(bleService.lastMessageTimestamp!)))s" : "∞"
            let sondeInfo = currentPositionData?.sondeName ?? "none"
            let altInfo = currentPositionData != nil ? "\(Int(currentPositionData!.altitude))m" : "none"

            // Key decision factors
            let startupStatus = isStartupComplete ? "✅" : "⏳"
            let debounceStatus = timeInState >= 30.0 ? "✅30s" : "⏳\(String(format: "%.1f", timeInState))s"
            // Compute staleness directly from BLE service
            let isStale = bleService.lastMessageTimestamp.map { Date().timeIntervalSince($0) > 3.0 } ?? true
            let staleStatus = isStale ? "⚠️stale" : "✅fresh"

            appLog("🔄 DataState: \(currentState) → \(newState) | BLE:\(inputs.bleConnectionState) APRS:\(inputs.aprsDataAvailable) Phase:\(inputs.balloonPhase) | Device:\(deviceInfo) Msg:\(msgAge) Sonde:\(sondeInfo) Alt:\(altInfo) | Startup:\(startupStatus) Debounce:\(debounceStatus) Data:\(staleStatus) AnyData:\(inputs.bleConnectionState.hasTelemetry || inputs.aprsDataAvailable)", category: .service, level: .info)
            transition(to: newState)
        }

    }

    private func determineNextState(inputs: TelemetryInputs) -> DataState {
        let timeInCurrentState = Date().timeIntervalSince(stateEntryTime)

        switch currentState {
        case .startup:
            return evaluateStartupTransitions(inputs: inputs)

        case .liveBLEFlying, .liveBLELanded:
            return evaluateLiveBLETransitions(inputs: inputs)

        case .waitingForAPRS:
            return evaluateWaitingForAPRSTransitions(inputs: inputs, timeInState: timeInCurrentState)

        case .aprsFallbackFlying:
            return evaluateAPRSFallbackFlyingTransitions(inputs: inputs, timeInState: timeInCurrentState)

        case .aprsFallbackLanded:
            return evaluateAPRSFallbackLandedTransitions(inputs: inputs, timeInState: timeInCurrentState)

        case .noTelemetry:
            return evaluateNoTelemetryTransitions(inputs: inputs)
        }
    }

    private func transition(to newState: DataState) {
        currentState = newState
        stateEntryTime = Date()
        handleStateTransition(to: newState)
    }

    private func handleStateTransition(to state: DataState) {
        switch state {
        case .startup:
            // Startup state - enable APRS polling to search for available data
            aprsService.enablePolling()

        case .noTelemetry:
            // No telemetry sources available - enable APRS polling to search for data
            aprsService.enablePolling()

        case .liveBLEFlying:
            // BLE telemetry active, balloon flying
            aprsService.disablePolling()
            // Trigger PredictionService with BLE balloon position
            if let position = currentPositionData {
                Task {
                    await predictionService.triggerPredictionWithPosition(position, trigger: "state-machine")
                }
            }

        case .liveBLELanded:
            // BLE telemetry active, balloon landed
            aprsService.disablePolling()
            // Set landing point to current balloon position and trigger route calculation
            if let position = currentPositionData {
                let landingCoord = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
                Task {
                    await landingPointTrackingService?.updateLandingPoint(landingCoord, source: .currentPosition)
                }
            }

        case .waitingForAPRS:
            // BLE lost - start APRS polling and wait for response
            aprsService.enablePolling()
            appLog("BalloonPositionService: Starting APRS polling - waiting for telemetry response", category: .service, level: .info)
            // Keep existing landing point

        case .aprsFallbackFlying:
            // APRS fallback while flying - enable polling and frequency monitoring
            aprsService.enablePolling()
            // Trigger PredictionService with APRS balloon position
            if let position = currentPositionData {
                Task {
                    await predictionService.triggerPredictionWithPosition(position, trigger: "state-machine")
                }
            }
            // Fill track from APRS historical data when entering APRS fallback mode
            balloonTrackService?.fillTrackGapsFromAPRS()

        case .aprsFallbackLanded:
            // APRS fallback with old/stale data indicating landing
            aprsService.enablePolling()
            // Set landing point to current balloon position and trigger route calculation
            if let position = currentPositionData {
                let landingCoord = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
                Task {
                    await landingPointTrackingService?.updateLandingPoint(landingCoord, source: .currentPosition)
                }
            }
            // Fill track from APRS historical data when entering APRS fallback mode
            balloonTrackService?.fillTrackGapsFromAPRS()
        }

        // Update staleness thresholds based on expected telemetry source
        updateStalenessThresholds(for: state)

        // Notify other services of state-specific behavior changes
        notifyStateSpecificBehavior(state)
    }

    // MARK: - Prediction Integration

    // Landing point calculation is now handled by LandingPointTrackingService via service chain


    private func updateStalenessThresholds(for state: DataState) {
        // Different staleness thresholds based on active telemetry source
        switch state {
        case .startup, .noTelemetry:
            // No active telemetry - use default thresholds
            break

        case .liveBLEFlying, .liveBLELanded:
            // BLE active - shorter staleness threshold for real-time data
            // Already handled by existing bleStalenessThreshold
            break

        case .waitingForAPRS:
            // Waiting for APRS - use default thresholds
            break

        case .aprsFallbackFlying, .aprsFallbackLanded:
            // APRS fallback - longer staleness threshold for network-based data
            // Already handled by existing aprsStalenessThreshold
            break
        }
    }

    private func notifyStateSpecificBehavior(_ state: DataState) {
        // Update published properties for other services to observe
        switch state {
        case .startup, .noTelemetry:
            // No predictions, no landing detection
            break

        case .liveBLEFlying:
            // BLE flying - enable all tracking functionality
            break

        case .liveBLELanded:
            // BLE landed - disable predictions, use live position as landing point
            break

        case .waitingForAPRS:
            // Waiting for APRS response - keep previous functionality disabled
            break

        case .aprsFallbackFlying:
            // APRS flying - enable predictions but more cautious landing detection
            break

        case .aprsFallbackLanded:
            // APRS landed - disable predictions, use APRS position as landing point
            break
        }

    }

    // MARK: - State Transition Evaluators

    private func evaluateStartupTransitions(inputs: TelemetryInputs) -> DataState {
        // Stay in startup until startup sequence is complete
        guard isStartupComplete else {
            return .startup
        }

        // After startup completion, evaluate based on available telemetry sources
        if inputs.bleConnectionState.hasTelemetry && inputs.balloonPhase == .landed {
            return .liveBLELanded
        }
        if inputs.bleConnectionState.hasTelemetry {
            return .liveBLEFlying
        }
        if inputs.aprsDataAvailable && inputs.balloonPhase == .landed {
            return .aprsFallbackLanded
        }
        if inputs.aprsDataAvailable {
            // For unknown balloon phase, default to flying mode until phase is determined
            return .aprsFallbackFlying
        }

        // Check if APRS priming was successful during startup
        if aprsService.aprsSerialName != nil {
            // APRS data available from priming - start fallback polling
            return inputs.balloonPhase == .landed ? .aprsFallbackLanded : .aprsFallbackFlying
        }

        return .noTelemetry
    }

    private func evaluateLiveBLETransitions(inputs: TelemetryInputs) -> DataState {
        // If BLE no longer has telemetry (connection state downgraded), transition to APRS
        if !inputs.bleConnectionState.hasTelemetry {
            return .waitingForAPRS
        }

        // Switch between flying/landed based on balloon phase
        return inputs.balloonPhase == .landed ? .liveBLELanded : .liveBLEFlying
    }

    private func evaluateWaitingForAPRSTransitions(inputs: TelemetryInputs, timeInState: TimeInterval) -> DataState {
        // BLE recovery takes priority
        if inputs.bleConnectionState.hasTelemetry {
            appLog("BalloonPositionService: BLE recovered while waiting for APRS", category: .service, level: .info)
            return inputs.balloonPhase == .landed ? .liveBLELanded : .liveBLEFlying
        }

        // APRS data arrived - transition to appropriate APRS fallback state
        if inputs.aprsDataAvailable {
            appLog("BalloonPositionService: APRS data received - transitioning to APRS fallback", category: .service, level: .info)
            return inputs.balloonPhase == .landed ? .aprsFallbackLanded : .aprsFallbackFlying
        }

        // Timeout after 10 seconds of waiting for APRS (2x network retry cycles)
        if timeInState > 10.0 {
            appLog("BalloonPositionService: APRS timeout after 10s - no telemetry available", category: .service, level: .error)
            return .noTelemetry
        }

        // Stay in waiting state
        return .waitingForAPRS
    }

    private func evaluateAPRSFallbackFlyingTransitions(inputs: TelemetryInputs, timeInState: TimeInterval) -> DataState {
        // Check if this is a new balloon (immediate transition without debounce)
        let isNewBalloon = isNewBalloonDetected()

        if isNewBalloon {
            appLog("BalloonPositionService: New balloon detected - bypassing 30s debounce for immediate BLE transition", category: .service, level: .info)
        }

        if inputs.bleConnectionState.hasTelemetry && (timeInState >= 30.0 || isNewBalloon) {
            return .liveBLEFlying
        }
        if inputs.balloonPhase == .landed {
            return .aprsFallbackLanded
        }
        if !inputs.aprsDataAvailable {
            return .noTelemetry
        }
        return .aprsFallbackFlying
    }

    private func evaluateAPRSFallbackLandedTransitions(inputs: TelemetryInputs, timeInState: TimeInterval) -> DataState {
        // Check if this is a new balloon (immediate transition without debounce)
        let isNewBalloon = isNewBalloonDetected()

        if isNewBalloon {
            appLog("BalloonPositionService: New balloon detected - bypassing 30s debounce for immediate BLE transition", category: .service, level: .info)
        }

        if inputs.bleConnectionState.hasTelemetry && (timeInState >= 30.0 || isNewBalloon) {
            return inputs.balloonPhase == .landed ? .liveBLELanded : .liveBLEFlying
        }
        if inputs.balloonPhase != .landed {
            return .aprsFallbackFlying
        }
        if !inputs.aprsDataAvailable {
            return .noTelemetry
        }
        return .aprsFallbackLanded
    }

    private func evaluateNoTelemetryTransitions(inputs: TelemetryInputs) -> DataState {
        if inputs.bleConnectionState.hasTelemetry && inputs.balloonPhase == .landed {
            return .liveBLELanded
        }
        if inputs.bleConnectionState.hasTelemetry {
            return .liveBLEFlying
        }
        if inputs.aprsDataAvailable && inputs.balloonPhase == .landed {
            return .aprsFallbackLanded
        }
        if inputs.aprsDataAvailable {
            return .aprsFallbackFlying
        }
        return .noTelemetry
    }

    /// Detect if BLE telemetry represents a new balloon (different sonde name)
    private func isNewBalloonDetected() -> Bool {
        guard let blePosition = bleService.latestPosition,
              !blePosition.sondeName.isEmpty else {
            return false
        }

        let bleSondeName = blePosition.sondeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSondeName = currentPositionData?.sondeName.trimmingCharacters(in: .whitespacesAndNewlines)

        // New balloon if BLE has a different sonde name than current telemetry
        return bleSondeName != currentSondeName
    }

    // Convenience methods for policies
    func getBalloonLocation() -> CLLocationCoordinate2D? {
        guard let position = currentPositionData else { return nil }
        return CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
    }

    func getLatestPositionData() -> PositionData? {
        return currentPositionData
    }
    

    /// Trigger state evaluation after APRS priming (called by ServiceCoordinator)
    func triggerStateEvaluation() {
        evaluateDataState()
    }

    /// Refresh current state's service configuration (for foreground resume or sonde change)
    /// Re-applies the current state's logic to ensure services are properly configured
    func refreshCurrentState(skipHistoricalFill: Bool = false) {
        appLog("BalloonPositionService: Refreshing current state (\(currentState)) service configuration", category: .service, level: .info)
        handleStateTransition(to: currentState)

        // Fill track from APRS historical data (works even with empty track)
        // Skip during sonde change - will be triggered after new sonde name is established
        if !skipHistoricalFill {
            balloonTrackService?.fillTrackGapsFromAPRS()
        }
    }

    /// Mark startup sequence as complete and trigger final state evaluation
    func completeStartup() {
        isStartupComplete = true
        appLog("BalloonPositionService: Startup marked as complete - evaluating final state", category: .service, level: .info)
        evaluateDataState()
    }




    // MARK: - Landing Detection (moved from BalloonTrackService)

    /// Calculate landing detection based on net movement across packets
    private func calculateLandingDetection() -> Bool {
        guard let balloonTrackService = balloonTrackService else { return false }

        // Start evaluation at packet 5 (need 5 packets: 0,1,2,3,4)
        guard balloonTrackService.currentBalloonTrack.count >= 5 else { return false }

        // Dynamic window logic:
        // Packets 5-19: expand from packet 0 to current packet
        // Packet 20+: sliding window of most recent 20 packets
        let availablePackets = balloonTrackService.currentBalloonTrack.count
        let windowSize = min(20, availablePackets)
        let recentPoints = Array(balloonTrackService.currentBalloonTrack.suffix(windowSize))

        guard let startPoint = recentPoints.first, let endPoint = recentPoints.last else {
            return false
        }

        // Calculate time window for speed calculation
        let timeWindow = endPoint.timestamp.timeIntervalSince(startPoint.timestamp)
        guard timeWindow > 0 else { return false }

        // Calculate net movement distance across entire window (3D displacement)
        let latToMeters = 111320.0 // meters per degree latitude
        let lonToMeters = latToMeters * cos(endPoint.latitude * .pi / 180)

        let dx = (endPoint.longitude - startPoint.longitude) * lonToMeters
        let dy = (endPoint.latitude - startPoint.latitude) * latToMeters
        let dz = endPoint.altitude - startPoint.altitude

        let netDistance = sqrt(dx * dx + dy * dy + dz * dz) // meters
        let netSpeedMS = netDistance / timeWindow // m/s
        let netSpeedKmh = netSpeedMS * 3.6 // km/h for logging

        // Simple thresholds
        let landingThresholdKmh = 3.0 // 3 km/h
        let landingThresholdMS = landingThresholdKmh / 3.6 // 0.83 m/s
        let altitudeThresholdM = 3000.0

        // Simple boolean logic: speed < 3 km/h AND altitude < 3000m
        let isLanded = (netSpeedMS < landingThresholdMS) && (endPoint.altitude < altitudeThresholdM)

        // Only log altitude threshold when relevant
        let altitudeInfo = endPoint.altitude < 10000 ? " (below 10km)" : ""
        let thresholdInfo = endPoint.altitude < altitudeThresholdM ? " alt<3km" : ""

        appLog(String(format: "🎯 LANDING [%d]: %.1fm @%.1fkm/h alt=%.0fm%@%@ win=%.1fs → %@",
                      windowSize, netDistance, netSpeedKmh, endPoint.altitude,
                      altitudeInfo, thresholdInfo, timeWindow,
                      isLanded ? "LANDED" : "FLYING"),
               category: .general, level: .debug)

        return isLanded
    }

    /// Update balloon phase based on position data and landing detection
    private func updateBalloonPhase() {
        guard let currentPosition = currentPositionData else {
            balloonPhase = .unknown
            return
        }

        // HIGHEST PRIORITY: Check for historical landing (20+ minutes stationary in track history)
        // This is definitive - once detected, balloon stays landed regardless of subsequent movement
        if let balloonTrack = balloonTrackService, balloonTrack.historicalLandingDetected {
            balloonPhase = .landed
            appLog("BalloonPositionService: Historical landing detected - balloon marked as LANDED (stationary period at \(balloonTrack.historicalLandingTime?.description ?? "unknown"))", category: .service, level: .info)
            return
        }

        // Check for old APRS data (age-based landing)
        // Use telemetry timestamp (when balloon last transmitted) to detect landing
        let positionAge = Date().timeIntervalSince(currentPosition.timestamp)
        let isAprsPosition = currentPosition.telemetrySource == .aprs
        let aprsLandingAgeThreshold = 120.0 // 2 minutes

        if isAprsPosition && positionAge > aprsLandingAgeThreshold {
            balloonPhase = .landed
            appLog("BalloonPositionService: APRS age-based landing detected - balloon marked as LANDED (telemetry age: \(Int(positionAge))s)", category: .service, level: .info)
            return
        }

        // BLE landing detection with 5-packet requirement
        let landingDetected = calculateLandingDetection()

        if landingDetected {
            balloonPhase = .landed
        } else {
            // Determine flight phase based on vertical speed
            if currentPosition.verticalSpeed > 0 {
                balloonPhase = .ascending
            } else if currentPosition.verticalSpeed < 0 {
                balloonPhase = currentPosition.altitude < 10_000 ? .descendingBelow10k : .descendingAbove10k
            } else {
                balloonPhase = .unknown
            }
        }

        // DEBUG: Critical debugging for balloon phase
    }

    // MARK: - Balloon Display Position Management (moved from ServiceCoordinator)

    private func updateBalloonDisplayPosition() {
        // Use landing point when landed, otherwise use live position data
        if balloonPhase == .landed, let balloonTrackService = balloonTrackService, let landingPosition = balloonTrackService.landingPosition {
            balloonDisplayPosition = landingPosition
            currentLocationService.updateBalloonDisplayPosition(landingPosition)
            appLog("BalloonPositionService: Display position set to landing point [\(String(format: "%.5f", landingPosition.latitude)), \(String(format: "%.5f", landingPosition.longitude))]", category: .service, level: .info)
        } else if let position = currentPositionData {
            let livePosition = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
            balloonDisplayPosition = livePosition
            currentLocationService.updateBalloonDisplayPosition(livePosition)
            appLog("BalloonPositionService: Display position set to live position [\(String(format: "%.5f", livePosition.latitude)), \(String(format: "%.5f", livePosition.longitude))]", category: .service, level: .info)
        } else {
            appLog("BalloonPositionService: Cannot update display position - no position data available (phase=\(balloonPhase))", category: .service, level: .debug)
        }
    }

    // MARK: - Sonde Change Handling

    func clearState() {
        // Clear all state variables (preserve stashed packet and state machine tracking)
        currentPositionData = nil
        currentRadioChannel = nil
        // currentBalloonName preserved - will be updated from new packet
        dataSource = .ble
        hasReceivedTelemetry = false
        aprsDataAvailable = false
        balloonPhase = .unknown
        balloonDisplayPosition = nil
        lastTelemetryTime = nil
        lastLoggedBurstKillerTime = nil
        processingCount = 0
        landingLogCount = 0
        speedCheckLogCount = 0
        // Do NOT clear: sondeChangePosition, sondeChangeSource (used for stashing during sonde change)
        // Do NOT clear: currentState, stateEntryTime, startupTime, isStartupComplete (state machine)

        appLog("BalloonPositionService: State cleared for new sonde", category: .service, level: .info)
    }

}

// MARK: - Balloon Track Service

@MainActor
final class BalloonTrackService: ObservableObject {
    @Published var currentBalloonTrack: [BalloonTrackPoint] = []
    @Published var currentBalloonName: String?
    var currentEffectiveDescentRate: Double?
    var trackUpdated = PassthroughSubject<Void, Never>()
    @Published var motionMetrics: BalloonMotionMetrics = BalloonMotionMetrics(
        rawHorizontalSpeedMS: 0,
        rawVerticalSpeedMS: 0,
        smoothedHorizontalSpeedMS: 0,
        smoothedVerticalSpeedMS: 0,
        adjustedDescentRateMS: nil
    )
    
    // Landing detection
    @Published var landingPosition: CLLocationCoordinate2D?
    @Published var historicalLandingDetected: Bool = false
    @Published var historicalLandingTime: Date?

    // Smoothed telemetry data (moved from DataPanelView for proper separation of concerns)
    var smoothedHorizontalSpeed: Double = 0
    var smoothedVerticalSpeed: Double = 0
    var adjustedDescentRate: Double? = nil

    
    private let persistenceService: PersistenceService
    let balloonPositionService: BalloonPositionService
    private var aprsService: APRSDataService?
    private var cancellables = Set<AnyCancellable>()

    // Track management
    private var smoothingCounter = 0
    private let saveInterval = 10 // Save every 10 telemetry points

    // Logging throttle counters
    private var speedCheckLogCount: Int = 0
    private var landingLogCount: Int = 0
    private let aprsLandingAgeThreshold: TimeInterval = 120

    // Adjusted descent rate smoothing buffer (FSD: 20 values)
    private var adjustedDescentHistory: [Double] = []


    // Robust speed smoothing state
    private var lastEmaTimestamp: Date? = nil
    private var emaHorizontalMS: Double = 0
    private var emaVerticalMS: Double = 0
    private var slowEmaHorizontalMS: Double = 0
    private var slowEmaVerticalMS: Double = 0
    private var hasEma: Bool = false
    private var hasSlowEma: Bool = false
    private var hWindow: [Double] = []
    private var vWindow: [Double] = []
    private let hampelWindowSize = 10
    private let hampelK = 3.0
    private let vHDeadbandMS: Double = 0.2   // ~0.72 km/h
    private let vVDeadbandMS: Double = 0.05
    private let tauHorizontal: Double = 3.0  // seconds (fast EMA)
    private let tauVertical: Double = 3.0    // seconds (fast EMA)
    private let tauSlowHorizontal: Double = 25.0 // seconds (slow EMA)
    private let tauSlowVertical: Double = 30.0   // seconds (slow EMA)
    
    init(persistenceService: PersistenceService, balloonPositionService: BalloonPositionService) {
        self.persistenceService = persistenceService
        self.balloonPositionService = balloonPositionService

        // BalloonTrackService initialized
        setupSubscriptions()
        loadPersistedDataAtStartup()
    }

    /// Load any persisted balloon data at startup
    private func loadPersistedDataAtStartup() {
        // Load the most recent sonde's track from persistence
        let allTracks = persistenceService.getAllTracks()

        guard !allTracks.isEmpty else {
            appLog("BalloonTrackService: No persisted tracks found", category: .service, level: .info)
            return
        }

        // Find the track with the most recent timestamp
        var mostRecentSondeName: String?
        var mostRecentTimestamp: Date?

        for (sondeName, track) in allTracks {
            guard let lastPoint = track.last else { continue }

            if mostRecentTimestamp == nil || lastPoint.timestamp > mostRecentTimestamp! {
                mostRecentTimestamp = lastPoint.timestamp
                mostRecentSondeName = sondeName
            }
        }

        // Load the most recent track
        if let sondeName = mostRecentSondeName,
           let track = allTracks[sondeName],
           !track.isEmpty {
            self.currentBalloonTrack = track
            self.currentBalloonName = sondeName
            appLog("BalloonTrackService: Loaded most recent persisted track for '\(sondeName)' with \(track.count) points (last update: \(track.last!.timestamp))", category: .service, level: .info)

            // Manually trigger update for subscribers
            trackUpdated.send()

            // Run historical landing detection on persisted track
            detectHistoricalLanding()

            // Fill gaps from APRS historical data after loading persisted track
            fillTrackGapsFromAPRS()
        } else {
            appLog("BalloonTrackService: No valid persisted tracks to load", category: .service, level: .info)
        }
    }
    
    private func setupSubscriptions() {
        // Subscribe to BalloonPositionService position data directly
        balloonPositionService.$currentPositionData
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }  // Filter out nil values
            .sink { [weak self] positionData in
                self?.processPositionData(positionData)
            }
            .store(in: &cancellables)
    }
    
    func processPositionData(_ positionData: PositionData) {
        // Sonde name now comes from BalloonPositionService (single source of truth)
        // BalloonPositionService handles sonde change detection and name updates
        if currentBalloonName == nil {
            currentBalloonName = balloonPositionService.currentBalloonName
        }

        // Only record track points when we have valid telemetry states (not startup, waitingForAPRS, or noTelemetry)
        let state = balloonPositionService.currentState
        guard state != .startup && state != .waitingForAPRS && state != .noTelemetry else {
            appLog("BalloonTrackService: State \(state) - not recording track point", category: .service, level: .info)
            return
        }

        // Compute track-derived speeds prior to appending, so we can store derived values
        var derivedHorizontalMS: Double? = nil
        var derivedVerticalMS: Double? = nil
        if let prev = currentBalloonTrack.last {
            let dt = positionData.timestamp.timeIntervalSince(prev.timestamp)
            if dt > 0 {
                let R = 6371000.0
                let lat1 = prev.latitude * .pi / 180, lon1 = prev.longitude * .pi / 180
                let lat2 = positionData.latitude * .pi / 180, lon2 = positionData.longitude * .pi / 180
                let dlat = lat2 - lat1, dlon = lon2 - lon1
                let a = sin(dlat/2) * sin(dlat/2) + cos(lat1) * cos(lat2) * sin(dlon/2) * sin(dlon/2)
                let c = 2 * atan2(sqrt(a), sqrt(1 - a))
                let distance = R * c // meters
                derivedHorizontalMS = distance / dt
                derivedVerticalMS = (positionData.altitude - prev.altitude) / dt
                // Diagnostics: compare derived vs position data
                let hPos = positionData.horizontalSpeed
                let vPos = positionData.verticalSpeed
                let hDiff = ((derivedHorizontalMS ?? hPos) - hPos) * 3.6
                let vDiff = (derivedVerticalMS ?? vPos) - vPos
                if abs(hDiff) > 30.0 || abs(vDiff) > 2.0 {
                    // Log immediately when significant speed discrepancy detected
                    speedCheckLogCount += 1
                    appLog(String(format: "⚠️ Speed anomaly (\(speedCheckLogCount)): track h=%.1f v=%.1f vs pos h=%.1f v=%.1f (diff: h=%.1f v=%.1f)", (derivedHorizontalMS ?? 0)*3.6, (derivedVerticalMS ?? 0), hPos*3.6, vPos, hDiff, vDiff), category: .service, level: .info)
                }
            }
        }

        let trackPoint = BalloonTrackPoint(
            latitude: positionData.latitude,
            longitude: positionData.longitude,
            altitude: positionData.altitude,
            timestamp: positionData.timestamp,
            verticalSpeed: derivedVerticalMS ?? positionData.verticalSpeed,
            horizontalSpeed: derivedHorizontalMS ?? positionData.horizontalSpeed
        )
        
        currentBalloonTrack.append(trackPoint)

        // Calculate effective descent rate from track history
        updateEffectiveDescentRate()

        // Landing detection now handled by BalloonPositionService

        // CSV logging (all builds)
        DebugCSVLogger.shared.logPosition(positionData)

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
        let positionAge = Date().timeIntervalSince(positionData.timestamp)
        let isAprsPosition = positionData.telemetrySource == .aprs

        // Debug APRS landing detection
        if isAprsPosition {
            appLog("BalloonTrackService: APRS landing check - age=\(Int(positionAge))s, threshold=\(Int(aprsLandingAgeThreshold))s, willLand=\(positionAge > aprsLandingAgeThreshold)", category: .service, level: .info)
        }

        if isAprsPosition && positionAge > aprsLandingAgeThreshold {
            let aprsCoordinate = CLLocationCoordinate2D(latitude: positionData.latitude, longitude: positionData.longitude)
            if landingPosition == nil {
                landingPosition = aprsCoordinate
            }
            appLog("BalloonTrackService: APRS age-based landing detected - balloon marked as LANDED at [\(String(format: "%.4f", aprsCoordinate.latitude)), \(String(format: "%.4f", aprsCoordinate.longitude))]", category: .service, level: .info)
        }


        publishMotionMetrics(rawHorizontal: positionData.horizontalSpeed,
                              rawVertical: positionData.verticalSpeed)

        // Periodic persistence
        smoothingCounter += 1
        if smoothingCounter % saveInterval == 0 {
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
        let alphaSlowH = dtEff / (tauSlowHorizontal + dtEff)
        let alphaSlowV = dtEff / (tauSlowVertical + dtEff)

        if !hasEma {
            emaHorizontalMS = xh
            emaVerticalMS = xv
            hasEma = true
        } else {
            emaHorizontalMS = (1 - alphaH) * emaHorizontalMS + alphaH * xh
            emaVerticalMS = (1 - alphaV) * emaVerticalMS + alphaV * xv
        }

        if !hasSlowEma {
            slowEmaHorizontalMS = xh
            slowEmaVerticalMS = xv
            hasSlowEma = true
        } else {
            slowEmaHorizontalMS = (1 - alphaSlowH) * slowEmaHorizontalMS + alphaSlowH * xh
            slowEmaVerticalMS = (1 - alphaSlowV) * slowEmaVerticalMS + alphaSlowV * xv
        }

        smoothedHorizontalSpeed = emaHorizontalMS
        smoothedVerticalSpeed = emaVerticalMS

        updateAdjustedDescentRate(fallback: slowEmaVerticalMS)
    }

    private func updateAdjustedDescentRate(fallback: Double) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-60)
        let window = currentBalloonTrack.filter { $0.timestamp >= windowStart }
        guard window.count >= 3 else {
            adjustedDescentRate = hasSlowEma ? slowEmaVerticalMS : fallback
            return
        }

        var intervalRates: [Double] = []
        for i in 1..<window.count {
            let dt = window[i].timestamp.timeIntervalSince(window[i-1].timestamp)
            if dt <= 0 { continue }
            let dv = window[i].altitude - window[i-1].altitude
            intervalRates.append(dv / dt)
        }
        guard !intervalRates.isEmpty else {
            adjustedDescentRate = hasSlowEma ? slowEmaVerticalMS : fallback
            return
        }

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
    

    private func publishMotionMetrics(rawHorizontal: Double, rawVertical: Double) {
        motionMetrics = BalloonMotionMetrics(
            rawHorizontalSpeedMS: rawHorizontal,
            rawVerticalSpeedMS: rawVertical,
            smoothedHorizontalSpeedMS: smoothedHorizontalSpeed,
            smoothedVerticalSpeedMS: smoothedVerticalSpeed,
            adjustedDescentRateMS: adjustedDescentRate
        )
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

    /// Set APRS service for historical track filling
    func setAPRSService(_ aprsService: APRSDataService) {
        self.aprsService = aprsService
    }

    /// Fill gaps in track with APRS historical points
    /// Only inserts APRS points where gaps > 1 second exist
    /// BLE data always takes priority (we never overwrite existing points)
    private func fillGapsInTrack(with aprsPoints: [BalloonTrackPoint]) -> Int {
        guard !aprsPoints.isEmpty else { return 0 }
        guard !currentBalloonTrack.isEmpty else {
            // Empty track - just use APRS points as is
            currentBalloonTrack = aprsPoints.sorted { $0.timestamp < $1.timestamp }
            return aprsPoints.count
        }

        let calendar = Calendar.current

        // Helper to round timestamp to nearest second
        func roundToSecond(_ date: Date) -> Date {
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            return calendar.date(from: components) ?? date
        }

        // Build dictionary of APRS points indexed by second for O(1) lookup
        var aprsBySecond: [Date: BalloonTrackPoint] = [:]
        for point in aprsPoints {
            let rounded = roundToSecond(point.timestamp)
            aprsBySecond[rounded] = point
        }

        // Walk through existing track and fill gaps
        var filledTrack: [BalloonTrackPoint] = []
        var pointsAdded = 0

        for i in 0..<currentBalloonTrack.count {
            // Add existing point
            filledTrack.append(currentBalloonTrack[i])

            // Check for gap before next point
            if i < currentBalloonTrack.count - 1 {
                let currentRounded = roundToSecond(currentBalloonTrack[i].timestamp)
                let nextRounded = roundToSecond(currentBalloonTrack[i+1].timestamp)

                let gap = nextRounded.timeIntervalSince(currentRounded)

                // Gap detected (> 1 second)
                if gap > 1.5 {
                    // Fill the gap second by second from APRS data
                    var currentSecond = currentRounded.addingTimeInterval(1)

                    while currentSecond < nextRounded {
                        if let aprsPoint = aprsBySecond[currentSecond] {
                            filledTrack.append(aprsPoint)
                            pointsAdded += 1
                        }
                        currentSecond = currentSecond.addingTimeInterval(1)
                    }
                }
            }
        }

        // Update track with filled version (already in chronological order)
        currentBalloonTrack = filledTrack

        return pointsAdded
    }

    /// Fill track gaps from APRS historical telemetry
    /// Runs asynchronously and does not block UI
    func fillTrackGapsFromAPRS() {
        guard let sondeName = currentBalloonName else {
            appLog("BalloonTrackService: Cannot fill gaps - no sonde name available", category: .service, level: .debug)
            return
        }

        guard let aprsService = aprsService else {
            appLog("BalloonTrackService: Cannot fill gaps - APRS service not available", category: .service, level: .debug)
            return
        }

        // Run in background Task to avoid blocking UI
        Task {
            appLog("BalloonTrackService: Starting APRS historical track fill for '\(sondeName)'", category: .service, level: .info)

            // Debug: Show local track endpoints
            if let firstPoint = currentBalloonTrack.first {
                appLog("BalloonTrackService: Local track first point - lat: \(String(format: "%.5f", firstPoint.latitude)), lon: \(String(format: "%.5f", firstPoint.longitude)), alt: \(String(format: "%.0f", firstPoint.altitude))m", category: .service, level: .info)
            }
            if let lastPoint = currentBalloonTrack.last {
                appLog("BalloonTrackService: Local track last point - lat: \(String(format: "%.5f", lastPoint.latitude)), lon: \(String(format: "%.5f", lastPoint.longitude)), alt: \(String(format: "%.0f", lastPoint.altitude))m", category: .service, level: .info)
            }
            if let landing = landingPosition {
                appLog("BalloonTrackService: Landing point - lat: \(String(format: "%.5f", landing.latitude)), lon: \(String(format: "%.5f", landing.longitude))", category: .service, level: .info)
            }

            let newPoints = await aprsService.fetchHistoricalTelemetryToFillGaps(
                serial: sondeName,
                localTrack: currentBalloonTrack
            )

            if !newPoints.isEmpty {
                // Verify sonde hasn't changed while we were fetching historical data
                await MainActor.run {
                    appLog("BalloonTrackService: Processing \(newPoints.count) historical points for sonde '\(sondeName)'", category: .service, level: .info)

                    guard currentBalloonName == sondeName else {
                        appLog("BalloonTrackService: Sonde changed from '\(sondeName)' to '\(currentBalloonName ?? "nil")' during historical fill - discarding \(newPoints.count) points", category: .service, level: .info)
                        return
                    }

                    // GAP FILLING: Only insert APRS points where gaps exist
                    // BLE data always takes priority - APRS fills gaps only
                    let pointsAdded = fillGapsInTrack(with: newPoints)
                    appLog("BalloonTrackService: Added \(pointsAdded) APRS points to fill gaps, total track now has \(currentBalloonTrack.count) points", category: .service, level: .info)
                    trackUpdated.send()
                    saveCurrentTrack()

                    appLog("BalloonTrackService: Starting historical landing detection on \(currentBalloonTrack.count) points", category: .service, level: .info)
                    // Analyze track history for stationary landing detection
                    detectHistoricalLanding()
                }
            } else {
                appLog("BalloonTrackService: No new historical points to add", category: .service, level: .info)

                appLog("BalloonTrackService: Starting historical landing detection on existing \(currentBalloonTrack.count) points", category: .service, level: .info)
                // Still run historical landing detection on existing track
                detectHistoricalLanding()
            }
        }
    }

    /// Historical landing detection and automatic track removal after landing position
    /// Analyzes APRS track history to find landing point and remove post-landing data
    ///
    /// STANDARD CASE: Balloon lands and stays at landing location
    ///   - Track naturally ends at landing, no truncation needed
    ///   - Handled by real-time landing detection (BalloonPositionService)
    ///
    /// SPECIAL CASES requiring track truncation (checked in order):
    ///   1. Telemetry blackout: Signal lost >20min after burst, then recovered/moved
    ///      → Truncates at gap (everything after is post-recovery transmission)
    ///   2. Stationary period: Transmits stationary 20+ min, then moved during recovery
    ///      → Truncates at stationary point (uses lat/lon/alt moving averages)
    ///      → Altitude detection prevents false positives during descent
    func detectHistoricalLanding() {
        guard currentBalloonTrack.count >= 10 else {
            appLog("BalloonTrackService: Historical landing detection skipped - insufficient track points (\(currentBalloonTrack.count))", category: .service, level: .debug)
            return
        }

        // Calculate actual point density to determine window size for 20 minutes
        let trackDuration = currentBalloonTrack.last!.timestamp.timeIntervalSince(currentBalloonTrack.first!.timestamp)
        let avgPointInterval = trackDuration / Double(currentBalloonTrack.count - 1)
        let targetDuration: TimeInterval = 20 * 60 // 20 minutes
        let windowSize = max(10, Int(targetDuration / avgPointInterval))

        appLog("BalloonTrackService: Track has \(currentBalloonTrack.count) points over \(Int(trackDuration/60))min, using window size \(windowSize) for 20-minute detection", category: .service, level: .info)

        guard currentBalloonTrack.count >= windowSize else {
            appLog("BalloonTrackService: Historical landing detection skipped - insufficient track points (\(currentBalloonTrack.count) < \(windowSize))", category: .service, level: .debug)
            return
        }

        // Step 1: Find burst point (maximum altitude)
        var burstIndex = 0
        var maxAltitude = currentBalloonTrack[0].altitude

        for (index, point) in currentBalloonTrack.enumerated() {
            if point.altitude > maxAltitude {
                maxAltitude = point.altitude
                burstIndex = index
            }
        }

        appLog("BalloonTrackService: Burst point found at index \(burstIndex) with altitude \(Int(maxAltitude))m", category: .service, level: .info)

        // Step 2: Only search for landing AFTER burst
        let searchStartIndex = burstIndex + windowSize

        guard searchStartIndex < currentBalloonTrack.count else {
            appLog("BalloonTrackService: Historical landing detection skipped - insufficient points after burst (\(currentBalloonTrack.count - burstIndex) points, need \(windowSize + 1))", category: .service, level: .debug)
            return
        }

        let stationaryThreshold = 0.0001 // ~11 meters at equator for lat/lon degrees
        let altitudeThreshold = 0.3 // meters per point
        let gapThreshold: TimeInterval = 20 * 60 // 20 minutes

        appLog("BalloonTrackService: Searching for landing from index \(searchStartIndex) to \(currentBalloonTrack.count)", category: .service, level: .info)

        // SCENARIO 2: Check for telemetry blackout (balloon stops transmitting, then recovered later)
        for i in burstIndex..<currentBalloonTrack.count - 1 {
            let timeDelta = currentBalloonTrack[i + 1].timestamp.timeIntervalSince(currentBalloonTrack[i].timestamp)

            // Blackout (gap > 20min) after burst = landing at last point before blackout
            if timeDelta > gapThreshold {
                let landingPoint = currentBalloonTrack[i]

                historicalLandingDetected = true
                historicalLandingTime = landingPoint.timestamp
                landingPosition = CLLocationCoordinate2D(
                    latitude: landingPoint.latitude,
                    longitude: landingPoint.longitude
                )

                appLog("BalloonTrackService: 🎯 HISTORICAL LANDING DETECTED via telemetry blackout - \(Int(timeDelta/60))min gap at [\(String(format: "%.5f", landingPoint.latitude)), \(String(format: "%.5f", landingPoint.longitude))], alt \(Int(landingPoint.altitude))m, index \(i), timestamp \(landingPoint.timestamp)", category: .service, level: .info)

                // Truncate track at landing - everything after gap is post-recovery transmission
                let originalCount = currentBalloonTrack.count
                currentBalloonTrack = Array(currentBalloonTrack[0...i])
                appLog("BalloonTrackService: Track truncated at blackout landing index \(i) - removed \(originalCount - currentBalloonTrack.count) post-recovery points", category: .service, level: .info)

                trackUpdated.send()
                saveCurrentTrack()
                balloonPositionService.triggerStateEvaluation()
                return
            }
        }

        // SCENARIO 1: Check for stationary period (balloon still transmitting while on ground)
        for i in searchStartIndex..<currentBalloonTrack.count {
            let window = Array(currentBalloonTrack[(i - windowSize)..<i])

            // Calculate moving averages of lat/lon/altitude changes
            var latSum = 0.0
            var lonSum = 0.0
            var altSum = 0.0

            for j in 1..<window.count {
                latSum += abs(window[j].latitude - window[j-1].latitude)
                lonSum += abs(window[j].longitude - window[j-1].longitude)
                altSum += abs(window[j].altitude - window[j-1].altitude)
            }

            let latAvg = latSum / Double(window.count - 1)
            let lonAvg = lonSum / Double(window.count - 1)
            let altAvg = altSum / Double(window.count - 1)

            // All averages small = stationary (horizontal AND vertical) = landed
            if latAvg < stationaryThreshold && lonAvg < stationaryThreshold && altAvg < altitudeThreshold {
                let landingPoint = currentBalloonTrack[i]

                historicalLandingDetected = true
                historicalLandingTime = landingPoint.timestamp
                landingPosition = CLLocationCoordinate2D(
                    latitude: landingPoint.latitude,
                    longitude: landingPoint.longitude
                )

                appLog("BalloonTrackService: 🎯 HISTORICAL LANDING DETECTED via stationary period - at [\(String(format: "%.5f", landingPoint.latitude)), \(String(format: "%.5f", landingPoint.longitude))], alt \(Int(landingPoint.altitude))m, index \(i), timestamp \(landingPoint.timestamp)", category: .service, level: .info)

                // Truncate track at landing point to remove post-recovery movement
                let originalCount = currentBalloonTrack.count
                currentBalloonTrack = Array(currentBalloonTrack[0...i])
                appLog("BalloonTrackService: Track truncated at stationary landing index \(i) - removed \(originalCount - currentBalloonTrack.count) post-landing points", category: .service, level: .info)

                trackUpdated.send()
                saveCurrentTrack()
                balloonPositionService.triggerStateEvaluation()
                return
            }
        }

        appLog("BalloonTrackService: Historical landing detection complete - no stationary period found", category: .service, level: .debug)
    }

    // Exposed helper to mark the balloon as landed at a given coordinate
    func setBalloonAsLanded(at coordinate: CLLocationCoordinate2D) {
        landingPosition = coordinate
        appLog("BalloonTrackService: Balloon manually set as LANDED at \(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))", category: .service, level: .info)
    }

    // MARK: - Smoothing and Staleness Detection (moved from DataPanelView)

    private func updateSmoothedSpeeds() {
        // Implementation moved to motion metrics calculation
    }

    // MARK: - Sonde Change Handling

    func clearState() {
        appLog("BalloonTrackService: clearState() called - clearing \(currentBalloonTrack.count) points", category: .service, level: .info)

        // Reset all state variables
        currentBalloonTrack = []
        currentEffectiveDescentRate = nil
        landingPosition = nil
        historicalLandingDetected = false
        historicalLandingTime = nil
        smoothingCounter = 0
        speedCheckLogCount = 0
        landingLogCount = 0

        // Reset motion metrics
        motionMetrics = BalloonMotionMetrics(
            rawHorizontalSpeedMS: 0,
            rawVerticalSpeedMS: 0,
            smoothedHorizontalSpeedMS: 0,
            smoothedVerticalSpeedMS: 0,
            adjustedDescentRateMS: nil
        )

        // Reset smoothed speeds
        smoothedHorizontalSpeed = 0
        smoothedVerticalSpeed = 0
        adjustedDescentRate = nil
        adjustedDescentHistory = []

        // Reset EMA/smoothing state
        lastEmaTimestamp = nil
        emaHorizontalMS = 0
        emaVerticalMS = 0
        slowEmaHorizontalMS = 0
        slowEmaVerticalMS = 0
        hasEma = false
        hasSlowEma = false

        // Reset Hampel windows
        hWindow = []
        vWindow = []

        // Publish empty track immediately
        trackUpdated.send()

        appLog("BalloonTrackService: State cleared - track now has \(currentBalloonTrack.count) points", category: .service, level: .info)
    }

    func resetForNewSonde() {
        appLog("BalloonTrackService: resetForNewSonde() called - clearing \(currentBalloonTrack.count) points", category: .service, level: .info)

        //Clean up old tracks
        persistenceService.purgeAllTracks()

        // Reset state
        currentBalloonTrack = []
        landingPosition = nil
        historicalLandingDetected = false
        historicalLandingTime = nil
        smoothingCounter = 0

        // Reset EMA/smoothing
        emaHorizontalMS = 0
        emaVerticalMS = 0
        slowEmaHorizontalMS = 0
        slowEmaVerticalMS = 0
        hasEma = false
        hasSlowEma = false

        // Publish empty track immediately
        trackUpdated.send()

        appLog("BalloonTrackService: Reset complete - track now has \(currentBalloonTrack.count) points", category: .service, level: .info)

        // Note: BalloonPositionService processes sonde-change position and publishes it
        // This service receives it via normal currentPositionData subscription and adds to track
    }
}

// MARK: - Landing Point Tracking Service

@MainActor
final class LandingPointTrackingService: ObservableObject {
    @Published private(set) var landingHistory: [LandingPredictionPoint] = []
    @Published private(set) var lastLandingPrediction: LandingPredictionPoint? = nil
    @Published private(set) var currentLandingPoint: CLLocationCoordinate2D? = nil

    private let persistenceService: PersistenceService
    private let balloonTrackService: BalloonTrackService
    private var routeCalculationService: RouteCalculationService?
    private var navigationService: NavigationService?
    private var cancellables = Set<AnyCancellable>()
    private let deduplicationThreshold: CLLocationDistance = 25.0
    private var currentSondeName: String?

    // Store pending route calculation for when sonde name becomes available
    private var pendingLandingPoint: CLLocationCoordinate2D?

    init(persistenceService: PersistenceService, balloonTrackService: BalloonTrackService) {
        self.persistenceService = persistenceService
        self.balloonTrackService = balloonTrackService

        // Note: Sonde change handling now managed by ServiceCoordinator
        // which calls resetForNewSonde() when sonde name changes
    }

    // Set reference to RouteCalculationService for service chain
    func setRouteCalculationService(_ routeCalculationService: RouteCalculationService) {
        self.routeCalculationService = routeCalculationService
        appLog("LandingPointTrackingService: RouteCalculationService configured", category: .service, level: .info)
    }

    // Set reference to NavigationService for landing point change notifications
    func setNavigationService(_ navigationService: NavigationService) {
        self.navigationService = navigationService
        appLog("LandingPointTrackingService: NavigationService configured", category: .service, level: .info)
    }

    // NEW: Unified landing point update method for service chain
    func updateLandingPoint(_ point: CLLocationCoordinate2D, source: LandingPointSource) async {
        guard balloonTrackService.currentBalloonName != nil else {
            appLog("LandingPointTrackingService: No sonde name yet - storing pending landing point for route calculation", category: .service, level: .debug)
            // Store for later when sonde name becomes available
            pendingLandingPoint = point
            return
        }

        // Update current landing point (published for UI and other services)
        currentLandingPoint = point

        // AUTO-CHAIN: Check for significant landing point changes and notify user
        navigationService?.checkForNavigationUpdate(newLandingPoint: point)

        // Handle different sources
        switch source {
        case .prediction:
            // Record as prediction in history
            recordLandingPrediction(coordinate: point, predictedAt: Date(), landingEta: nil, source: .sondehub)
        case .currentPosition:
            // Update as current position (could record differently if needed)
            appLog("LandingPointTrackingService: Landing point updated to current position [\(String(format: "%.4f", point.latitude)), \(String(format: "%.4f", point.longitude))]", category: .service, level: .info)
        }

        // AUTO-CHAIN: Trigger route calculation when landing point changes
        triggerRouteCalculation(to: point)
    }

    private func triggerRouteCalculation(to point: CLLocationCoordinate2D) {
        if let routingService = routeCalculationService {
            appLog("LandingPointTrackingService: Triggering route calculation to [\(String(format: "%.4f", point.latitude)), \(String(format: "%.4f", point.longitude))]", category: .service, level: .info)
            routingService.calculateRoute(to: point)
        } else {
            appLog("LandingPointTrackingService: No RouteCalculationService available for route calculation", category: .service, level: .debug)
        }
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
        currentLandingPoint = nil
    }

    // MARK: - Sonde Change Handling

    func clearState() {
        // Clear all state variables
        landingHistory = []
        lastLandingPrediction = nil
        currentLandingPoint = nil
        currentSondeName = nil
        pendingLandingPoint = nil

        appLog("LandingPointTrackingService: State cleared for new sonde", category: .service, level: .info)
    }

    func resetForNewSonde() {
        // Get the new sonde name from BalloonTrackService
        let newSondeName = balloonTrackService.currentBalloonName

        // Purge ALL landing histories on sonde change (start fresh)
        persistenceService.purgeAllLandingHistories()

        // Update to new sonde
        currentSondeName = newSondeName

        // Clear history (start fresh for new sonde)
        landingHistory = []
        lastLandingPrediction = nil

        // Clear current state (will be repopulated by new predictions)
        currentLandingPoint = nil
        pendingLandingPoint = nil

        // Reset downstream services (service chain pattern)
        routeCalculationService?.resetForNewSonde()
        navigationService?.resetForNewSonde()

        appLog("LandingPointTrackingService: Reset for new sonde", category: .service, level: .info)
    }
}

