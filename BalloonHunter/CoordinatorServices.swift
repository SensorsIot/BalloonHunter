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

4) Device Settings (optional, non‑blocking)
   - BLE issues o{?}o opportunistically after the first packet, and SettingsView can also request on demand.
   - Startup does not wait for a settings response; configuration is stored when received and used by settings views.

5) Read Persistence
   - Load from persistence:
     - Prediction parameters
     - Historic track data
     - Landing point (if available)

6) Landing Point Determination (per FSD - 2 priorities only)
   - Prio 1: If telemetry is received and the balloon is landed, set landing point to current balloon position.
   - Prio 2: If balloon is still in flight (telemetry available), use the predicted landing position.
   - Otherwise: No landing point is available.

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
    
    /// Performs the complete 7-step startup sequence as defined in FSD
    func performCompleteStartupSequence() async {
        let startTime = Date()
        
        // Phase 1: Steps 1-2 (Services → BLE)
        let phase1Start = Date()
        await MainActor.run {
            currentStartupStep = 1
            startupProgress = "1-2. Services & BLE"
        }

        // Step 1: Service Initialization (already done)
        // Step 2: BLE Connection
        let _ = await startBLEConnectionWithTimeout()

        let phase1Time = Date().timeIntervalSince(phase1Start)
        appLog("STARTUP: Steps 1-2 ✅ Services → BLE (\(String(format: "%.1f", phase1Time))s)", category: .general, level: .info)

        // Phase 2: Steps 3-5 (Telemetry → Settings → Data)
        let phase2Start = Date()
        await MainActor.run {
            currentStartupStep = 3
            startupProgress = "3-5. Telemetry & Data"
        }

        // Step 3: APRS Startup Priming - call SondeHub API to get latest telemetry data
        await primeAPRSStartupData()
        // Step 4: First Telemetry Package
        await waitForFirstBLEPackageAndPublishTelemetryStatus()
        // Step 5: Device Settings - handled opportunistically by BLE service; no blocking needed
        // Step 6: Persistence Data
        await loadAllPersistenceData()

        let phase2Time = Date().timeIntervalSince(phase2Start)
        appLog("STARTUP: Steps 3-6 ✅ APRS → Telemetry → Settings → Data (\(String(format: "%.1f", phase2Time))s)", category: .general, level: .info)

        // Phase 3: Steps 7-8 (Landing Point → Final Map)
        let phase3Start = Date()
        await MainActor.run {
            currentStartupStep = 7
            startupProgress = "7-8. Landing & Display"
        }

        // Step 7: Landing Point Determination
        appLog("STARTUP: Step 7 - Starting landing point determination", category: .general, level: .info)
        await determineLandingPointWithPriorities()
        appLog("STARTUP: Step 7 - Landing point determination complete", category: .general, level: .info)

        // Step 8: Final Map Display
        appLog("STARTUP: Step 8 - Starting final map display", category: .general, level: .info)
        await setupInitialMapDisplay()
        appLog("STARTUP: Step 8 - Final map display complete", category: .general, level: .info)

        let phase3Time = Date().timeIntervalSince(phase3Start)
        appLog("STARTUP: Steps 7-8 ✅ Landing Point → Final Map (\(String(format: "%.1f", phase3Time))s)", category: .general, level: .info)

        // Mark startup as complete
        let totalTime = Date().timeIntervalSince(startTime)
        await MainActor.run {
            currentStartupStep = 7
            startupProgress = "Startup Complete"
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
            appLog("Step 4: Waiting for Bluetooth to power on", category: .general, level: .info)
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second check interval
        }
        
        guard bleCommunicationService.centralManager.state == .poweredOn else {
            appLog("Step 4: Bluetooth not powered on - proceeding without connection", category: .general, level: .info)
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
    
    func determineLandingPointWithPriorities() async {
        appLog("Landing: Starting landing point determination", category: .general, level: .info)
        if let t = balloonTelemetry {
            let condA = (t.altitude < 1000 && abs(t.verticalSpeed) < 2.0)
            let condB = (t.altitude < 500)
            appLog(String(format: "Landing: Telemetry present: lat=%.5f lon=%.5f alt=%.1f v=%.2f h=%.2f condA=%@ condB=%@",
                          t.latitude, t.longitude, t.altitude, t.verticalSpeed, t.horizontalSpeed,
                          condA ? "true" : "false", condB ? "true" : "false"),
                   category: .general, level: .info)
        } else {
            appLog("Landing: No telemetry available at decision time", category: .general, level: .info)
        }
        
        // Priority 1: If telemetry received and balloon has landed, current position is landing point
        // Priority 1: Check if balloon has landed (improved criteria)
        if let telemetry = balloonTelemetry, 
           (telemetry.altitude < 1000 && abs(telemetry.verticalSpeed) < 2.0) || 
           (telemetry.altitude < 500) {
            let currentPosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
            await MainActor.run {
                landingPoint = currentPosition
            }
            appLog(String(format: "Priority 1: SUCCESS - Landing set from telemetry at %.5f, %.5f (alt=%.1f v=%.2f)",
                          telemetry.latitude, telemetry.longitude, telemetry.altitude, telemetry.verticalSpeed),
                   category: .general, level: .info)
            return
        }
        
        // Priority 2: If balloon in flight, use predicted landing position
        if balloonTelemetry != nil {
                
            // Trigger prediction if needed and wait for result
            await predictionService.triggerManualPrediction()
            
            // Wait up to 10 seconds for prediction to complete
            let predictionTimeout = Date().addingTimeInterval(10)
            while Date() < predictionTimeout {
                if let predictedLanding = predictionData?.landingPoint {
                    await MainActor.run {
                        landingPoint = predictedLanding
                    }
                    appLog("Priority 2: SUCCESS - Landing point set from prediction", category: .general, level: .info)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second checks
            }
            appLog("Priority 2: FAILED - Prediction timeout or no landing point in prediction", category: .general, level: .info)
        } else {
            appLog("Priority 2: Not applicable - no telemetry available", category: .general, level: .info)
        }
        
        // All priorities failed
        appLog("BOTH PRIORITIES FAILED - No landing point available", category: .general, level: .info)
        await MainActor.run {
            landingPoint = nil
        }
    }
    
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

    /// Prime APRS startup data (Step 3 of startup sequence)
    private func primeAPRSStartupData() async {
        appLog("STARTUP: Step 3 - Priming APRS startup data", category: .general, level: .info)

        // Access APRS service through BalloonPositionService
        await balloonPositionService.aprsService.primeStartupData()

        appLog("STARTUP: Step 3 - APRS startup priming complete", category: .general, level: .info)
    }
}
