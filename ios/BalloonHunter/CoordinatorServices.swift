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
    
    /// Performs the complete startup sequence (5 steps per FSD)
    func performCompleteStartupSequence() async {
        let startTime = Date()
        let maxStartupTime: TimeInterval = 15.0

        // Step 1: Load Persisted Data
        await MainActor.run {
            currentStartupStep = 1
            startupProgress = "Step 1: Loading Data"
        }
        appLog("STARTUP: Step 1 - Settings only; no sonde data until one is chosen", category: .general, level: .info)

        // `userSettings` is the only thing read here, and it is not sonde-specific.
        // Nothing belonging to a sonde is loaded before selection has said which
        // sonde that would be — see FSD *Startup*. The BLE hunt tail is read later
        // by the context loader, for the serial actually chosen.
        let landingPoints: [LandingPredictionPoint] = []

        // Step 2: Service Initialization (already done in init) + Request location
        await MainActor.run {
            currentStartupStep = 2
            startupProgress = "Step 2: Services"
        }
        appLog("STARTUP: Step 2 - Services initialized, requesting location", category: .general, level: .info)
        currentLocationService.requestCurrentLocation()

        // Step 3: Inject Persisted Data into Services
        await MainActor.run {
            currentStartupStep = 3
            startupProgress = "Step 3: Restoring State"
        }
        appLog("STARTUP: Step 3 - Injecting persisted data into services", category: .general, level: .info)

        // Nothing sonde-specific is injected. Startup must not seed an identity
        // before selection has produced one: the hunted serial is the picker's
        // answer alone, and a name written here would later be mistaken for proof
        // that tracking had been set up. The BLE hunt tail is restored later, by the
        // context loader, for whichever serial is actually chosen.
        landingPointTrackingService.injectPersistedData(landingPoints: landingPoints)

        // Step 4: Start BLE & APRS (gap filling now works on loaded track)
        await MainActor.run {
            currentStartupStep = 4
            startupProgress = "Step 4: BLE & APRS"
        }
        appLog("STARTUP: Step 4 - Starting BLE and APRS services", category: .general, level: .info)

        async let bleResult = startBLEConnectionWithTimeout()
        async let aprsTask: Void = primeAPRSStartupData()

        let (_, _) = await bleResult
        await aprsTask

        // Wait for definitive answers from both services (with timeout)
        await waitForServiceAnswers(maxWaitTime: maxStartupTime - Date().timeIntervalSince(startTime))

        // Step 4b: Check for flying sondes - auto-select if found, otherwise show selection
        await MainActor.run {
            startupProgress = "Step 4: Select Sonde"
        }

        // Get available sondes from APRS service (sorted by datetime, most recent first)
        let sondes = balloonPositionService.aprsService.availableSondes

        // Startup performs no investigation of its own. `LandingDetector` has
        // already judged the sonde whose telemetry arrived, and its verdict is
        // published as `balloonPhase`; startup reads that and nothing else.
        //
        // It used to re-decide from the raw sonde list on vertical speed alone.
        // That is a second implementation of a question the detector owns, and
        // it disagreed: on 21 August 2026 it auto-selected W4214520 from a frame
        // 6.8 h old, 2.4 seconds after the detector had classified that very
        // sonde as landed. The picker never appeared.
        let phase = balloonPositionService.balloonPhase
        let selection = StartupSelection.decide(
            phase: phase,
            trackedSerial: balloonPositionService.currentPositionData?.sondeName)

        appLog("STARTUP: Step 4b - LandingDetector says phase=\(phase) → \(selection)", category: .general, level: .info)

        if case .autoSelect(let flyingSerial) = selection {
            // Airborne - auto-select it, skip the picker. The serial comes from
            // the telemetry the detector judged, so a sonde absent from the
            // SondeHub list (a live decode of an unlisted sonde) still selects.
            let listed = sondes.first { $0.serial == flyingSerial }
            appLog("STARTUP: Step 4b - Flying sonde '\(flyingSerial)'\(listed.map { " at \(Int($0.alt))m" } ?? " (not in SondeHub list)") - auto-selecting", category: .general, level: .info)

            await MainActor.run {
                selectedSondeSerial = flyingSerial
                availableSondesForSelection = sondes
            }

            // Directly confirm the flying sonde selection
            confirmSondeSelection()

        } else if sondes.isEmpty {
            // Nothing to choose from. The picker has no Skip — a hunt always has a
            // hunted sonde — so presenting an empty one would trap the hunter with
            // no way forward. Proceed instead and let the state machine wait: a
            // sonde appears on either feed, or nothing is drawn.
            appLog("STARTUP: Step 4b - No candidates on either feed - nothing to select, waiting for telemetry", category: .general, level: .info)

        } else {
            // No flying sonde - show selection popup
            let ages = sondes.map { s -> String in
                let age = s.lastHeard.map { Int(Date().timeIntervalSince($0) / 60) }
                return "\(s.serial) last heard \(age.map { "\($0)min" } ?? "?") ago"
            }
            appLog("STARTUP: Step 4b - No flying sonde, showing selection popup (\(sondes.count) available: \(ages.joined(separator: ", ")))", category: .general, level: .info)

            await MainActor.run {
                availableSondesForSelection = sondes
                selectedSondeSerial = sondes.first?.serial
                showSondeSelectionPopup = true
            }

            // Wait for the hunter to confirm (5-second auto-confirm on the
            // pre-selected newest). Selection always yields a sonde.
            await waitForSondeSelection()
        }

        // Step 4c: Check frequency sync if BLE is connected
        if bleCommunicationService.connectionState.canReceiveCommands,
           let aprsRadio = balloonPositionService.aprsService.latestRadioChannel {
            appLog("STARTUP: Step 4c - BLE connected, checking frequency sync", category: .general, level: .info)
            checkStartupFrequencySync(aprsRadio: aprsRadio)
        } else {
            appLog("STARTUP: Step 4c - BLE not ready, skipping frequency sync", category: .general, level: .info)
        }

        // Step 4d: Fill whatever the local track is missing, from SondeHub.
        //
        // SondeHub holds the flight; balloontrack.json is only as complete as
        // this device happened to be listening. Anything the app missed - before
        // it was started, while it was closed, or while the receiver was on
        // another sonde - exists there and nowhere else.
        //
        // Unconditional on purpose. Gating this on an empty track meant a hunt
        // that had recorded a couple of minutes was treated as complete, and the
        // rest of the flight stayed missing. The merge only writes into seconds
        // the track has no point for, so live BLE data is never displaced.
        if let hunted = balloonPositionService.currentBalloonName {
            appLog("STARTUP: Step 4d - Reading balloon context for '\(hunted)' from SondeHub (have \(balloonTrackService.currentBalloonTrack.count) points)", category: .general, level: .info)
            Task { [weak balloonTrackService] in await balloonTrackService?.readBalloonContext(serial: hunted) }
        }

        // Step 5: State Machine Handoff & UI Transition
        await MainActor.run {
            currentStartupStep = 5
            startupProgress = "Step 5: Startup Complete"
        }
        appLog("STARTUP: Step 5 - Completing startup and handing control to state machine", category: .general, level: .info)

        balloonPositionService.completeStartup()

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
