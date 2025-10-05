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
   - Request user location EARLY so GPS has time to resolve before route calculation.

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

        // Step 1: Service Initialization (already done) + Request user location early
        await MainActor.run {
            currentStartupStep = 1
            startupProgress = "Step 1: Services"
        }

        // Request user location EARLY so it has time to resolve before route calculation
        appLog("STARTUP: Step 1 - Requesting user location (early for route calculation)", category: .general, level: .info)
        currentLocationService.requestCurrentLocation()

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

        // Wait for definitive answers from both services (with timeout)
        await waitForServiceAnswers(maxWaitTime: maxStartupTime - Date().timeIntervalSince(startTime))

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

        appLog("STARTUP: Complete ✅ Control handed to state machine (\(String(format: "%.1f", totalTime))s total)", category: .general, level: .info)
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
    private func waitForServiceAnswers(maxWaitTime: TimeInterval) async {
        let startTime = Date()

        while true {
            let bleAnswered = hasBleProvivedAnswer()
            let aprsAnswered = hasAprsProvidedAnswer()

            if bleAnswered && aprsAnswered {
                appLog("STARTUP: Both services provided definitive answers", category: .general, level: .info)
                return
            }

            // Check if we've exceeded max wait time
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= maxWaitTime {
                appLog("STARTUP: Timeout waiting for services (BLE: \(bleAnswered), APRS: \(aprsAnswered)) - transitioning to noTelemetry state", category: .general, level: .error)
                return
            }

            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second checks
        }
    }

    /// Check if BLE service has provided a definitive answer
    private func hasBleProvivedAnswer() -> Bool {
        // BLE answered if:
        // 1. Bluetooth is off, OR
        // 2. Connected/ready state reached (.readyForCommands or .dataReady), OR
        // 3. Scan timeout occurred (BLE service stopped scanning after 5s timeout)
        let bluetoothOff = bleCommunicationService.centralManager.state != .poweredOn
        let connected = bleCommunicationService.connectionState == .readyForCommands ||
                       bleCommunicationService.connectionState == .dataReady
        let scanTimedOut = bleCommunicationService.scanStartTime != nil &&
                          Date().timeIntervalSince(bleCommunicationService.scanStartTime!) >= bleCommunicationService.scanTimeout

        return bluetoothOff || connected || scanTimedOut
    }

    /// Check if APRS service has provided a definitive answer (data or error)
    private func hasAprsProvidedAnswer() -> Bool {
        // APRS answered if: has data OR has error
        return balloonPositionService.aprsService.latestPosition != nil ||
               balloonPositionService.aprsService.lastApiError != nil
    }


}
