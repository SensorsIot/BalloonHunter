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
extension ServiceCoordinator {
    
    /// Performs the complete 8-step startup sequence as defined in FSD
    func performCompleteStartupSequence() async {
        let startTime = Date()
        
        // Phase 1: Steps 1-3 (Services → Location → Map)
        let phase1Start = Date()
        await MainActor.run { 
            currentStartupStep = 1
            startupProgress = "1-3. Services & Location" 
        }
        
        // Step 1: Service Initialization (already done)
        // Step 2: Location Services Activation
        await activateLocationServices()
        // Step 3: Initial Map Display  
        await setupInitialMapView()
        
        let phase1Time = Date().timeIntervalSince(phase1Start)
        appLog("STARTUP: Steps 1-3 ✅ Services → Location → Map (\(String(format: "%.1f", phase1Time))s)", category: .general, level: .info)
        
        // Phase 2: Steps 4-6 (BLE Connect → Telemetry → Settings)
        let phase2Start = Date()
        await MainActor.run { 
            currentStartupStep = 4
            startupProgress = "4-6. BLE & Data" 
        }
        
        // Step 4: BLE Connection
        let _ = await startBLEConnectionWithTimeout()
        // Step 5: First Telemetry Package
        await waitForFirstBLEPackageAndPublishTelemetryStatus()
        // Step 6: Device Settings
        await waitForSettingsResponse()
        
        let phase2Time = Date().timeIntervalSince(phase2Start)
        appLog("STARTUP: Steps 4-6 ✅ BLE Connect → Telemetry → Settings (\(String(format: "%.1f", phase2Time))s)", category: .general, level: .info)
        
        // Phase 3: Steps 7-8 (Persistence → Landing Point)
        let phase3Start = Date()
        await MainActor.run { 
            currentStartupStep = 7
            startupProgress = "7-8. Data & Display" 
        }
        
        // Step 7: Persistence Data
        await loadAllPersistenceData()
        // Step 8: Landing Point & Final Display
        await determineLandingPointWithPriorities()
        await setupInitialMapDisplay()
        
        let phase3Time = Date().timeIntervalSince(phase3Start)
        appLog("STARTUP: Steps 7-8 ✅ Persistence → Landing Point (\(String(format: "%.1f", phase3Time))s)", category: .general, level: .info)
        
        // Mark startup as complete
        let totalTime = Date().timeIntervalSince(startTime)
        await MainActor.run {
            currentStartupStep = 8
            startupProgress = "Startup Complete"
            isStartupComplete = true
            showLogo = false
            showTrackingMap = true
        }
        
        appLog("STARTUP: Complete ✅ Ready for tracking (\(String(format: "%.1f", totalTime))s total)", category: .general, level: .info)
    }
    
    // MARK: - Startup Step Execution Helper (removed - using consolidated logging)
    
    // MARK: - Step 2: Location Services Activation
    
    private func activateLocationServices() async {
        // Wait briefly for location service to initialize
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        if let userLoc = userLocation {
            // Set 25km zoom around user position
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: userLoc.latitude, longitude: userLoc.longitude),
                latitudinalMeters: 25000,
                longitudinalMeters: 25000
            )
            await MainActor.run {
                self.region = region
            }
        }
    }
    
    // MARK: - Step 3: Initial Map Display
    
    private func setupInitialMapView() async {
        await MainActor.run {
            showTrackingMap = true
        }
        
        // Wait for UI to update
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
    }
    
    // MARK: - Step 4: BLE Connection
    
    private func startBLEConnectionWithTimeout() async -> (connected: Bool, hasMessage: Bool) {
        // Step 4: Starting BLE connection (log removed)
        
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
            appLog("Step 4: No BLE connection established within timeout", category: .general, level: .info)
            return (connected: false, hasMessage: false)
        }
    }
    
    // MARK: - Step 5: First Telemetry Package
    
    private func waitForFirstBLEPackageAndPublishTelemetryStatus() async {
        // Step 5: Waiting for first BLE package (log removed)
        
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
            appLog("Step 5: No BLE package received within timeout", category: .general, level: .info)
        }
    }
    
    // MARK: - Step 6: Device Settings
    
    private func waitForSettingsResponse() async {
        // Step 6: Requesting device settings (log removed)
        
        // Issue settings command
        bleCommunicationService.getParameters()
        
        let initialDeviceSettings = bleCommunicationService.deviceSettings
        let timeout = Date().addingTimeInterval(3) // 3 seconds for settings response
        
        while Date() < timeout {
            // Check if device settings have been updated (different from initial)
            if bleCommunicationService.deviceSettings.frequency != initialDeviceSettings.frequency ||
               !bleCommunicationService.deviceSettings.probeType.isEmpty {
                // Device settings received
                return
            }
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second checks
        }
        
        appLog("Step 6: Settings response timeout - proceeding with defaults", category: .general, level: .info)
    }
    
    // MARK: - Step 7: Persistence Data
    
    func loadAllPersistenceData() async {
        // Step 7: Reading persistence data (log removed)
        
        // Load prediction parameters (already loaded during initialize)
        // Historic track data will be loaded by BalloonTrackService when first telemetry arrives  
        // Landing point loaded from persistence (without clipboard parsing)
        loadPersistenceData()
        
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds for loading
        // Persistence data loading complete
    }
    
    // MARK: - Step 8: Landing Point & Final Display
    
    func determineLandingPointWithPriorities() async {
        // Step 8: Starting landing point determination (log removed)
        
        // Priority 1: If telemetry received and balloon has landed, current position is landing point
        // Priority 1: Check if balloon has landed
        if let telemetry = balloonTelemetry, telemetry.verticalSpeed >= -0.5 && telemetry.altitude < 500 {
            let currentPosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
            await MainActor.run {
                landingPoint = currentPosition
            }
            appLog("Priority 1: SUCCESS - Landing point set from current balloon position (landed)", category: .general, level: .info)
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
        
        // Priority 3: Read and parse from clipboard
        if setLandingPointFromClipboard() {
            appLog("Priority 3: SUCCESS - Landing point set from clipboard", category: .general, level: .info)
            return
        }
        
        // Priority 4: Use persisted landing point
        if let telemetry = balloonTelemetry, !telemetry.sondeName.isEmpty {
            if let persistedLanding = persistenceService.loadLandingPoint(sondeName: telemetry.sondeName) {
                await MainActor.run {
                    landingPoint = persistedLanding
                }
                appLog("Priority 4: SUCCESS - Landing point set from persistence for sonde \(telemetry.sondeName)", category: .general, level: .info)
                return
            }
            appLog("Priority 4: FAILED - No persisted landing point for sonde \(telemetry.sondeName)", category: .general, level: .info)
        } else {
            appLog("Priority 4: FAILED - No sonde name available for persistence lookup", category: .general, level: .info)
        }
        
        // All priorities failed
        appLog("ALL PRIORITIES FAILED - No landing point available", category: .general, level: .info)
        await MainActor.run {
            landingPoint = nil
        }
    }
    
    private func setupInitialMapDisplay() async {
        // Display initial map with all annotations
        
        // Per FSD: Initial map uses maximum zoom level to show:
        // - The user position
        // - The landing position  
        // - If a balloon is flying, the route and predicted path
        triggerShowAllAnnotations()
        
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds for map to update
        // Initial map display complete
    }
}