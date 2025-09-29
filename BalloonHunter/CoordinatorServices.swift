// CoordinatorServices.swift
// Extensions for ServiceCoordinator to handle complex service coordination logic
// This file contains startup sequence and other service coordination methods

import Foundation
import Combine
import SwiftUI
import CoreLocation
import CoreBluetooth
import MapKit
import OSLog
import UIKit

// MARK: - Startup Sequence Extension
/** [markdown]
# Startup

This section captures the startup flow defined in the Balloon Hunter App FSD (V5) and
documents how the coordinator orchestrates initialization. It is provided here as
in‑code markup for quick reference while working on the startup sequence.

## Sequence

1) Service Initialization
   - Initialize core services as early as possible.
   - Present the logo page immediately during startup.

2) Connect Device
   - BLE service attempts to connect to MySondyGo.
   - Wait up to 5 seconds for a connection; BLE remains non‑blocking and may connect later.
   - If no connection, set the "no tracking" flag (degraded mode) and continue.

3) Publish Telemetry
   - After the first BLE packet is received and decoded, BLE publishes whether telemetry is available.

4) Device Settings (on-demand only)
   - Device settings are fetched only when SettingsView is opened or frequency sync is needed.
   - Startup optimization: No automatic o{?}o command during startup since frequency/probe type are available in telemetry packets.

5) Read Persistence
   - Load from persistence:
     - Prediction parameters
     - Historic track data
     - Landing point (if available)

6) Landing Point Determination
   - BalloonTrackService publishes landing state/position derived from telemetry and persistence.
   - Coordinator simply mirrors that state; no additional heuristics required.

7) Final Map Displayed
   - Show the tracking map (with button row and data panel).
   - Initial map uses maximum zoom level to show all available overlays:
     - User position
     - Landing position (if available)
     - If a balloon is flying, the route and predicted path

8) End of Setup
   - Transition to steady‑state tracking: BLE telemetry updates, prediction scheduling (60 s),
     and route recalculation (on mode change and significant user movement).

## Notes
 - Views remain presentation‑only; logic resides in services and this coordinator.
 - BalloonTrackService provides smoothed speeds, adjusted descent rate, and landed state.
 - PredictionService handles both API calls and automatic 60‑second scheduling.
 - Automatic frequency sync: BalloonPositionService automatically syncs RadioSondyGo frequency when APRS telemetry becomes available during startup (no user prompt).
*/
extension ServiceCoordinator {
    
    /// Performs the complete startup sequence
    func performCompleteStartupSequence() async {
        let startTime = Date()
        let maxStartupTime: TimeInterval = 15.0 // BLE timeout (5s) + APRS timeout (5s) + buffer (5s)

        // Overall startup timeout task
        let startupTask = Task {
            // Step 1: Service Initialization (already done)
            await MainActor.run {
                currentStartupStep = 1
                startupProgress = "Step 1: Services"
            }
            appLog("STARTUP: Step 1 - Service initialization complete", category: .general, level: .info)

            // Step 2: Start both services and wait for definitive answers
            await MainActor.run {
                currentStartupStep = 2
                startupProgress = "Step 2: BLE & APRS"
            }
            async let bleResult = startBLEConnectionWithTimeout()
            async let aprsTask: Void = primeAPRSStartupData()

            let (_, _) = await bleResult
            await aprsTask

            // Wait for definitive answers from both services
            await waitForServiceAnswers()

            // Step 3: Load persistence data and complete startup
            await MainActor.run {
                currentStartupStep = 3
                startupProgress = "Step 3: Data & Startup"
            }
            await loadAllPersistenceData()
            balloonPositionService.completeStartup()

            // Step 4: End startup - hand control to state machine
            let totalTime = Date().timeIntervalSince(startTime)
            await MainActor.run {
                isStartupComplete = true
                showLogo = false
                showTrackingMap = true
            }

            appLog("STARTUP: Complete ✅ Services answered, control handed to state machine (\(String(format: "%.1f", totalTime))s total)", category: .general, level: .info)
        }

        // Create timeout task
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(maxStartupTime * 1_000_000_000))
            await MainActor.run {
                startupProgress = "💀 Something horrible happened"
                appLog("STARTUP: TIMEOUT ☠️ Startup exceeded \(maxStartupTime)s limit", category: .general, level: .error)
            }
        }

        // Race between startup and timeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await startupTask.value
                timeoutTask.cancel()
            }
            group.addTask {
                try? await timeoutTask.value
                startupTask.cancel()
            }
            await group.next()
            group.cancelAll()
        }
    }
    
    
    // MARK: - Step 2: BLE Connection
    
    private func startBLEConnectionWithTimeout() async -> (connected: Bool, hasMessage: Bool) {
        // Just start BLE scanning if Bluetooth is available
        guard bleCommunicationService.centralManager.state == .poweredOn else {
            appLog("Step 2: Bluetooth not powered on", category: .general, level: .info)
            return (connected: false, hasMessage: false)
        }

        bleCommunicationService.startScanning()
        appLog("Step 2: BLE scanning started", category: .general, level: .info)
        return (connected: false, hasMessage: false)
    }

    // MARK: - Step 3: First Telemetry Package

    private func waitForFirstBLEPackageAndPublishTelemetryStatus() async {
        // Step 3: Report current BLE status to state machine (no timeout)
        appLog("Step 3: BLE service initialized - state machine will monitor telemetry", category: .general, level: .info)
        // State machine will handle all BLE connection monitoring and timeout decisions
    }

    // Step 4 removed: BLE service issues o{?}o after first packet; SettingsView also requests on demand.

    // MARK: - Step 5: Persistence Data
    
    func loadAllPersistenceData() async {
        // Step 5: Reading persistence data (log removed)

        // Load prediction parameters (already loaded during initialize)
        // Historic track data will be loaded by BalloonTrackService when first telemetry arrives
        // Landing point loaded from persistence
        loadPersistenceData()

        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds for loading
        // Persistence data loading complete
    }

    // MARK: - Step 6: Landing Point & Step 7: Final Display
    
    private func setupInitialMapDisplay() async {
        // Show tracking map for the first time
        // TrackingMapView will automatically trigger showAnnotations when map is ready

        await MainActor.run {
            showTrackingMap = true
        }

        // Brief wait for UI to update
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds


        // TrackingMapView will call updateCameraToShowAllAnnotations() when map camera initializes
    }

    /// Start APRS service immediately during startup (Step 2 of startup sequence)
    private func primeAPRSStartupData() async {
        // Start APRS polling immediately - no separate priming step
        balloonPositionService.aprsService.startPolling()
    }

    /// Wait for initial APRS data before completing state machine startup
    private func waitForInitialAPRSData() async {
        // Just start APRS polling - let overall startup timeout handle failures
        appLog("STARTUP: APRS polling started", category: .general, level: .info)
    }

    /// Wait for definitive answers from both BLE and APRS services
    private func waitForServiceAnswers() async {
        while true {
            let bleAnswered = hasBleProvivedAnswer()
            let aprsAnswered = hasAprsProvidedAnswer()

            if bleAnswered && aprsAnswered {
                appLog("STARTUP: Both services provided definitive answers", category: .general, level: .info)
                return
            }

            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second checks
        }
    }

    /// Check if BLE service has provided a definitive answer (enum published after first packet)
    private func hasBleProvivedAnswer() -> Bool {
        // BLE answered if: Bluetooth is off OR received valid connection state (.readyForCommands or .dataReady)
        return bleCommunicationService.centralManager.state != .poweredOn ||
               bleCommunicationService.connectionState == .readyForCommands ||
               bleCommunicationService.connectionState == .dataReady
    }

    /// Check if APRS service has provided a definitive answer (data or error)
    private func hasAprsProvidedAnswer() -> Bool {
        // APRS answered if: has data OR has error
        return balloonPositionService.aprsService.latestPosition != nil ||
               balloonPositionService.aprsService.lastApiError != nil
    }


}

// MARK: - Frequency Management Service

@MainActor
final class FrequencyManagementService: ObservableObject {
    @Published var syncProposal: FrequencySyncProposal? = nil

    private let bleService: BLECommunicationService
    private var cancellables = Set<AnyCancellable>()

    init(bleService: BLECommunicationService, balloonPositionService: BalloonPositionService) {
        self.bleService = bleService

        // Subscribe to state changes and radio data for frequency sync evaluation
        Publishers.CombineLatest(
            balloonPositionService.$currentState,
            balloonPositionService.$currentRadioChannel
        )
        .sink { [weak self] state, radioData in
            let freqString = radioData.map { String(format: "%.2f", $0.frequency) } ?? "nil"
            appLog("FrequencyManagementService: Subscriber triggered - state: \(state), radioData frequency: \(freqString) MHz", category: .service, level: .debug)
            self?.evaluateFrequencySync(state: state, radioData: radioData,
                                      positionData: balloonPositionService.currentPositionData)
        }
        .store(in: &cancellables)

        // Subscribe to APRS radio data for startup frequency sync comparison
        balloonPositionService.aprsService.$latestRadioChannel
            .sink { [weak self] aprsRadioData in
                if let aprsData = aprsRadioData, aprsData.telemetrySource == .aprs {
                    let state = balloonPositionService.currentState
                    appLog("FrequencyManagementService: APRS radio data received - state: \(state), freq: \(String(format: "%.2f", aprsData.frequency)) MHz", category: .service, level: .debug)

                    // Trigger frequency sync evaluation with APRS radio data
                    self?.evaluateFrequencySync(state: state, radioData: aprsData,
                                              positionData: balloonPositionService.currentPositionData)
                }
            }
            .store(in: &cancellables)
    }

    /// Accept and execute the frequency sync proposal
    func acceptFrequencySyncProposal() {
        guard let proposal = syncProposal else { return }

        // Delegate to BLE service for frequency sync
        bleService.acceptFrequencySync(frequency: proposal.frequency, probeType: proposal.probeType, source: "FrequencyManagement-UserAccepted")

        // Clear the proposal
        syncProposal = nil
    }

    /// Reject the frequency sync proposal
    func rejectFrequencySyncProposal() {
        guard let proposal = syncProposal else { return }

        // Delegate to BLE service for rejection handling
        bleService.rejectFrequencySync(frequency: proposal.frequency, probeType: proposal.probeType)

        // Clear the proposal
        syncProposal = nil
    }

    private func evaluateFrequencySync(state: DataState, radioData: RadioChannelData?, positionData: PositionData?) {
        appLog("FrequencyManagementService: evaluateFrequencySync called with state: \(state), radioData: \(radioData != nil ? "present" : "nil"), positionData: \(positionData != nil ? "present" : "nil")", category: .service, level: .debug)

        if let radio = radioData {
            appLog("FrequencyManagementService: Radio data - source: \(radio.telemetrySource), freq: \(String(format: "%.2f", radio.frequency)) MHz, probe: '\(radio.probeType)'", category: .service, level: .debug)
        }
        if let position = positionData {
            appLog("FrequencyManagementService: Position data - source: \(position.telemetrySource), sonde: '\(position.sondeName)'", category: .service, level: .debug)
        }

        switch state {
        case .aprsFallbackFlying, .aprsFallbackLanded:
            appLog("FrequencyManagementService: APRS fallback state - evaluating frequency proposal", category: .service, level: .debug)
            evaluateAPRSFrequencyProposal(radioData: radioData, positionData: positionData)

        case .startup:
            appLog("FrequencyManagementService: Startup state - evaluating frequency sync", category: .service, level: .debug)
            evaluateStartupFrequencySync(radioData: radioData, positionData: positionData)

        case .liveBLEFlying, .liveBLELanded, .waitingForAPRS:
            // Evaluate frequency sync when APRS data is available for comparison
            if let radio = radioData, radio.telemetrySource == .aprs {
                appLog("FrequencyManagementService: Evaluating APRS-BLE frequency sync in state \(state) - APRS freq: \(String(format: "%.2f", radio.frequency)) MHz", category: .service, level: .info)
                evaluateAPRSFrequencyProposal(radioData: radioData, positionData: positionData)
            } else {
                let radioSource = radioData?.telemetrySource.rawValue ?? "nil"
                let radioFreq = radioData.map { String(format: "%.2f", $0.frequency) } ?? "nil"
                let bleDeviceFreq = String(format: "%.2f", bleService.deviceSettings.frequency)
                appLog("FrequencyManagementService: No APRS radio data available for frequency sync evaluation in state \(state) (radio source: \(radioSource), radio freq: \(radioFreq), BLE device freq: \(bleDeviceFreq))", category: .service, level: .debug)
            }

        case .noTelemetry:
            appLog("FrequencyManagementService: No telemetry state - skipping frequency sync evaluation", category: .service, level: .debug)
            break
        }
    }

    private func evaluateAPRSFrequencyProposal(radioData: RadioChannelData?, positionData: PositionData?) {
        appLog("FrequencyManagementService: evaluateAPRSFrequencyProposal called", category: .service, level: .debug)

        guard let radio = radioData else {
            appLog("FrequencyManagementService: No radio data available", category: .service, level: .debug)
            return
        }

        // For frequency sync, we need radio data with APRS frequency information
        // This can be triggered in BLE states when APRS data is available for comparison
        guard radio.telemetrySource == .aprs else {
            appLog("FrequencyManagementService: Radio data source is not APRS: \(radio.telemetrySource)", category: .service, level: .debug)
            return
        }

        // Only evaluate frequency sync when BLE is ready for commands
        guard bleService.connectionState.canReceiveCommands else {
            appLog("FrequencyManagementService: BLE not ready for commands (state: \(bleService.connectionState)) - skipping frequency sync evaluation", category: .service, level: .debug)
            return
        }

        let aprsFreq = radio.frequency
        let bleFreq = bleService.deviceSettings.frequency
        let freqDifference = abs(aprsFreq - bleFreq)
        let freqMismatch = freqDifference > 0.01

        let aprsProbeType = radio.probeType.isEmpty ? "RS41" : radio.probeType
        let bleProbeType = bleService.deviceSettings.probeType
        let probeTypeMismatch = aprsProbeType != bleProbeType

        appLog("FrequencyManagementService: Frequency comparison - APRS: \(String(format: "%.2f", aprsFreq)) MHz, BLE: \(String(format: "%.2f", bleFreq)) MHz, difference: \(String(format: "%.2f", freqDifference)) MHz, mismatch: \(freqMismatch)", category: .service, level: .info)
        appLog("FrequencyManagementService: Probe type comparison - APRS: '\(aprsProbeType)', BLE: '\(bleProbeType)', mismatch: \(probeTypeMismatch)", category: .service, level: .info)

        guard freqMismatch || probeTypeMismatch else {
            appLog("FrequencyManagementService: APRS-BLE frequency/probe match, no sync needed", category: .service, level: .debug)
            return
        }

        appLog("FrequencyManagementService: APRS fallback frequency sync needed - creating user proposal", category: .service, level: .info)
        createFrequencySyncProposal(aprsFreq: aprsFreq, aprsProbeType: aprsProbeType, bleFreq: bleFreq, bleProbeType: bleProbeType)
    }

    private func evaluateStartupFrequencySync(radioData: RadioChannelData?, positionData: PositionData?) {
        appLog("FrequencyManagementService: evaluateStartupFrequencySync called", category: .service, level: .debug)

        guard let radio = radioData else {
            appLog("FrequencyManagementService: Startup - No radio data available", category: .service, level: .debug)
            return
        }

        // During startup, we can have APRS radio data without position data
        // Check if this is APRS radio data (from API response)
        guard radio.telemetrySource == .aprs else {
            appLog("FrequencyManagementService: Startup - Radio data source is not APRS: \(radio.telemetrySource)", category: .service, level: .debug)
            return
        }

        // Only evaluate frequency sync when BLE is ready for commands
        guard bleService.connectionState.canReceiveCommands else {
            appLog("FrequencyManagementService: Startup - BLE not ready for commands (state: \(bleService.connectionState)) - skipping frequency sync evaluation", category: .service, level: .debug)
            return
        }

        let aprsFreq = radio.frequency
        let bleFreq = bleService.deviceSettings.frequency
        let freqDifference = abs(aprsFreq - bleFreq)
        let freqMismatch = freqDifference > 0.01

        let aprsProbeType = radio.probeType.isEmpty ? "RS41" : radio.probeType
        let bleProbeType = bleService.deviceSettings.probeType
        let probeTypeMismatch = aprsProbeType != bleProbeType

        appLog("FrequencyManagementService: Startup frequency comparison - APRS: \(String(format: "%.2f", aprsFreq)) MHz, BLE: \(String(format: "%.2f", bleFreq)) MHz, difference: \(String(format: "%.2f", freqDifference)) MHz, mismatch: \(freqMismatch)", category: .service, level: .info)
        appLog("FrequencyManagementService: Startup probe type comparison - APRS: '\(aprsProbeType)', BLE: '\(bleProbeType)', mismatch: \(probeTypeMismatch)", category: .service, level: .info)

        guard freqMismatch || probeTypeMismatch else {
            appLog("FrequencyManagementService: Startup - APRS-BLE frequency/probe match, no sync needed", category: .service, level: .debug)
            return
        }

        appLog("FrequencyManagementService: Startup frequency sync needed - creating user proposal", category: .service, level: .info)
        createFrequencySyncProposal(aprsFreq: aprsFreq, aprsProbeType: aprsProbeType, bleFreq: bleFreq, bleProbeType: bleProbeType)
    }

    private func createFrequencySyncProposal(aprsFreq: Double, aprsProbeType: String, bleFreq: Double, bleProbeType: String) {
        // Create proposal for user confirmation
        syncProposal = FrequencySyncProposal(frequency: aprsFreq, probeType: aprsProbeType)

        appLog("FrequencyManagementService: Frequency sync proposal created - APRS: \(String(format: "%.2f", aprsFreq)) MHz \(aprsProbeType) vs BLE: \(String(format: "%.2f", bleFreq)) MHz \(bleProbeType)", category: .service, level: .info)
    }
}
