import Foundation
import Combine
import CoreLocation
import MapKit
import OSLog

// MARK: - Telemetry State Machine Types

enum TelemetryState: CustomStringConvertible, Equatable {
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

    var shouldEnableAPRS: Bool {
        switch self {
        case .startup, .noTelemetry, .liveBLEFlying, .liveBLELanded:
            return false
        case .waitingForAPRS, .aprsFallbackFlying, .aprsFallbackLanded:
            return true
        }
    }
}

struct TelemetryInputs {
    let bleTelemetryState: BLETelemetryState
    let aprsTelemetryIsAvailable: Bool
    let balloonPhase: BalloonPhase
}

// MARK: - Balloon Position Service

@MainActor
final class BalloonPositionService: ObservableObject {
    // Current position and telemetry data
    var currentPosition: CLLocationCoordinate2D?
    @Published var currentTelemetry: TelemetryData?
    var currentAltitude: Double?
    var currentVerticalSpeed: Double?
    @Published var currentBalloonName: String?
    @Published var lastTelemetrySource: TelemetrySource = .ble
    
    // Derived position data
    var distanceToUser: Double?
    private var timeSinceLastUpdate: TimeInterval = 0
    var hasReceivedTelemetry: Bool = false
    @Published var burstKillerCountdown: Int? = nil
    @Published var burstKillerReferenceDate: Date? = nil
    @Published var isTelemetryStale: Bool = false
    @Published var aprsTelemetryIsAvailable: Bool = false

    // State machine
    @Published var currentTelemetryState: TelemetryState = .startup

    // Balloon flight state (moved from BalloonTrackService)
    @Published var balloonPhase: BalloonPhase = .unknown
    private var stateEntryTime: Date = Date()
    private var startupTime: Date = Date()
    private var balloonTrackService: BalloonTrackService?
    private var isStartupComplete: Bool = false

    // State-specific published properties for other services
    @Published var shouldEnablePredictions: Bool = false
    @Published var shouldEnableLandingDetection: Bool = false
    @Published var isInAPRSFallbackMode: Bool = false

    private let bleService: BLECommunicationService
    let aprsService: APRSTelemetryService
    private let currentLocationService: CurrentLocationService
    private let persistenceService: PersistenceService
    private var currentUserLocation: LocationData?
    private var lastTelemetryTime: Date?
    private var lastLoggedBurstKillerTime: Int?
    private var processingCount: Int = 0
    private var landingLogCount: Int = 0
    private var speedCheckLogCount: Int = 0
    private var cancellables = Set<AnyCancellable>()
    private let bleStalenessThreshold: TimeInterval = 3.0 // 3 seconds for BLE
    private let aprsStalenessThreshold: TimeInterval = 30.0 // 30 seconds for APRS

    
    init(bleService: BLECommunicationService,
         aprsService: APRSTelemetryService,
         currentLocationService: CurrentLocationService,
         persistenceService: PersistenceService) {
        self.bleService = bleService
        self.aprsService = aprsService
        self.currentLocationService = currentLocationService
        self.persistenceService = persistenceService
        setupSubscriptions()
        // BalloonPositionService initialized
    }

    // Set reference to BalloonTrackService for landing detection
    func setBalloonTrackService(_ balloonTrackService: BalloonTrackService) {
        self.balloonTrackService = balloonTrackService

        // Trigger initial state evaluation
        evaluateTelemetryState()
    }
    
    private func setupSubscriptions() {
        // Subscribe to BLE service telemetry stream (primary source)
        bleService.telemetryData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] telemetry in
                self?.handleTelemetryUpdate(telemetry, source: "BLE")
            }
            .store(in: &cancellables)

        // Subscribe to APRS service telemetry stream (fallback source)
        aprsService.telemetryData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] telemetry in
                self?.handleTelemetryUpdate(telemetry, source: "APRS")
            }
            .store(in: &cancellables)

        // Monitor BLE telemetry state for state machine evaluation
        bleService.$telemetryState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateTelemetryState()
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
    
    private func handleTelemetryUpdate(_ telemetry: TelemetryData, source: String) {
        // Debug: Always log when APRS telemetry arrives
        if source == "APRS" {
            appLog("BalloonPositionService: APRS telemetry received for \(telemetry.sondeName) - BLE available: \(bleService.telemetryState.hasTelemetry)", category: .service, level: .info)
        }

        // Only process APRS telemetry when BLE telemetry is not available (arbitration)
        if source == "APRS" && bleService.telemetryState.hasTelemetry {
            appLog("BalloonPositionService: APRS telemetry received but BLE telemetry is available - ignoring", category: .service, level: .debug)
            return
        }

        let now = Date()

        // Throttle repetitive telemetry processing logs - only log every 10 packets
        processingCount += 1
        if processingCount % 10 == 1 {
            appLog("BalloonPositionService: Processing \(source) telemetry (\(processingCount), every 10th) for \(telemetry.sondeName)", category: .service, level: .info)
        }
        if telemetry.burstKillerTime > 0 && lastLoggedBurstKillerTime != telemetry.burstKillerTime {
            appLog("BalloonPositionService: burstKillerTime received = \(telemetry.burstKillerTime)", category: .service, level: .debug)
            lastLoggedBurstKillerTime = telemetry.burstKillerTime
        }

        var telemetryToStore = telemetry

        if source == "BLE" {
            let countdown = telemetry.burstKillerTime
            if countdown > 0 {
                burstKillerCountdown = countdown
                burstKillerReferenceDate = telemetry.timestamp
                persistenceService.updateBurstKillerTime(for: telemetry.sondeName,
                                                         time: countdown,
                                                         referenceDate: telemetry.timestamp)
            } else if countdown == 0 {
                burstKillerCountdown = nil
                burstKillerReferenceDate = nil
            }
        } else {
            if let record = persistenceService.loadBurstKillerRecord(for: telemetry.sondeName) {
                burstKillerCountdown = record.seconds
                burstKillerReferenceDate = record.referenceDate
                telemetryToStore.burstKillerTime = record.seconds
            } else {
                burstKillerCountdown = nil
                burstKillerReferenceDate = nil
            }
        }

        currentTelemetry = telemetryToStore

        // Update balloon phase based on new telemetry
        updateBalloonPhase()

        // Trigger startup frequency sync if needed
        triggerStartupFrequencySyncIfNeeded()

        // Update current state
        currentPosition = CLLocationCoordinate2D(latitude: telemetryToStore.latitude,
                                                 longitude: telemetryToStore.longitude)
        currentAltitude = telemetryToStore.altitude
        currentVerticalSpeed = telemetryToStore.verticalSpeed
        currentBalloonName = telemetryToStore.sondeName
        hasReceivedTelemetry = true
        lastTelemetryTime = now
        if source == "APRS" {
            aprsTelemetryIsAvailable = true
        }
        // Note: bleTelemetryIsAvailable is now managed via BLE service telemetryState subscription

        lastTelemetrySource = (source == "APRS") ? .aprs : .ble

        // Trigger state machine evaluation when telemetry source changes
        evaluateTelemetryState()

        // Update APRS service with BLE sonde name for mismatch detection
        if source == "BLE" {
            aprsService.updateBLESondeName(telemetry.sondeName)
        }

        // Update distance to user if location available
        updateDistanceToUser()

        // Frequency sync when APRS messages arrive during fallback scenarios
        if source == "APRS" && (currentTelemetryState == .aprsFallbackFlying || currentTelemetryState == .aprsFallbackLanded) {
            performRegularAPRSFrequencySync()
        }

        // Position and telemetry are now available through @Published properties
        // Suppress verbose position update log in debug output
    }

    // handleBLETelemetryAvailabilityChange removed - state machine handles this automatically
    
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
            // Don't mark as stale if we never had telemetry - only when existing telemetry ages out
            isTelemetryStale = false
            return
        }
        timeSinceLastUpdate = Date().timeIntervalSince(lastUpdate)

        // Use different staleness thresholds based on telemetry source
        let threshold = (lastTelemetrySource == .aprs) ? aprsStalenessThreshold : bleStalenessThreshold
        isTelemetryStale = timeSinceLastUpdate > threshold

        // Note: bleTelemetryIsAvailable staleness is now managed by BLE service directly
    }

    // MARK: - Telemetry State Machine

    private func evaluateTelemetryState() {
        let inputs = TelemetryInputs(
            bleTelemetryState: bleService.telemetryState,
            aprsTelemetryIsAvailable: aprsTelemetryIsAvailable,
            balloonPhase: balloonPhase
        )

        let newState = determineNextState(inputs: inputs)

        if newState != currentTelemetryState {
            let timeInState = Date().timeIntervalSince(stateEntryTime)
            appLog("TelemetryState: \(currentTelemetryState) → \(newState) | BLE:\(inputs.bleTelemetryState) APRS:\(inputs.aprsTelemetryIsAvailable) Phase:\(inputs.balloonPhase) Time:\(String(format: "%.1f", timeInState))s", category: .service, level: .info)
            transition(to: newState)
        }

    }

    private func determineNextState(inputs: TelemetryInputs) -> TelemetryState {
        let timeInCurrentState = Date().timeIntervalSince(stateEntryTime)

        switch currentTelemetryState {
        case .startup:
            return evaluateStartupTransitions(inputs: inputs)

        case .liveBLEFlying:
            return evaluateLiveBLEFlyingTransitions(inputs: inputs)

        case .liveBLELanded:
            return evaluateLiveBLELandedTransitions(inputs: inputs)

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

    private func transition(to newState: TelemetryState) {
        currentTelemetryState = newState
        stateEntryTime = Date()
        handleStateTransition(to: newState)
    }

    private func handleStateTransition(to state: TelemetryState) {
        switch state {
        case .startup:
            // Startup state - no telemetry operations yet
            aprsService.disablePolling()

        case .noTelemetry:
            // No telemetry sources available - disable all polling
            aprsService.disablePolling()

        case .liveBLEFlying:
            // BLE telemetry active, balloon flying
            aprsService.disablePolling()
            // BLE telemetry is source of truth - no frequency sync needed

        case .liveBLELanded:
            // BLE telemetry active, balloon landed
            aprsService.disablePolling()
            // Landed state - predictions should stop, landing point is live position

        case .waitingForAPRS:
            // BLE lost - start APRS polling and wait for response
            aprsService.enablePolling()
            appLog("BalloonPositionService: Starting APRS polling - waiting for telemetry response", category: .service, level: .info)

        case .aprsFallbackFlying:
            // APRS fallback while flying - enable polling and frequency monitoring
            aprsService.enablePolling()
            // Frequency sync happens when APRS messages arrive

        case .aprsFallbackLanded:
            // APRS fallback with old/stale data indicating landing
            aprsService.enablePolling()
            // Predictions should stop, use APRS position as landing point
            // Frequency sync happens when APRS messages arrive
        }

        // Update staleness thresholds based on expected telemetry source
        updateStalenessThresholds(for: state)

        // Notify other services of state-specific behavior changes
        notifyStateSpecificBehavior(state)
    }

    private func updateStalenessThresholds(for state: TelemetryState) {
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

    private func notifyStateSpecificBehavior(_ state: TelemetryState) {
        // Update published properties for other services to observe
        switch state {
        case .startup, .noTelemetry:
            // No predictions, no landing detection
            shouldEnablePredictions = false
            shouldEnableLandingDetection = false
            isInAPRSFallbackMode = false

        case .liveBLEFlying:
            // BLE flying - enable all tracking functionality
            shouldEnablePredictions = true
            shouldEnableLandingDetection = true
            isInAPRSFallbackMode = false

        case .liveBLELanded:
            // BLE landed - disable predictions, use live position as landing point
            shouldEnablePredictions = false
            shouldEnableLandingDetection = false
            isInAPRSFallbackMode = false

        case .waitingForAPRS:
            // Waiting for APRS response - keep previous functionality disabled
            shouldEnablePredictions = false
            shouldEnableLandingDetection = false
            isInAPRSFallbackMode = false

        case .aprsFallbackFlying:
            // APRS flying - enable predictions but more cautious landing detection
            shouldEnablePredictions = true
            shouldEnableLandingDetection = true
            isInAPRSFallbackMode = true

        case .aprsFallbackLanded:
            // APRS landed - disable predictions, use APRS position as landing point
            shouldEnablePredictions = false
            shouldEnableLandingDetection = false
            isInAPRSFallbackMode = true
        }

        appLog("BalloonPositionService: State behavior - Predictions:\(shouldEnablePredictions) LandingDetection:\(shouldEnableLandingDetection) APRSMode:\(isInAPRSFallbackMode)", category: .service, level: .debug)
    }

    // MARK: - State Transition Evaluators

    private func evaluateStartupTransitions(inputs: TelemetryInputs) -> TelemetryState {
        // Stay in startup until startup sequence is complete
        guard isStartupComplete else {
            return .startup
        }

        // After startup completion, evaluate based on available telemetry sources
        if inputs.bleTelemetryState.hasTelemetry && inputs.balloonPhase == .landed {
            return .liveBLELanded
        }
        if inputs.bleTelemetryState.hasTelemetry {
            return .liveBLEFlying
        }
        if inputs.aprsTelemetryIsAvailable && inputs.balloonPhase == .landed {
            return .aprsFallbackLanded
        }
        if inputs.aprsTelemetryIsAvailable {
            return .aprsFallbackFlying
        }

        // Check if APRS priming was successful during startup
        if aprsService.aprsSerialName != nil {
            // APRS data available from priming - start fallback polling
            return inputs.balloonPhase == .landed ? .aprsFallbackLanded : .aprsFallbackFlying
        }

        return .noTelemetry
    }

    private func evaluateLiveBLEFlyingTransitions(inputs: TelemetryInputs) -> TelemetryState {
        if inputs.balloonPhase == .landed {
            return .liveBLELanded
        }
        if !inputs.bleTelemetryState.hasTelemetry {
            // BLE lost - start APRS and wait for response
            appLog("BalloonPositionService: BLE lost while flying - starting APRS and waiting for response", category: .service, level: .info)
            return .waitingForAPRS
        }
        return .liveBLEFlying
    }

    private func evaluateLiveBLELandedTransitions(inputs: TelemetryInputs) -> TelemetryState {
        if inputs.balloonPhase != .landed {
            return .liveBLEFlying
        }
        if !inputs.bleTelemetryState.hasTelemetry {
            // BLE lost - start APRS and wait for response
            appLog("BalloonPositionService: BLE lost while landed - starting APRS and waiting for response", category: .service, level: .info)
            return .waitingForAPRS
        }
        return .liveBLELanded
    }

    private func evaluateWaitingForAPRSTransitions(inputs: TelemetryInputs, timeInState: TimeInterval) -> TelemetryState {
        // BLE recovery takes priority
        if inputs.bleTelemetryState.hasTelemetry {
            appLog("BalloonPositionService: BLE recovered while waiting for APRS", category: .service, level: .info)
            return inputs.balloonPhase == .landed ? .liveBLELanded : .liveBLEFlying
        }

        // APRS data arrived - transition to appropriate APRS fallback state
        if inputs.aprsTelemetryIsAvailable {
            appLog("BalloonPositionService: APRS data received - transitioning to APRS fallback", category: .service, level: .info)
            return inputs.balloonPhase == .landed ? .aprsFallbackLanded : .aprsFallbackFlying
        }

        // Timeout after 30 seconds of waiting for APRS
        if timeInState > 30.0 {
            appLog("BalloonPositionService: APRS timeout after 30s - no telemetry available", category: .service, level: .error)
            return .noTelemetry
        }

        // Stay in waiting state
        return .waitingForAPRS
    }

    private func evaluateAPRSFallbackFlyingTransitions(inputs: TelemetryInputs, timeInState: TimeInterval) -> TelemetryState {
        if inputs.bleTelemetryState.hasTelemetry && timeInState >= 30.0 {
            return .liveBLEFlying
        }
        if inputs.balloonPhase == .landed {
            return .aprsFallbackLanded
        }
        if !inputs.aprsTelemetryIsAvailable {
            return .noTelemetry
        }
        return .aprsFallbackFlying
    }

    private func evaluateAPRSFallbackLandedTransitions(inputs: TelemetryInputs, timeInState: TimeInterval) -> TelemetryState {
        if inputs.bleTelemetryState.hasTelemetry && timeInState >= 30.0 {
            return inputs.balloonPhase == .landed ? .liveBLELanded : .liveBLEFlying
        }
        if inputs.balloonPhase != .landed {
            return .aprsFallbackFlying
        }
        if !inputs.aprsTelemetryIsAvailable {
            return .noTelemetry
        }
        return .aprsFallbackLanded
    }

    private func evaluateNoTelemetryTransitions(inputs: TelemetryInputs) -> TelemetryState {
        if inputs.bleTelemetryState.hasTelemetry && inputs.balloonPhase == .landed {
            return .liveBLELanded
        }
        if inputs.bleTelemetryState.hasTelemetry {
            return .liveBLEFlying
        }
        if inputs.aprsTelemetryIsAvailable && inputs.balloonPhase == .landed {
            return .aprsFallbackLanded
        }
        if inputs.aprsTelemetryIsAvailable {
            return .aprsFallbackFlying
        }
        return .noTelemetry
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

    /// Trigger state evaluation after APRS priming (called by ServiceCoordinator)
    func triggerStateEvaluation() {
        evaluateTelemetryState()
    }

    /// Mark startup sequence as complete and trigger final state evaluation
    func completeStartup() {
        isStartupComplete = true
        appLog("BalloonPositionService: Startup marked as complete - evaluating final state", category: .service, level: .info)
        evaluateTelemetryState()
    }

    /// Trigger automatic frequency sync during startup when APRS telemetry first becomes available
    private func triggerStartupFrequencySyncIfNeeded() {
        // Only during startup or shortly after
        guard !isStartupComplete || Date().timeIntervalSince(startupTime) < 10 else { return }

        // Only for APRS telemetry
        guard let telemetry = currentTelemetry,
              telemetry.softwareVersion == "APRS" else { return }

        // Check if BLE is ready for commands
        guard bleService.telemetryState.canReceiveCommands else { return }

        // Check if frequency sync is needed
        let aprsFreq = telemetry.frequency
        let bleFreq = bleService.deviceSettings.frequency
        let freqMismatch = abs(aprsFreq - bleFreq) > 0.01 // 0.01 MHz tolerance

        guard freqMismatch, aprsFreq > 0 else {
            appLog("BalloonPositionService: Frequencies already match, no startup sync needed", category: .service, level: .info)
            return
        }

        appLog("BalloonPositionService: Performing startup frequency sync from \(String(format: "%.2f", bleFreq)) MHz to \(String(format: "%.2f", aprsFreq)) MHz", category: .service, level: .info)

        // Perform automatic sync during startup (no user prompt needed)
        let probeType = BLECommunicationService.ProbeType.from(string: telemetry.probeType.isEmpty ? "RS41" : telemetry.probeType) ?? .rs41
        bleService.setFrequency(aprsFreq, probeType: probeType)

        // Note: Display will update when RadioSondyGo confirms the new frequency via BLE device settings

        appLog("BalloonPositionService: Startup frequency sync complete", category: .service, level: .info)
    }

    /// Regular frequency sync during APRS fallback scenarios
    /// If RadioSondyGo is connected (readyForCommands), regularly check and sync frequency/sonde type
    private func performRegularAPRSFrequencySync() {
        // Only perform sync when we have APRS telemetry
        guard let telemetry = currentTelemetry,
              telemetry.softwareVersion == "APRS" else { return }

        // Only sync if RadioSondyGo is connected and ready for commands
        guard bleService.telemetryState.canReceiveCommands else { return }

        // Check if frequency sync is needed
        let aprsFreq = telemetry.frequency
        let bleFreq = bleService.deviceSettings.frequency
        let freqMismatch = abs(aprsFreq - bleFreq) > 0.01 // 0.01 MHz tolerance

        // Check if probe type sync is needed
        let aprsProbeType = telemetry.probeType.isEmpty ? "RS41" : telemetry.probeType
        let bleProbeType = bleService.deviceSettings.probeType
        let probeTypeMismatch = aprsProbeType != bleProbeType

        guard (freqMismatch && aprsFreq > 0) || probeTypeMismatch else {
            return // No sync needed
        }

        appLog("BalloonPositionService: APRS fallback frequency sync needed - Freq: \(String(format: "%.2f", bleFreq)) → \(String(format: "%.2f", aprsFreq)) MHz, Probe: '\(bleProbeType)' → '\(aprsProbeType)'", category: .service, level: .info)

        // Perform sync
        let probeType = BLECommunicationService.ProbeType.from(string: aprsProbeType) ?? .rs41
        bleService.setFrequency(aprsFreq, probeType: probeType)

        appLog("BalloonPositionService: APRS fallback frequency sync command sent", category: .service, level: .info)
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

        // Comprehensive single-line logging with all parameters
        appLog(String(format: "🎯 LANDING [%d]: %.1fm @%.1fkm/h alt=%.0fm win=%.1fs spd<%.1f alt<%.0f → %@",
                      windowSize, netDistance, netSpeedKmh, endPoint.altitude, timeWindow,
                      landingThresholdKmh, altitudeThresholdM,
                      isLanded ? "LANDED" : "FLYING"),
               category: .general, level: .debug)

        return isLanded
    }

    /// Update balloon phase based on telemetry and landing detection
    private func updateBalloonPhase() {
        guard let currentTelemetry = currentTelemetry else {
            balloonPhase = .unknown
            return
        }

        // Check for old APRS data (age-based landing)
        let telemetryAge = Date().timeIntervalSince(currentTelemetry.timestamp)
        let isAprsTelemetry = currentTelemetry.softwareVersion == "APRS"
        let aprsLandingAgeThreshold = 120.0 // 2 minutes

        if isAprsTelemetry && telemetryAge > aprsLandingAgeThreshold {
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
            if currentTelemetry.verticalSpeed >= 0 {
                balloonPhase = .ascending
            } else {
                balloonPhase = currentTelemetry.altitude < 10_000 ? .descendingBelow10k : .descendingAbove10k
            }
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
    private var telemetryPointCounter = 0
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
        let incomingName = telemetryData.sondeName.trimmingCharacters(in: .whitespacesAndNewlines)

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

            telemetryPointCounter = 0
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
                if abs(hDiff) > 30.0 || abs(vDiff) > 2.0 {
                    // Log immediately when significant speed discrepancy detected
                    speedCheckLogCount += 1
                    appLog(String(format: "⚠️ Speed anomaly (\(speedCheckLogCount)): track h=%.1f v=%.1f vs tele h=%.1f v=%.1f (diff: h=%.1f v=%.1f)", (derivedHorizontalMS ?? 0)*3.6, (derivedVerticalMS ?? 0), hTele*3.6, vTele, hDiff, vDiff), category: .service, level: .info)
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

        // Landing detection now handled by BalloonPositionService

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
        let telemetryAge = Date().timeIntervalSince(telemetryData.timestamp)
        let isAprsTelemetry = telemetryData.softwareVersion == "APRS"

        // Debug APRS landing detection
        if isAprsTelemetry {
            appLog("BalloonTrackService: APRS landing check - age=\(Int(telemetryAge))s, threshold=\(Int(aprsLandingAgeThreshold))s, willLand=\(telemetryAge > aprsLandingAgeThreshold)", category: .service, level: .info)
        }

        if isAprsTelemetry && telemetryAge > aprsLandingAgeThreshold {
            let aprsCoordinate = CLLocationCoordinate2D(latitude: telemetryData.latitude, longitude: telemetryData.longitude)
            if landingPosition == nil {
                landingPosition = aprsCoordinate
            }
            appLog("BalloonTrackService: APRS age-based landing detected - balloon marked as LANDED at [\(String(format: "%.4f", aprsCoordinate.latitude)), \(String(format: "%.4f", aprsCoordinate.longitude))]", category: .service, level: .info)
        }


        publishMotionMetrics(rawHorizontal: telemetryData.horizontalSpeed,
                              rawVertical: telemetryData.verticalSpeed)

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
