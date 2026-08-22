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
    /// The last frequency proposal the hunter answered, accepted or rejected. A
    /// question that differs from it may be asked again; one that equals it may
    /// not. See FSD *Keeping the receiver on the hunted frequency* (FR-F.3).
    private var lastAnsweredFrequencyQuestion: FrequencyQuestion?
    /// What the sonde context load is doing right now, or `nil` when it is not
    /// running. Loading a whole flight from SondeHub takes seconds, and without
    /// this the hunter watches an unchanged screen and reasonably concludes the app
    /// has hung. Published as text so the view only renders it.
    @Published private(set) var sondeContextProgress: String?

    // 60-second prediction timer (as referenced in comments)
    private var predictionTimer: Timer? = nil

    // 5-minute recovery-status timer: while landed, ask SondeHub (radiosondy
    // finds) whether the sonde has been recovered, to colour the balloon.
    private var recoveryTimer: Timer? = nil

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

        lastAnsweredFrequencyQuestion = proposal.question
        frequencySyncProposal = nil

        appLog("ServiceCoordinator: Frequency sync accepted - receiver following the hunted sonde", category: .service, level: .info)
    }

    /// Reject the frequency sync proposal
    func rejectFrequencySyncProposal() {
        guard let proposal = frequencySyncProposal else { return }

        // Delegate to BLE service for rejection handling
        bleCommunicationService.rejectFrequencySync(frequency: proposal.frequency, probeType: proposal.probeType)

        lastAnsweredFrequencyQuestion = proposal.question
        frequencySyncProposal = nil

        appLog("ServiceCoordinator: Frequency sync rejected - not asking again until something changes", category: .service, level: .info)
    }

    /// Ask whether the receiver should follow the hunted sonde. Called on each of
    /// the three triggers of FR-F.1-F.3 - a selection, a receiver connection, and a
    /// changed report for the hunted sonde - because those are exactly the moments
    /// the answer can change. `FrequencySyncPolicy` decides; this only carries the
    /// question to the alert.
    func checkFrequencySync(aprsRadio: RadioChannelData) {
        guard frequencySyncProposal == nil else { return }
        guard bleCommunicationService.connectionState.canReceiveCommands else { return }

        let question = FrequencySyncPolicy.question(
            huntedFrequency: aprsRadio.frequency,
            huntedProbeType: aprsRadio.probeType,
            receiverFrequency: bleCommunicationService.radioSettings.frequency,
            receiverProbeType: bleCommunicationService.radioSettings.probeType,
            connectionGeneration: bleCommunicationService.connectionGeneration)

        guard FrequencySyncPolicy.shouldAsk(question, lastAnswered: lastAnsweredFrequencyQuestion),
              let question else { return }

        let aprsProbeType = aprsRadio.probeType.isEmpty ? "RS41" : aprsRadio.probeType
        appLog("FREQ: Receiver on \(String(format: "%.2f", bleCommunicationService.radioSettings.frequency)) MHz (\(bleCommunicationService.radioSettings.probeType)), hunted sonde on \(String(format: "%.2f", aprsRadio.frequency)) MHz (\(aprsProbeType)) - proposing the change", category: .service, level: .info)
        frequencySyncProposal = FrequencySyncProposal(frequency: aprsRadio.frequency,
                                                      probeType: aprsProbeType,
                                                      sondeName: aprsRadio.sondeName,
                                                      question: question)
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

        // Recovery status: every 5 minutes, if the balloon is landed, check whether
        // it has been found (radiosondy.info via SondeHub). Cheap — one request per
        // 5 min, and only when landed. Startup and sonde-selection are covered
        // separately (entering a landed state, and startTrackingSonde).
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.balloonPositionService.balloonPhase == .landed else { return }
                self.balloonPositionService.checkRecoveryStatus()
            }
        }

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
        //
        // Ask SondeHub about the serial *before* clearing anything. A sonde on a
        // bench transmits like any other and five of its packets declare a retune,
        // so without this the hunted sonde's track, landing point and route are
        // discarded for a unit that is going nowhere. One request, on a confirmed
        // retune only. See FSD *Test sondes must not take over the hunt*.
        bleCommunicationService.$confirmedSondeChange
            .compactMap { $0 }
            .sink { [weak self] newSonde in
                guard let self else { return }
                self.bleCommunicationService.confirmedSondeChange = nil
                Task { [weak self] in
                    guard let self else { return }
                    let frames = await self.balloonPositionService.aprsService.recentFrameCount(serial: newSonde)
                    guard !TestSonde.isTestSonde(recentFrameCount: frames) else {
                        appLog("🧪 ServiceCoordinator: '\(newSonde)' is a test sonde - SondeHub holds nothing for it. Keeping the hunt on '\(self.balloonPositionService.currentBalloonName ?? "none")'", category: .service, level: .info)
                        return
                    }
                    appLog("🎈 ServiceCoordinator: Receiver retuned to '\(newSonde)' - clearing previous sonde", category: .service, level: .info)
                    self.startTrackingSonde(name: newSonde, checkFrequencySync: false)
                }
            }
            .store(in: &cancellables)

        // The prediction timer follows `PredictionPolicy`, so it must be re-evaluated
        // whenever any of that policy's three inputs changes — not on state alone.
        // In landed-by-silence the decision flips the moment the first estimate
        // arrives, which is what stops the marker drifting under a driving hunter.
        balloonPositionService.$currentState
            .map { _ in () }
            .merge(with: balloonPositionService.$landingConfirmedByBLE.map { _ in () },
                   predictionService.$latestPrediction.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updatePredictionTimer()
            }
            .store(in: &cancellables)

        // Triggers 2 and 3 of FR-F.1/F.2. The receiver connecting, and the hunted
        // sonde's reported channel changing, are the other two moments the answer
        // to "is the receiver on the hunted frequency?" can change. Both funnel
        // into the same owner as the selection trigger; `FrequencySyncPolicy`
        // decides whether anything is actually asked, so a redundant trigger is
        // silent rather than a repeated alert.
        bleCommunicationService.$connectionGeneration
            .removeDuplicates()
            .map { _ in () }
            .merge(with: balloonPositionService.aprsService.$latestRadioChannel.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self,
                      let aprsRadio = self.balloonPositionService.aprsService.latestRadioChannel else { return }
                self.checkFrequencySync(aprsRadio: aprsRadio)
            }
            .store(in: &cancellables)

        // Sonde change coordination: Per FSD, detection happens in BalloonPositionService.handlePositionUpdate()
        // which calls coordinator.clearAllSondeData() directly - no subscription needed here

        // Direct subscriptions setup complete
    }



    // MARK: - 60-Second Prediction Timer

    /// Run or stop the prediction timer according to `PredictionPolicy`, from the
    /// current value of each of its inputs. Called whenever any of them changes.
    private func updatePredictionTimer() {
        let shouldPredict = PredictionPolicy.shouldPredict(
            state: balloonPositionService.currentState,
            touchdownConfirmed: balloonPositionService.landingConfirmedByBLE,
            hasPrediction: predictionService.latestPrediction != nil)

        if shouldPredict {
            startPredictionTimer()
        } else {
            stopPredictionTimer()
        }
    }

    /// Start the 60-second prediction timer for flying states
    private func startPredictionTimer() {
        // Don't start if already running
        guard predictionTimer == nil else { return }

        appLog("ServiceCoordinator: Starting 60-second prediction timer", category: .service, level: .info)
        predictionService.startAutomaticPredictions()

        // Fire once immediately so the predicted landing (and route) appears now,
        // not after the first 60 s — matters when entering landed-by-silence,
        // where the last-heard frame is the only basis and no further data comes.
        predictionTimerFired()

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
        // No "already tracking" shortcut. Selection is the only thing that names a
        // hunted sonde, and it always means: set this one up.
        let previousSonde = balloonPositionService.currentBalloonName

        appLog("ServiceCoordinator: === Starting to track sonde '\(name)' (was: '\(previousSonde ?? "none")') ===", category: .general, level: .info)

        // 1. Clear the previous sonde's data — only when there genuinely is a
        //    different previous sonde. On cold start the name already matches the
        //    restored track, and clearing here would throw away the very track that
        //    was just loaded from disk (including BLE points SondeHub never had).
        if let previousSonde, previousSonde != name {
            clearAllSondeData()
        } else {
            appLog("ServiceCoordinator: Same sonde as restored/current - keeping its track, nothing to clear", category: .general, level: .info)
        }

        // 2. Set frequency sync flag
        // A sonde adopted from BLE is one the receiver is already tuned to, so the
        // rule finds nothing to ask and the old suppression flag is unnecessary.
        // Asking on every selection is the trigger FR-F.1 names.

        // 3. Set the sonde name. One stored copy; BalloonTrackService reads it.
        balloonPositionService.currentBalloonName = name

        // Tell the receiver which sonde this hunt follows, so telemetry for any
        // other one is dropped before it enters the app.
        bleCommunicationService.huntedSondeName = name

        // 4. Set APRS override (works even if sonde not in APRS)
        balloonPositionService.aprsService.overrideSondeSerial = name
        balloonPositionService.aprsService.recoveryStatus = .none  // reset for the new sonde

        // 5. Read the entire sonde context from SondeHub — telemetry, track and
        // recovery — then establish the landing prediction and route from it. This
        // is the one place it happens; startup and every new sonde come through
        // here. Ongoing re-prediction is flying-only (PredictionPolicy), so a
        // landed sonde is predicted once here and does not drift.
        Task { [weak self] in
            guard let self else { return }
            defer { self.sondeContextProgress = nil }

            // ① Read the balloon context — the retained track topped up from
            //    SondeHub, latest position published. Recovery is a sibling call.
            self.sondeContextProgress = "Loading \(name) from SondeHub…"
            await self.balloonTrackService.readBalloonContext(serial: name)

            self.sondeContextProgress = "Checking whether \(name) was recovered…"
            await self.balloonPositionService.aprsService.checkRecovery(serial: name)

            // ② track is drawn from that data. ③ prediction from the published
            // position → ④ route. One ordered chain, no second fetch.
            //
            // `PredictionPolicy` decides here as everywhere else. A confirmed
            // touchdown means the position is known and there is nothing left to
            // estimate, so predicting anyway would move a landing marker off the
            // balloon the receiver is standing next to.
            if let position = self.balloonPositionService.aprsService.latestPosition,
               PredictionPolicy.shouldPredict(
                   state: self.balloonPositionService.currentState,
                   touchdownConfirmed: self.balloonPositionService.landingConfirmedByBLE,
                   hasPrediction: self.predictionService.latestPrediction != nil) {
                self.sondeContextProgress = "Predicting the landing point…"
                await self.predictionService.triggerPredictionWithPosition(position, trigger: "sonde-context")
            }

            // Trigger 1 of FR-F.1: a sonde was selected, so the hunted channel may
            // have changed.
            if let aprsRadio = self.balloonPositionService.aprsService.latestRadioChannel {
                self.checkFrequencySync(aprsRadio: aprsRadio)
            }
        }

        // 6. Trigger state evaluation - enables predictions, routing, track recording
        balloonPositionService.triggerStateEvaluation()

        appLog("ServiceCoordinator: === Now tracking '\(name)' ===", category: .general, level: .info)
    }

    // MARK: - Phase 2: When To Leave

    /// When to set off in order to meet the landing.
    ///
    /// Both halves move - the landing time as the flight develops, the driving
    /// time as the route is recalculated - so this is read fresh each time rather
    /// than stored. See *FSD -> Hunt Phases -> Phase 2*.
    var departurePlan: DepartureTime.Plan? {
        DepartureTime().plan(
            landingTime: predictionService.latestPrediction?.landingTime,
            drivingTime: routeCalculationService.currentRoute?.expectedTravelTime
        )
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
    /// Show sonde selection popup during operation (Change Sonde)
    /// **An empty picker must never appear.** It has no Skip — a hunt always has a
    /// hunted sonde — so a picker with nothing in it is a dead end. When the cached
    /// list is empty the refresh happens *first* and the picker is presented only if
    /// it produced candidates.
    func showSondeSelectionForChange() {
        let cached = balloonPositionService.aprsService.availableSondes

        guard !cached.isEmpty else {
            appLog("ServiceCoordinator: Change Sonde - nothing cached, fetching before presenting", category: .general, level: .info)
            isRefreshingSondeList = true
            Task { [weak self] in
                guard let self else { return }
                await self.balloonPositionService.aprsService.refreshAvailableSondes()
                self.isRefreshingSondeList = false
                let fetched = self.balloonPositionService.aprsService.availableSondes
                guard !fetched.isEmpty else {
                    appLog("ServiceCoordinator: Change Sonde - no sondes available, picker not shown", category: .general, level: .info)
                    return
                }
                self.presentSondePicker(fetched)
            }
            return
        }

        // Show the cached list at once, then refresh from SondeHub so the picker
        // reflects the last 24 h as of now rather than as of app launch.
        presentSondePicker(cached)
        isRefreshingSondeList = true
        Task { [weak self] in
            guard let self else { return }
            await self.balloonPositionService.aprsService.refreshAvailableSondes()
            let refreshed = self.balloonPositionService.aprsService.availableSondes
            self.isRefreshingSondeList = false

            // A refresh that empties the list would leave an empty picker on screen.
            guard !refreshed.isEmpty else {
                appLog("ServiceCoordinator: Sonde list refresh returned nothing - keeping the cached list rather than emptying the picker", category: .general, level: .info)
                return
            }
            self.availableSondesForSelection = refreshed

            // Keep the highlighted row valid if the refresh dropped it.
            if let selected = self.selectedSondeSerial,
               !refreshed.contains(where: { $0.serial == selected }) {
                self.selectedSondeSerial = refreshed.first?.serial
            }
            appLog("ServiceCoordinator: Sonde list refreshed (\(refreshed.count) available)", category: .general, level: .info)
        }
    }

    /// Put a non-empty candidate list on screen. The only place the picker is shown
    /// for a manual change, so the non-empty precondition holds in one spot.
    private func presentSondePicker(_ sondes: [SondeHubSondeData]) {
        precondition(!sondes.isEmpty, "the picker must never be presented empty")
        availableSondesForSelection = sondes
        selectedSondeSerial = balloonPositionService.currentBalloonName ?? sondes.first?.serial
        sondeSelectionCountdown = 0  // No auto-confirm during manual change
        userStartedEditing = false
        showSondeSelectionPopup = true
        appLog("ServiceCoordinator: Showing sonde selection for manual change (\(sondes.count) available)", category: .general, level: .info)
    }

    /// Switch to a sonde detected by BLE (may not be in APRS)
    /// Handles edge case where BLE receives a flying sonde not in SondeHub
    func switchToBLESonde(_ sondeName: String) {
        // No frequency sync needed - BLE is already tuned to this sonde
        startTrackingSonde(name: sondeName, checkFrequencySync: false)
    }
}
