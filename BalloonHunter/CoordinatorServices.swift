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
        async let aprsResult = primeAPRSStartupData()

        let _ = await bleResult
        let _ = await aprsResult
        appLog("STARTUP: Step 2 - BLE connection and APRS priming complete", category: .general, level: .info)

        // Step 3: First Telemetry Package
        await MainActor.run {
            currentStartupStep = 3
            startupProgress = "Step 3: Telemetry"
        }
        await waitForFirstBLEPackageAndPublishTelemetryStatus()
        appLog("STARTUP: Step 3 - First telemetry package processed", category: .general, level: .info)

        // Step 4: Persistence Data
        await MainActor.run {
            currentStartupStep = 4
            startupProgress = "Step 4: Data"
        }
        await loadAllPersistenceData()
        appLog("STARTUP: Step 4 - Persistence data loaded", category: .general, level: .info)

        // Step 5: Landing Point (APRS data available from parallel Step 2)
        await MainActor.run {
            currentStartupStep = 5
            startupProgress = "Step 5: Landing Point"
        }
        appLog("STARTUP: Step 5 - Landing point provided by BalloonTrackService/persistence", category: .general, level: .info)

        // Step 6: Final Map Display
        await MainActor.run {
            currentStartupStep = 6
            startupProgress = "Step 6: Map Display"
        }
        await setupInitialMapDisplay()
        appLog("STARTUP: Step 6 - Final map display complete", category: .general, level: .info)

        // Mark startup as complete
        let totalTime = Date().timeIntervalSince(startTime)
        await MainActor.run {
            isStartupComplete = true
            showLogo = false
            showTrackingMap = true
        }

        appLog("STARTUP: Complete ✅ Ready for tracking (\(String(format: "%.1f", totalTime))s total)", category: .general, level: .info)
    }
    
    // MARK: - Startup Step Execution Helper (removed - using consolidated logging)
    
    // MARK: - Step 2: BLE Connection
    
    private func startBLEConnectionWithTimeout() async -> (connected: Bool, hasMessage: Bool) {
        // Step 2: Starting BLE connection (log removed)
        
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
        while !bleCommunicationService.isReadyForCommands && Date() < connectionTimeout {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second checks
        }
        
        if bleCommunicationService.isReadyForCommands {
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

    /// Prime APRS startup data (Step 2 of startup sequence)
    private func primeAPRSStartupData() async {
        appLog("STARTUP: Step 2 - Priming APRS startup data", category: .general, level: .info)

        // Access APRS service through BalloonPositionService
        await balloonPositionService.aprsService.primeStartupData()

        appLog("STARTUP: Step 2 - APRS startup priming complete", category: .general, level: .info)
    }

}
