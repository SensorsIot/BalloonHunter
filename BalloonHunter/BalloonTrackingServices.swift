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
    case aprsFallbackFlying
    case aprsFallbackLanded
    case noTelemetry

    var description: String {
        switch self {
        case .startup: return "startup"
        case .liveBLEFlying: return "liveBLEFlying"
        case .liveBLELanded: return "liveBLELanded"
        case .aprsFallbackFlying: return "aprsFallbackFlying"
        case .aprsFallbackLanded: return "aprsFallbackLanded"
        case .noTelemetry: return "noTelemetry"
        }
    }

    var shouldEnableAPRS: Bool {
        switch self {
        case .startup, .noTelemetry, .liveBLEFlying, .liveBLELanded:
            return false
        case .aprsFallbackFlying, .aprsFallbackLanded:
            return true
        }
    }
}

struct TelemetryInputs {
    let bleTelemetryIsAvailable: Bool
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
    @Published var bleTelemetryIsAvailable: Bool = false
    @Published var aprsTelemetryIsAvailable: Bool = false

    // State machine
    @Published var currentTelemetryState: TelemetryState = .startup
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

    // Set reference to BalloonTrackService for balloon phase access
    func setBalloonTrackService(_ balloonTrackService: BalloonTrackService) {
        self.balloonTrackService = balloonTrackService

        // Subscribe to balloon phase changes to trigger state evaluation
        balloonTrackService.$balloonPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateTelemetryState()
            }
            .store(in: &cancellables)

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

        // Monitor BLE telemetry availability for state machine evaluation
        $bleTelemetryIsAvailable
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
        // Only process APRS telemetry when BLE telemetry is not available (arbitration)
        if source == "APRS" && bleTelemetryIsAvailable {
            appLog("BalloonPositionService: APRS telemetry received but BLE telemetry is available - ignoring", category: .service, level: .debug)
            return
        }

        let now = Date()

        appLog("BalloonPositionService: Processing \(source) telemetry for sonde \(telemetry.sondeName)", category: .service, level: .info)
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
        if source == "BLE" {
            bleTelemetryIsAvailable = true
        } else if source == "APRS" {
            aprsTelemetryIsAvailable = true
        }

        lastTelemetrySource = (source == "APRS") ? .aprs : .ble

        // Trigger state machine evaluation when telemetry source changes
        evaluateTelemetryState()

        // Update APRS service with BLE sonde name for mismatch detection
        if source == "BLE" {
            aprsService.updateBLESondeName(telemetry.sondeName)
        }

        // Update distance to user if location available
        updateDistanceToUser()

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

        if isTelemetryStale {
            bleTelemetryIsAvailable = false
        }
    }

    // MARK: - Telemetry State Machine

    private func evaluateTelemetryState() {
        guard let balloonTrackService = balloonTrackService else { return }

        let inputs = TelemetryInputs(
            bleTelemetryIsAvailable: bleTelemetryIsAvailable,
            aprsTelemetryIsAvailable: aprsTelemetryIsAvailable,
            balloonPhase: balloonTrackService.balloonPhase
        )

        let newState = determineNextState(inputs: inputs)

        if newState != currentTelemetryState {
            let timeInState = Date().timeIntervalSince(stateEntryTime)
            appLog("TelemetryState: \(currentTelemetryState) → \(newState) | BLE:\(inputs.bleTelemetryIsAvailable) APRS:\(inputs.aprsTelemetryIsAvailable) Phase:\(inputs.balloonPhase) Time:\(String(format: "%.1f", timeInState))s", category: .service, level: .info)
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

        case .aprsFallbackFlying:
            // APRS fallback while flying - enable polling and frequency monitoring
            aprsService.enablePolling()
            // Monitor for frequency mismatches between APRS and BLE device settings

        case .aprsFallbackLanded:
            // APRS fallback with old/stale data indicating landing
            aprsService.enablePolling()
            // Predictions should stop, use APRS position as landing point
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
        if inputs.bleTelemetryIsAvailable && inputs.balloonPhase == .landed {
            return .liveBLELanded
        }
        if inputs.bleTelemetryIsAvailable {
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
        if !inputs.bleTelemetryIsAvailable && inputs.aprsTelemetryIsAvailable && inputs.balloonPhase == .landed {
            return .aprsFallbackLanded
        }
        if !inputs.bleTelemetryIsAvailable && inputs.aprsTelemetryIsAvailable {
            return .aprsFallbackFlying
        }
        if !inputs.bleTelemetryIsAvailable {
            return .noTelemetry
        }
        return .liveBLEFlying
    }

    private func evaluateLiveBLELandedTransitions(inputs: TelemetryInputs) -> TelemetryState {
        if inputs.balloonPhase != .landed {
            return .liveBLEFlying
        }
        if !inputs.bleTelemetryIsAvailable {
            return .noTelemetry // No APRS for landed balloons
        }
        return .liveBLELanded
    }

    private func evaluateAPRSFallbackFlyingTransitions(inputs: TelemetryInputs, timeInState: TimeInterval) -> TelemetryState {
        if inputs.bleTelemetryIsAvailable && timeInState >= 30.0 {
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
        if inputs.bleTelemetryIsAvailable && timeInState >= 30.0 {
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
        if inputs.bleTelemetryIsAvailable && inputs.balloonPhase == .landed {
            return .liveBLELanded
        }
        if inputs.bleTelemetryIsAvailable {
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
        guard bleService.isReadyForCommands else { return }

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
        let probeType = BLECommunicationService.ProbeType.from(string: telemetry.probeType ?? "RS41") ?? .rs41
        bleService.setFrequency(aprsFreq, probeType: probeType)

        // Note: Display will update when RadioSondyGo confirms the new frequency via BLE device settings

        appLog("BalloonPositionService: Startup frequency sync complete", category: .service, level: .info)
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
    @Published var balloonPhase: BalloonPhase = .unknown
    
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
    private var lastMetricsLog: Date? = nil
    
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

            let persistedTrack = persistenceService.loadTrackForCurrentSonde(sondeName: incomingName)

            if let currentName = currentBalloonName,
               currentName != incomingName {
                appLog("BalloonTrackService: Switching from different sonde (\(currentName)) - purging old tracks", category: .service, level: .info)
                persistenceService.purgeAllTracks()
            }

            if let track = persistedTrack {
                self.currentBalloonTrack = track
                appLog("BalloonTrackService: Loaded persisted track for \(incomingName) with \(self.currentBalloonTrack.count) points", category: .service, level: .info)
            } else {
                self.currentBalloonTrack = []
                appLog("BalloonTrackService: No persisted track found - starting fresh track for \(incomingName)", category: .service, level: .info)
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
        let landingLatched = updateLandingDetection(telemetryData)

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
            balloonPhase = .landed
            appLog("BalloonTrackService: APRS age-based landing detected - balloon marked as LANDED at [\(String(format: "%.4f", aprsCoordinate.latitude)), \(String(format: "%.4f", aprsCoordinate.longitude))]", category: .service, level: .info)
        } else if landingLatched {
            balloonPhase = .landed
        } else {
            let verticalTrend = smoothedVerticalSpeed
            if verticalTrend >= 0 {
                balloonPhase = .ascending
            } else {
                balloonPhase = trackPoint.altitude < 10_000 ? .descendingBelow10k : .descendingAbove10k
            }
        }

        if balloonPhase == .landed {
            smoothedHorizontalSpeed = 0
            smoothedVerticalSpeed = 0
            adjustedDescentRate = nil
            adjustedDescentHistory.removeAll()
            emaHorizontalMS = 0
            emaVerticalMS = 0
            slowEmaHorizontalMS = 0
            slowEmaVerticalMS = 0
            hasEma = false
            hasSlowEma = false
            hWindow.removeAll()
            vWindow.removeAll()
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
    
    @discardableResult
    private func updateLandingDetection(_ telemetryData: TelemetryData) -> Bool {
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

        // Debug landing detection criteria (only log when we have meaningful data)
        if window30.count >= 3 && altSpread30 < 1000 && radius30 < 10000 {
            appLog(String(format: "🎯 LANDING: points=%d altSpread=%.1fm radius=%.1fm speed=%.1fkm/h confidence=%.1f%% → landed=%@",
                          window30.count, altSpread30, radius30, smoothedHorizontalSpeedKmh, landingConfidence * 100, isLandedNow ? "YES" : "NO"),
                   category: .general, level: .debug)
        }

        let wasLanded = balloonPhase == .landed
        let wasPreviouslyFlying = balloonPhase != .landed && balloonPhase != .unknown
        var isLanded = wasLanded

        if !wasLanded && isLandedNow {
            // Balloon just landed
            isLanded = true
            landingConfidenceFalsePositiveCount = 0

            // Use smoothed (100) position for landing point
            if landingPositionBuffer.count >= 50 { // Use at least 50 points for reasonable smoothing
                let avgLat = landingPositionBuffer.map { $0.latitude }.reduce(0, +) / Double(landingPositionBuffer.count)
                let avgLon = landingPositionBuffer.map { $0.longitude }.reduce(0, +) / Double(landingPositionBuffer.count)
                landingPosition = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            } else {
                landingPosition = currentPosition
            }

            let altSpreadStr = altSpread30.isFinite ? String(format: "%.2f", altSpread30) : "∞"
            let radiusStr = radius30.isFinite ? String(format: "%.1f", radius30) : "∞"
            appLog("BalloonTrackService: Balloon LANDED — altSpread30=\(altSpreadStr)m, radius30=\(radiusStr)m", category: .service, level: .info)

        } else if isLanded {
            let belowSampleThreshold = window30.count < 3
            if belowSampleThreshold || landingConfidence < landingConfidenceClearThreshold {
                landingConfidenceFalsePositiveCount += 1
            } else {
                landingConfidenceFalsePositiveCount = 0
            }

            if landingConfidenceFalsePositiveCount >= landingConfidenceClearSamplesRequired {
                isLanded = false
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

        let isCurrentlyFlying = hasRecentTelemetry && !isLanded

        if wasPreviouslyFlying && isCurrentlyFlying {
            let instH = telemetryData.horizontalSpeed * 3.6
            let instV = telemetryData.verticalSpeed
            let avgV = smoothedVerticalSpeed
            let phase: String = {
                if isLanded { return "Landed" }
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
        if !isLanded && window30.count >= 10 {
            let nowT = Date()
            if lastMetricsLog == nil || nowT.timeIntervalSince(lastMetricsLog!) > 10.0 {
                lastMetricsLog = nowT
                let altSpreadStr = altSpread30.isFinite ? String(format: "%.2f", altSpread30) : "∞"
                let radiusStr = radius30.isFinite ? String(format: "%.1f", radius30) : "∞"
                appLog("BalloonTrackService: Metrics — altSpread30=\(altSpreadStr)m, radius30=\(radiusStr)m, hSpeed(avg)=\(String(format: "%.2f", smoothedHorizontalSpeedKmh)) km/h", category: .service, level: .debug)
            }
        }
        #endif
        
        return isLanded
    }

    private func publishMotionMetrics(rawHorizontal: Double, rawVertical: Double) {
        let smoothedH = balloonPhase == .landed ? 0 : smoothedHorizontalSpeed
        let smoothedV = balloonPhase == .landed ? 0 : smoothedVerticalSpeed
        let adjusted = balloonPhase == .landed ? Double?(0.0) : adjustedDescentRate
        motionMetrics = BalloonMotionMetrics(
            rawHorizontalSpeedMS: rawHorizontal,
            rawVerticalSpeedMS: rawVertical,
            smoothedHorizontalSpeedMS: smoothedH,
            smoothedVerticalSpeedMS: smoothedV,
            adjustedDescentRateMS: adjusted
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
        balloonPhase = .landed
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
