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

    // Sonde selection popup state
    @Published var showSondeSelectionPopup: Bool = false
    @Published var availableSondesForSelection: [SondeHubSondeData] = []
    @Published var isRefreshingSondeList: Bool = false
    @Published var selectedSondeSerial: String? = nil
    @Published var sondeSelectionCountdown: Int = 5
    private var sondeSelectionContinuation: CheckedContinuation<Void, Never>?
    private var sondeSelectionTimer: Timer?
    private var userStartedEditing: Bool = false

    // Core services
    let currentLocationService: CurrentLocationService
    let bleCommunicationService: BLECommunicationService
    let predictionService: PredictionService

    // Domain services
    let balloonPositionService: BalloonPositionService
    let balloonTrackService: BalloonTrackService
    let landingPointTrackingService: LandingPointTrackingService
    let routeCalculationService: RouteCalculationService
    let navigationService: NavigationService

    private var cancellables = Set<AnyCancellable>()

    // User settings reference (shared instance from AppServices)
    let userSettings: UserSettings

    // App settings reference (for transport mode and other app-level settings)
    var appSettings: AppSettings?

    // Frequency sync proposal forwarded from APRS service
    @Published var frequencySyncProposal: FrequencySyncProposal? = nil
    private var startupFrequencySyncDone: Bool = false  // Only sync once per startup/sonde change

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
        routeCalculationService: RouteCalculationService,
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
        self.routeCalculationService = routeCalculationService
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
        balloonPositionService.setServiceCoordinator(self)
        // Shared dependencies (predictionCache, userSettings) now passed via constructor
    }

    // MARK: - Frequency Sync Interface

    /// Accept the frequency sync proposal
    func acceptFrequencySyncProposal() {
        guard let proposal = frequencySyncProposal else { return }

        // Delegate to BLE service for frequency sync
        bleCommunicationService.acceptFrequencySync(frequency: proposal.frequency, probeType: proposal.probeType, source: "ServiceCoordinator-UserAccepted")

        // Mark startup sync as complete - won't prompt again until sonde change
        startupFrequencySyncDone = true

        // Clear the proposal
        frequencySyncProposal = nil

        appLog("ServiceCoordinator: Frequency sync accepted - startup sync complete", category: .service, level: .info)
    }

    /// Reject the frequency sync proposal
    func rejectFrequencySyncProposal() {
        guard let proposal = frequencySyncProposal else { return }

        // Delegate to BLE service for rejection handling
        bleCommunicationService.rejectFrequencySync(frequency: proposal.frequency, probeType: proposal.probeType)

        // Mark startup sync as complete - won't prompt again until sonde change
        startupFrequencySyncDone = true

        // Clear the proposal
        frequencySyncProposal = nil

        appLog("ServiceCoordinator: Frequency sync rejected - startup sync complete", category: .service, level: .info)
    }

    /// Check frequency sync (called after sonde selection during startup or manual change)
    func checkStartupFrequencySync(aprsRadio: RadioChannelData) {
        // Skip if already done or proposal pending
        guard !startupFrequencySyncDone else { return }
        guard frequencySyncProposal == nil else { return }

        let aprsFreq = aprsRadio.frequency
        let bleFreq = bleCommunicationService.radioSettings.frequency
        let freqMismatch = abs(aprsFreq - bleFreq) > 0.01

        let aprsProbeType = aprsRadio.probeType.isEmpty ? "RS41" : aprsRadio.probeType
        let bleProbeType = bleCommunicationService.radioSettings.probeType
        let probeTypeMismatch = aprsProbeType != bleProbeType

        // Mark sync as evaluated
        startupFrequencySyncDone = true

        guard freqMismatch || probeTypeMismatch else {
            appLog("STARTUP: Frequency matches - APRS: \(String(format: "%.2f", aprsFreq)) MHz, BLE: \(String(format: "%.2f", bleFreq)) MHz", category: .service, level: .info)
            return
        }

        appLog("STARTUP: Frequency mismatch - APRS: \(String(format: "%.2f", aprsFreq)) MHz (\(aprsProbeType)), BLE: \(String(format: "%.2f", bleFreq)) MHz (\(bleProbeType))", category: .service, level: .info)
        frequencySyncProposal = FrequencySyncProposal(frequency: aprsFreq, probeType: aprsProbeType, sondeName: aprsRadio.sondeName)
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
    
    // MARK: - Direct Event Handling
    
    private func setupDirectSubscriptions() {
        // Position data subscription for potential future coordinator needs
        // Currently position data is accessed directly by consumers
        // Frequency sync is handled explicitly during startup and sonde change (not via subscription)

        // Receiver retuned to a different sonde. Per FSD "Sonde Change Flow",
        // every trace of the previous sonde is cleared before the new one is
        // adopted - which is what startTrackingSonde does.
        bleCommunicationService.$confirmedSondeChange
            .compactMap { $0 }
            .sink { [weak self] newSonde in
                guard let self else { return }
                appLog("🎈 ServiceCoordinator: Receiver retuned to '\(newSonde)' - clearing previous sonde", category: .service, level: .info)
                self.bleCommunicationService.confirmedSondeChange = nil
                self.startTrackingSonde(name: newSonde, checkFrequencySync: false)
            }
            .store(in: &cancellables)

        // Monitor state changes to control 60-second prediction timer
        balloonPositionService.$currentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleStateChangeForPredictionTimer(state)
            }
            .store(in: &cancellables)

        // Sonde change coordination: Per FSD, detection happens in BalloonPositionService.handlePositionUpdate()
        // which calls coordinator.clearAllSondeData() directly - no subscription needed here

        // Direct subscriptions setup complete
    }



    // MARK: - 60-Second Prediction Timer

    /// Handle state changes to control prediction timer
    private func handleStateChangeForPredictionTimer(_ state: DataState) {
        switch state {
        case .liveBLEFlying, .aprsFlying:
            // Flying states: start 60-second prediction timer
            startPredictionTimer()
        case .startup, .liveBLELanded, .waitingForAPRS, .aprsLanded, .noTelemetry:
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

    // MARK: - Sonde Change Orchestration (Per FSD)

    /// Clear all old sonde data when new sonde is detected
    /// Called by BalloonPositionService when sonde name change detected
    /// Per FSD Section: Sonde Change Flow
    func clearAllSondeData() {
        appLog("🎈 ServiceCoordinator: Clearing all old sonde data", category: .service, level: .info)

        // Clear all services to initial empty state
        balloonPositionService.clearAllData()
        balloonTrackService.clearAllData()
        landingPointTrackingService.clearAllData()
        predictionService.clearAllData()
        routeCalculationService.clearAllData()
        navigationService.clearAllData()

        // Clear caches (async)
        Task {
            await predictionCache.purgeAll()
            await routingCache.purgeAll()
        }

        appLog("✅ ServiceCoordinator: All old sonde data cleared", category: .service, level: .info)
    }

    // MARK: - Sonde Tracking (Single Entry Point)

    /// Start tracking a sonde - called by all selection methods
    /// This is the ONLY place where tracking setup happens
    /// - Parameters:
    ///   - name: Sonde serial number
    ///   - checkFrequencySync: Whether to check frequency sync (false for BLE-detected sondes already tuned)
    func startTrackingSonde(name: String, checkFrequencySync: Bool = true) {
        let currentSonde = balloonPositionService.currentBalloonName ?? ""
        guard name != currentSonde else {
            appLog("ServiceCoordinator: Already tracking '\(name)'", category: .general, level: .info)
            return
        }

        appLog("ServiceCoordinator: === Starting to track sonde '\(name)' (was: '\(currentSonde)') ===", category: .general, level: .info)

        // 1. Clear all old sonde data
        clearAllSondeData()

        // 2. Set frequency sync flag
        startupFrequencySyncDone = !checkFrequencySync

        // 3. Set sonde name in services
        balloonPositionService.currentBalloonName = name
        balloonTrackService.injectPersistedData(sondeName: name, track: [])

        // Tell the receiver which sonde this hunt follows, so telemetry for any
        // other one is dropped before it enters the app.
        bleCommunicationService.huntedSondeName = name

        // 4. Set APRS override (works even if sonde not in APRS)
        balloonPositionService.aprsService.overrideSondeSerial = name

        // 5. Fetch APRS data, fill track, check frequency sync
        Task { [weak self] in
            await self?.balloonPositionService.aprsService.forceImmediateFetch()
            self?.balloonTrackService.fillTrackGapsFromAPRS(sondeName: name)

            // Check frequency sync if requested and BLE connected
            if checkFrequencySync {
                await MainActor.run {
                    if let self = self,
                       self.bleCommunicationService.connectionState.canReceiveCommands,
                       let aprsRadio = self.balloonPositionService.aprsService.latestRadioChannel {
                        self.checkStartupFrequencySync(aprsRadio: aprsRadio)
                    }
                }
            }
        }

        // 6. Trigger state evaluation - enables predictions, routing, track recording
        balloonPositionService.triggerStateEvaluation()

        appLog("ServiceCoordinator: === Now tracking '\(name)' ===", category: .general, level: .info)
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

    // MARK: - Sonde Selection Popup

    /// Wait for user to confirm sonde selection during startup
    func waitForSondeSelection() async {
        // Start the countdown timer
        startSondeSelectionCountdown()

        await withCheckedContinuation { continuation in
            sondeSelectionContinuation = continuation
        }
    }

    /// Start the 5-second countdown timer for auto-confirm
    private func startSondeSelectionCountdown() {
        sondeSelectionCountdown = 5
        userStartedEditing = false

        sondeSelectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                // Don't count down if user started editing
                guard !self.userStartedEditing else {
                    self.sondeSelectionTimer?.invalidate()
                    self.sondeSelectionTimer = nil
                    return
                }

                self.sondeSelectionCountdown -= 1

                if self.sondeSelectionCountdown <= 0 {
                    // Auto-confirm with detected sonde
                    appLog("ServiceCoordinator: Auto-confirming sonde selection after timeout", category: .general, level: .info)
                    self.confirmSondeSelection()
                }
            }
        }
    }

    /// Called when user starts editing the sonde name field
    func userDidStartEditingSondeName() {
        userStartedEditing = true
        sondeSelectionTimer?.invalidate()
        sondeSelectionTimer = nil
        appLog("ServiceCoordinator: User started editing - countdown cancelled", category: .general, level: .debug)
    }

    /// User confirmed sonde selection (tapped "Use" or auto-confirmed)
    func confirmSondeSelection() {
        // Stop timer if running
        sondeSelectionTimer?.invalidate()
        sondeSelectionTimer = nil

        // Close popup and resume continuation
        defer {
            showSondeSelectionPopup = false
            sondeSelectionContinuation?.resume()
            sondeSelectionContinuation = nil
        }

        guard let selectedSerial = selectedSondeSerial?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !selectedSerial.isEmpty else {
            appLog("ServiceCoordinator: confirmSondeSelection - no sonde selected", category: .general, level: .info)
            return
        }

        // Start tracking the selected sonde (handles all setup)
        startTrackingSonde(name: selectedSerial, checkFrequencySync: true)
    }

    /// User skipped sonde selection (tapped "Skip")
    func skipSondeSelection() {
        // Stop timer if running
        sondeSelectionTimer?.invalidate()
        sondeSelectionTimer = nil

        appLog("ServiceCoordinator: User skipped sonde selection", category: .general, level: .info)
        showSondeSelectionPopup = false
        sondeSelectionContinuation?.resume()
        sondeSelectionContinuation = nil
    }

    /// Show sonde selection popup during operation (Change Sonde)
    func showSondeSelectionForChange() {
        // Update available sondes list from APRS service
        availableSondesForSelection = balloonPositionService.aprsService.availableSondes
        selectedSondeSerial = balloonPositionService.currentBalloonName

        // Reset countdown
        sondeSelectionCountdown = 0  // No auto-confirm during manual change
        userStartedEditing = false

        showSondeSelectionPopup = true
        appLog("ServiceCoordinator: Showing sonde selection for manual change (\(availableSondesForSelection.count) cached)", category: .general, level: .info)

        // Show the cached list at once, then refresh from SondeHub so the picker
        // reflects the last 24 h as of now rather than as of app launch.
        isRefreshingSondeList = true
        Task { [weak self] in
            guard let self else { return }
            await self.balloonPositionService.aprsService.refreshAvailableSondes()
            self.availableSondesForSelection = self.balloonPositionService.aprsService.availableSondes
            self.isRefreshingSondeList = false

            // Keep the highlighted row valid if the refresh dropped it.
            if let selected = self.selectedSondeSerial,
               !self.availableSondesForSelection.contains(where: { $0.serial == selected }) {
                self.selectedSondeSerial = self.availableSondesForSelection.first?.serial
            }
            appLog("ServiceCoordinator: Sonde list refreshed (\(self.availableSondesForSelection.count) available)", category: .general, level: .info)
        }
    }

    /// Switch to a sonde detected by BLE (may not be in APRS)
    /// Handles edge case where BLE receives a flying sonde not in SondeHub
    func switchToBLESonde(_ sondeName: String) {
        // No frequency sync needed - BLE is already tuned to this sonde
        startTrackingSonde(name: sondeName, checkFrequencySync: false)
    }
}
