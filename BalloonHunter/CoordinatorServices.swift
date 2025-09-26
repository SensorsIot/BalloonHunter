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

        // Step 1: Service Initialization (already done)
        await MainActor.run {
            currentStartupStep = 1
            startupProgress = "Step 1: Services"
        }
        appLog("STARTUP: Step 1 - Service initialization complete", category: .general, level: .info)

        // Step 2: BLE Connection + APRS Priming (parallel with timeout)
        await MainActor.run {
            currentStartupStep = 2
            startupProgress = "Step 2: BLE & APRS"
        }
        async let bleResult = startBLEConnectionWithTimeout()
        async let aprsTask: Void = primeAPRSStartupData()

        let _ = await bleResult
        await aprsTask
        appLog("STARTUP: Step 2 - BLE connection and APRS priming complete", category: .general, level: .info)

        // Step 3: First Telemetry Package
        await MainActor.run {
            currentStartupStep = 3
            startupProgress = "Step 3: Telemetry"
        }
        await waitForFirstBLEPackageAndPublishTelemetryStatus()
        appLog("STARTUP: Step 3 - First telemetry package processed", category: .general, level: .info)

        // Step 4: Wait for APRS data and complete state machine startup
        await MainActor.run {
            currentStartupStep = 4
            startupProgress = "Step 4: State Machine"
        }
        await waitForInitialAPRSData()
        appLog("STARTUP: Step 4 - Starting state machine with BLE and APRS sources evaluated", category: .general, level: .info)
        balloonPositionService.completeStartup()
        appLog("STARTUP: Step 4 - State machine startup complete", category: .general, level: .info)

        // Step 5: Persistence Data
        await MainActor.run {
            currentStartupStep = 5
            startupProgress = "Step 5: Data"
        }
        await loadAllPersistenceData()
        appLog("STARTUP: Step 5 - Persistence data loaded", category: .general, level: .info)

        // Step 6: Landing Point (state machine now provides landing detection)
        await MainActor.run {
            currentStartupStep = 6
            startupProgress = "Step 6: Landing Point"
        }
        appLog("STARTUP: Step 6 - Landing point determined by state machine", category: .general, level: .info)

        // Step 7: Final Map Display
        await MainActor.run {
            currentStartupStep = 7
            startupProgress = "Step 7: Map Display"
        }
        await setupInitialMapDisplay()
        appLog("STARTUP: Step 7 - Final map display complete", category: .general, level: .info)

        // Mark startup as complete (automatic frequency sync now handled by BalloonPositionService)
        let totalTime = Date().timeIntervalSince(startTime)
        await MainActor.run {
            isStartupComplete = true
            showLogo = false
            showTrackingMap = true
        }

        // Brief delay to ensure map is ready before triggering zoom
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds

        // Trigger final map zoom to show all overlays
        triggerStartupMapZoom()

        appLog("STARTUP: Complete ✅ Ready for tracking (\(String(format: "%.1f", totalTime))s total)", category: .general, level: .info)
    }
    
    
    // MARK: - Step 2: BLE Connection
    
    private func startBLEConnectionWithTimeout() async -> (connected: Bool, hasMessage: Bool) {
        
        // Wait for Bluetooth to be powered on (reasonable timeout)
        let bluetoothTimeout = Date().addingTimeInterval(5) // 5 seconds for Bluetooth
        while bleCommunicationService.centralManager.state != .poweredOn && Date() < bluetoothTimeout {
            appLog("Step 2: Waiting for Bluetooth to power on", category: .general, level: .info)
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second check interval
        }
        
        guard bleCommunicationService.centralManager.state == .poweredOn else {
            appLog("Step 2: Bluetooth not powered on - proceeding without connection", category: .general, level: .info)
            return (connected: false, hasMessage: false)
        }
        
        // Start scanning for MySondyGo devices
        bleCommunicationService.startScanning()
        
        // Try to establish connection with 5-second timeout
        let connectionTimeout = Date().addingTimeInterval(5) // 5 seconds to find and connect
        while !bleCommunicationService.telemetryState.canReceiveCommands && Date() < connectionTimeout {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second checks
        }
        
        if bleCommunicationService.telemetryState.canReceiveCommands {
            // BLE connection established
            return (connected: true, hasMessage: true)
        } else {
            appLog("Step 2: No BLE connection established within timeout", category: .general, level: .info)
            return (connected: false, hasMessage: false)
        }
    }

    // MARK: - Step 3: First Telemetry Package

    private func waitForFirstBLEPackageAndPublishTelemetryStatus() async {
        // Step 3: Waiting for first BLE package (log removed)
        
        // Wait up to 3 seconds for the first BLE message of any type
        let timeout = Date().addingTimeInterval(3)
        var hasReceivedFirstMessage = false
        
        while Date() < timeout && !hasReceivedFirstMessage {
            // Check if we've received any BLE messages (Type 0, 1, 2, or 3)
            if bleCommunicationService.latestTelemetry != nil || 
               !bleCommunicationService.deviceSettings.probeType.isEmpty ||
               bleCommunicationService.deviceSettings.frequency != 434.0 {
                hasReceivedFirstMessage = true
                
                // Publish telemetry availability status
                let _ = bleCommunicationService.latestTelemetry != nil
                // First BLE package received
                break
            }
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second checks
        }
        
        if !hasReceivedFirstMessage {
            appLog("Step 3: No BLE package received within timeout", category: .general, level: .info)
        }
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

        appLog("🔍 ZOOM: TrackingMap displayed - will auto-trigger showAnnotations when ready", category: .general, level: .info)

        // TrackingMapView will call updateCameraToShowAllAnnotations() when map camera initializes
    }

    /// Start APRS service immediately during startup (Step 2 of startup sequence)
    private func primeAPRSStartupData() async {
        appLog("STARTUP: Step 2 - Starting APRS service for immediate telemetry", category: .general, level: .info)

        // Start APRS polling immediately - no separate priming step
        balloonPositionService.aprsService.startPolling()

        appLog("STARTUP: Step 2 - APRS service started (will wait for data before state machine)", category: .general, level: .info)
    }

    /// Wait for initial APRS data before completing state machine startup
    private func waitForInitialAPRSData() async {
        appLog("STARTUP: Waiting for initial APRS data before state machine completion", category: .general, level: .info)

        // Wait up to 3 seconds for first APRS data to arrive
        let timeout = Date().addingTimeInterval(3.0)

        while Date() < timeout {
            // Check if APRS has provided any telemetry data
            if balloonPositionService.aprsService.latestTelemetry != nil {
                appLog("STARTUP: Initial APRS data received - proceeding with state machine", category: .general, level: .info)
                return
            }

            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second checks
        }

        appLog("STARTUP: No APRS data within timeout - proceeding with state machine", category: .general, level: .info)
    }


}
