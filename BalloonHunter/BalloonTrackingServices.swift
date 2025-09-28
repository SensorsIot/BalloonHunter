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

    // Landing point determination (centralized in state machine)
    @Published var landingPoint: CLLocationCoordinate2D? = nil

    // Display position: shows landing point when landed, live position when flying
    @Published var balloonDisplayPosition: CLLocationCoordinate2D? = nil

    // Cached prediction data for flying state landing point determination

    private var stateEntryTime: Date = Date()
    private var startupTime: Date = Date()
    private var balloonTrackService: BalloonTrackService?
    private var isStartupComplete: Bool = false


    private let bleService: BLECommunicationService
    let aprsService: APRSDataService
    private let currentLocationService: CurrentLocationService
    private let persistenceService: PersistenceService
    private let predictionService: PredictionService
    private let routeCalculationService: RouteCalculationService
    private var landingPointTrackingService: LandingPointTrackingService?
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
                // Only update if we're in APRS mode or no BLE data available
                guard let self = self else { return }
                if self.currentState == .aprsFallbackFlying ||
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

        // Throttle repetitive position processing logs - only log every 10 packets
        processingCount += 1
        if processingCount % 10 == 1 {
            appLog("BalloonPositionService: Processing \(source) position (\(processingCount), every 10th) for \(position.sondeName)", category: .service, level: .info)
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
            let deviceInfo = bleService.connectionStatus == .connected ? "connected" : "disconnected"
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
            // NEW: Trigger PredictionService with BLE balloon position
            if let position = currentPositionData {
                Task {
                    await predictionService.triggerPredictionWithPosition(position, trigger: "state-machine")
                }
            }

        case .liveBLELanded:
            // BLE telemetry active, balloon landed
            aprsService.disablePolling()
            // NEW: Trigger LandingPointTrackingService with current BLE position
            if let position = currentPositionData,
               position.latitude != 0.0, position.longitude != 0.0 {
                let currentPosition = CLLocationCoordinate2D(
                    latitude: position.latitude,
                    longitude: position.longitude
                )
                Task {
                    await landingPointTrackingService?.updateLandingPoint(currentPosition, source: .currentPosition)
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
            // NEW: Trigger PredictionService with APRS balloon position
            if let position = currentPositionData {
                Task {
                    await predictionService.triggerPredictionWithPosition(position, trigger: "state-machine")
                }
            }

        case .aprsFallbackLanded:
            // APRS fallback with old/stale data indicating landing
            aprsService.enablePolling()
            // NEW: Trigger LandingPointTrackingService with current APRS position
            if let position = currentPositionData,
               position.telemetrySource == .aprs,
               position.latitude != 0.0, position.longitude != 0.0 {
                let currentPosition = CLLocationCoordinate2D(
                    latitude: position.latitude,
                    longitude: position.longitude
                )
                Task {
                    await landingPointTrackingService?.updateLandingPoint(currentPosition, source: .currentPosition)
                }
            }
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

        // Check for old APRS data (age-based landing)
        let positionAge = Date().timeIntervalSince(currentPosition.timestamp)
        let isAprsPosition = currentPosition.telemetrySource == .aprs
        let aprsLandingAgeThreshold = 120.0 // 2 minutes

        if isAprsPosition && positionAge > aprsLandingAgeThreshold {
            balloonPhase = .landed
            appLog("BalloonPositionService: APRS age-based landing detected - balloon marked as LANDED", category: .service, level: .info)
            return
        }

        // BLE landing detection with 5-packet requirement
        let landingDetected = calculateLandingDetection()

        if landingDetected {
            balloonPhase = .landed
        } else {
            // Determine flight phase based on vertical speed
            if currentPosition.verticalSpeed >= 0 {
                balloonPhase = .ascending
            } else {
                balloonPhase = currentPosition.altitude < 10_000 ? .descendingBelow10k : .descendingAbove10k
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
        } else if let position = currentPositionData {
            let livePosition = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
            balloonDisplayPosition = livePosition
            currentLocationService.updateBalloonDisplayPosition(livePosition)
        }
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
    
    // Smoothed telemetry data (moved from DataPanelView for proper separation of concerns)
    var smoothedHorizontalSpeed: Double = 0
    var smoothedVerticalSpeed: Double = 0
    var adjustedDescentRate: Double? = nil

    
    private let persistenceService: PersistenceService
    let balloonPositionService: BalloonPositionService
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
        cleanupPersistedTracks()
        setupSubscriptions()
        loadPersistedDataAtStartup()
    }

    /// Clean up persisted tracks by removing invalid coordinate points (0,0)
    private func cleanupPersistedTracks() {
        let allTracks = persistenceService.getAllTracks()
        var cleanedCount = 0
        var totalOriginalPoints = 0
        var totalValidPoints = 0

        for (sondeName, trackData) in allTracks {
            let originalCount = trackData.count
            totalOriginalPoints += originalCount

            // Filter out invalid coordinates (0,0) and empty/nil values
            let validTrackData = trackData.filter { point in
                return point.latitude != 0.0 &&
                       point.longitude != 0.0 &&
                       abs(point.latitude) <= 90.0 &&
                       abs(point.longitude) <= 180.0
            }

            let validCount = validTrackData.count
            totalValidPoints += validCount

            if validCount != originalCount {
                // Save cleaned track data back to persistence
                persistenceService.saveBalloonTrack(sondeName: sondeName, track: validTrackData)
                cleanedCount += 1
                appLog("BalloonTrackService: Cleaned track '\(sondeName)' - removed \(originalCount - validCount) invalid points (\(validCount)/\(originalCount) valid)", category: .service, level: .info)
            }
        }

        if cleanedCount > 0 {
            appLog("BalloonTrackService: Startup cleanup completed - cleaned \(cleanedCount) tracks, removed \(totalOriginalPoints - totalValidPoints) invalid points", category: .service, level: .info)
        } else {
            appLog("BalloonTrackService: Startup cleanup completed - all persisted tracks valid", category: .service, level: .debug)
        }
    }

    /// Load any persisted balloon data at startup
    private func loadPersistedDataAtStartup() {
        // Try to load any existing track data from persistence
        // Note: We don't know the sonde name yet, so we can't load specific tracks
        // But we can prepare the service for when telemetry arrives
        appLog("BalloonTrackService: Ready to load persisted data on first telemetry", category: .service, level: .info)
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
        let incomingName = positionData.sondeName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Always extract sonde name, even during startup (needed for service chain)
        if !incomingName.isEmpty && currentBalloonName == nil {
            currentBalloonName = incomingName
            appLog("BalloonTrackService: Sonde name extracted during startup: \(incomingName)", category: .service, level: .info)
        }

        // Only record track points when we have valid telemetry states (not startup, waitingForAPRS, or noTelemetry)
        let state = balloonPositionService.currentState
        guard state != .startup && state != .waitingForAPRS && state != .noTelemetry else {
            appLog("BalloonTrackService: State \(state) - not recording track point", category: .service, level: .info)
            return
        }

        if !incomingName.isEmpty,
           incomingName != currentBalloonName {
            appLog("BalloonTrackService: New sonde detected - \(incomingName), switching from \(currentBalloonName ?? "none")", category: .service, level: .info)

            // Load persisted track for this sonde if available
            let persistedTrack = persistenceService.loadTrackForCurrentSonde(sondeName: incomingName)
            if let track = persistedTrack {
                self.currentBalloonTrack = track
                appLog("BalloonTrackService: Loaded persisted track for \(incomingName) with \(self.currentBalloonTrack.count) points", category: .service, level: .info)
            } else {
                self.currentBalloonTrack = []
                appLog("BalloonTrackService: No persisted track found - starting fresh track for \(incomingName)", category: .service, level: .info)
            }
            self.landingPosition = nil

            // Clean up old tracks if switching sondes
            if let currentName = currentBalloonName,
               currentName != incomingName {
                appLog("BalloonTrackService: Switching from different sonde (\(currentName)) - purging old tracks", category: .service, level: .info)
                persistenceService.purgeAllTracks()
            }

            smoothingCounter = 0
            currentBalloonName = incomingName
            emaHorizontalMS = 0
            emaVerticalMS = 0
            slowEmaHorizontalMS = 0
            slowEmaVerticalMS = 0
            hasEma = false
            hasSlowEma = false
        } else if currentBalloonName == nil {
            currentBalloonName = incomingName
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

    // Exposed helper to mark the balloon as landed at a given coordinate
    func setBalloonAsLanded(at coordinate: CLLocationCoordinate2D) {
        landingPosition = coordinate
        appLog("BalloonTrackService: Balloon manually set as LANDED at \(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))", category: .service, level: .info)
    }

    // MARK: - Smoothing and Staleness Detection (moved from DataPanelView)

    private func updateSmoothedSpeeds() {
        // Implementation moved to motion metrics calculation
    }
}

// MARK: - Landing Point Tracking Service

@MainActor
final class LandingPointTrackingService: ObservableObject {
    @Published private(set) var landingHistory: [LandingPredictionPoint] = []
    @Published private(set) var lastLandingPrediction: LandingPredictionPoint? = nil

    private let persistenceService: PersistenceService
    private let balloonTrackService: BalloonTrackService
    private var routeCalculationService: RouteCalculationService?
    private var cancellables = Set<AnyCancellable>()
    private let deduplicationThreshold: CLLocationDistance = 25.0
    private var currentSondeName: String?

    // Store pending route calculation for when sonde name becomes available
    private var pendingLandingPoint: CLLocationCoordinate2D?

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

    // Set reference to RouteCalculationService for service chain
    func setRouteCalculationService(_ routeCalculationService: RouteCalculationService) {
        self.routeCalculationService = routeCalculationService
        appLog("LandingPointTrackingService: RouteCalculationService configured", category: .service, level: .info)
    }

    // NEW: Unified landing point update method for service chain
    func updateLandingPoint(_ point: CLLocationCoordinate2D, source: LandingPointSource) async {
        guard balloonTrackService.currentBalloonName != nil else {
            appLog("LandingPointTrackingService: No sonde name yet - storing pending landing point for route calculation", category: .service, level: .debug)
            // Store for later when sonde name becomes available
            pendingLandingPoint = point
            return
        }

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

        // Process pending landing point if we have one
        if let pending = pendingLandingPoint, newName != nil {
            appLog("LandingPointTrackingService: Sonde name available - processing pending landing point for route calculation", category: .service, level: .info)
            pendingLandingPoint = nil
            triggerRouteCalculation(to: pending)
        }
    }
}

