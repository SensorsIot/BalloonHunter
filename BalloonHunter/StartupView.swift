import SwiftUI
import OSLog
import Combine
import CoreLocation
import MapKit
import CoreBluetooth

struct StartupView: View {
    @EnvironmentObject var balloonTracker: BalloonTracker
    @EnvironmentObject var userSettings: UserSettings
    
    @State private var startupProgress: String = "Initializing..."
    @State private var isInitialized: Bool = false
    @State private var bleConnectionStatus: ConnectionStatus = .disconnected
    @State private var hasReceivedFirstTelemetry: Bool = false

    var body: some View {
        // No visible UI - startup runs silently in background
        Color.clear
            .onAppear {
                Task {
                    await performStartup()
                }
            }
    }
    
    private func performStartup() async {
        guard !isInitialized else { return }
        isInitialized = true
        
        do {
            // Step 1: Load user settings
            startupProgress = "Loading settings..."
            await loadUserSettings()
            
            // Step 2: Initialize services first
            startupProgress = "Initializing services..."
            balloonTracker.initialize()
            
            // Step 3: Setup location services
            startupProgress = "Getting location..."
            try await setupLocationServices()
            
            // Signal location ready - TrackingMapView can now be shown
            NotificationCenter.default.post(name: .locationReady, object: nil)
            appLog("StartupView: Location ready, TrackingMapView should now appear", category: .general, level: .info)
            
            // Continue with background tasks
            // Step 4: Attempt to connect to MySondyGo (non-blocking)
            startupProgress = "Connecting to MySondyGo..."
            await attemptBLEConnection()
            
            // Step 5: Device settings are read automatically by BLE service
            // No need to manually request them here
            
            // Step 6: Load all persistence data
            startupProgress = "Loading saved data..."
            await loadAllPersistenceData()
            
            // Step 7: Process current balloon data if telemetry available
            if balloonTracker.bleCommunicationService.latestTelemetry != nil {
                startupProgress = "Processing balloon data..."
                await processCurrentBalloonData()
            }
            
            // Step 7: Initialize map display to show all annotations
            startupProgress = "Setting up map display..."
            await triggerInitialMapDisplay()
            
            startupProgress = "Ready!"
            
            // Signal startup completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .startupCompleted, object: nil)
            }
            
            // App status summary
            let bleStatus = balloonTracker.bleCommunicationService.connectionStatus == .connected ? "Connected" : "Disconnected"
            let telemetryStatus = balloonTracker.mapState.balloonTelemetry != nil ? "Available" : "None"
            let locationStatus = balloonTracker.mapState.userLocation != nil ? "Available" : "None"
            let trackCount = balloonTracker.balloonTrackService.currentBalloonTrack.count
            let currentSonde = balloonTracker.balloonTrackService.currentBalloonName ?? "None"
            let historicTrack = trackCount > 0 ? "Yes (\(trackCount) pts)" : "None"
            
            // Landing point status
            let landingPointStatus = if let landingPoint = balloonTracker.mapState.landingPoint {
                "Yes (\(String(format: "%.4f", landingPoint.latitude)), \(String(format: "%.4f", landingPoint.longitude)))"
            } else {
                "None"
            }
            
            // Prediction parameters from UserSettings
            let burstAlt = Int(userSettings.burstAltitude)
            let ascentRate = userSettings.ascentRate
            let descentRate = userSettings.descentRate
            
            // Also show landing point from service before startup completes
            let serviceLandingPoint = if let serviceLP = balloonTracker.landingPointService.validLandingPoint {
                "Service: Yes (\(String(format: "%.4f", serviceLP.latitude)), \(String(format: "%.4f", serviceLP.longitude)))"
            } else {
                "Service: None"
            }
            
            appLog("🚀 BalloonHunter Ready - BLE: \(bleStatus), Telemetry: \(telemetryStatus), Location: \(locationStatus)", category: .general, level: .info)
            appLog("📍 Track Status - Sonde: \(currentSonde), Historic track: \(historicTrack)", category: .general, level: .info)
            appLog("🎯 Landing Points - MapState: \(landingPointStatus), \(serviceLandingPoint)", category: .general, level: .info)
            appLog("⚙️ Prediction Params - Burst: \(burstAlt)m, Ascent: \(ascentRate)m/s, Descent: \(descentRate)m/s", category: .general, level: .info)
            
        } catch {
            startupProgress = "Startup failed: \(error.localizedDescription)"
            appLog("StartupView: Startup failed with error: \(error)", category: .general, level: .error)
            
            // Retry after delay
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            await performStartup()
        }
    }
    
    private func loadUserSettings() async {
        // Load persisted prediction parameters into user settings
        if let persisted = balloonTracker.persistenceService.readPredictionParameters() {
            await MainActor.run {
                userSettings.burstAltitude = persisted.burstAltitude
                userSettings.ascentRate = persisted.ascentRate
                userSettings.descentRate = persisted.descentRate
            }
        }
        appLog("StartupView: Settings loaded", category: .general, level: .debug)
    }
    
    private func attemptBLEConnection() async {
        // Wait for Bluetooth to be powered on first
        let bluetoothTimeout = Date().addingTimeInterval(10) // 10 seconds timeout for Bluetooth
        while balloonTracker.bleCommunicationService.centralManager.state != .poweredOn && Date() < bluetoothTimeout {
            appLog("StartupView: Waiting for Bluetooth to power on", category: .general, level: .info)
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second check interval
        }
        
        guard balloonTracker.bleCommunicationService.centralManager.state == .poweredOn else {
            appLog("StartupView: Bluetooth not powered on, publishing telemetry unavailable and continuing startup", category: .general, level: .error)
            // Publish telemetry unavailable event and continue
            EventBus.shared.publishTelemetryAvailability(TelemetryAvailabilityEvent(
                isAvailable: false,
                reason: "Bluetooth not powered on"
            ))
            return
        }
        
        appLog("StartupView: Bluetooth powered on, starting scan", category: .general, level: .info)
        
        // Show "no RadiosondyGo detected" message
        startupProgress = "No RadiosondyGo detected"
        
        // Now start BLE scanning
        balloonTracker.bleCommunicationService.startScanning()
        
        // Wait for BLE connection (with 5 second timeout)
        let connectionTimeout = Date().addingTimeInterval(5) // 5 seconds timeout
        while bleConnectionStatus != .connected && Date() < connectionTimeout {
            await observeBLEConnectionStatus()
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second check interval
        }
        
        if bleConnectionStatus == .connected {
            appLog("StartupView: BLE connection established", category: .general, level: .info)
            
            // Update message when device is connected
            startupProgress = "RadiosondyGo connected, waiting for data..."
            
            // Wait for first telemetry (with timeout)
            let telemetryTimeout = Date().addingTimeInterval(10) // 10 seconds timeout
            while !hasReceivedFirstTelemetry && Date() < telemetryTimeout {
                await observeFirstTelemetry()
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second check interval
            }
            
            if hasReceivedFirstTelemetry {
                appLog("StartupView: First telemetry received", category: .general, level: .info)
            } else {
                appLog("StartupView: No telemetry received, but continuing startup", category: .general, level: .info)
                // Note: BLE service will publish telemetry availability event when first packet is processed
            }
        } else {
            appLog("StartupView: No device connected within 5 seconds, publishing telemetry unavailable and continuing startup", category: .general, level: .info)
            // Publish telemetry unavailable event and continue
            EventBus.shared.publishTelemetryAvailability(TelemetryAvailabilityEvent(
                isAvailable: false,
                reason: "No RadiosondyGo device found within 5 seconds"
            ))
            // BLE service continues trying to connect in background
        }
    }
    
    private func observeBLEConnectionStatus() async {
        await MainActor.run {
            bleConnectionStatus = balloonTracker.bleCommunicationService.connectionStatus
        }
    }
    
    private func observeFirstTelemetry() async {
        await MainActor.run {
            if balloonTracker.bleCommunicationService.latestTelemetry != nil {
                hasReceivedFirstTelemetry = true
            }
        }
    }
    
    // requestDeviceSettings removed - BLE service handles this automatically
    
    private func setupLocationServices() async throws {
        // Start location services - UI will handle initial region setting
        await MainActor.run {
            balloonTracker.currentLocationService.requestPermission()
            balloonTracker.currentLocationService.startUpdating()
        }
        
        // Wait for initial location (with timeout)
        let locationTimeout = Date().addingTimeInterval(10) // 10 seconds timeout
        var hasLocation = false
        
        while !hasLocation && Date() < locationTimeout {
            await MainActor.run {
                if balloonTracker.currentLocationService.locationData != nil {
                    hasLocation = true
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second check interval
        }
        
        guard hasLocation else {
            appLog("StartupView: Location timeout, continuing without location", category: .general, level: .error)
            throw StartupError.locationTimeout
        }
        
        appLog("StartupView: Initial location obtained, UI will handle map initialization", category: .general, level: .info)
    }
    
    private func loadAllPersistenceData() async {
        // This will be handled by individual services as they initialize
        // Track history will be loaded by BalloonTrackService
        // Landing points will be loaded by LandingPointService
        // Prediction parameters already loaded in loadUserSettings()
        
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds for data loading
        appLog("StartupView: Persistence data loading triggered", category: .general, level: .debug)
    }
    
    private func processCurrentBalloonData() async {
        guard let telemetry = balloonTracker.bleCommunicationService.latestTelemetry else {
            appLog("StartupView: No telemetry available for balloon data processing", category: .general, level: .debug)
            return
        }
        
        appLog("StartupView: Processing balloon data - lat: \(telemetry.latitude), lon: \(telemetry.longitude), alt: \(telemetry.altitude)m", category: .general, level: .info)
        
        // Get current balloon position from telemetry
        let balloonPosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
        
        // Step 7a: Call balloon prediction service
        startupProgress = "Calculating balloon prediction..."
        await callBalloonPredictionService(telemetry: telemetry)
        
        // Step 7b: Call routing service if user location is available
        if let userLocation = balloonTracker.currentLocationService.locationData {
            startupProgress = "Calculating route..."
            await callRoutingService(userLocation: userLocation, balloonPosition: balloonPosition)
        }
        
        // Step 7c: Call landing point service
        startupProgress = "Determining landing point..."
        await callLandingPointService()
        
        appLog("StartupView: Balloon data processing completed", category: .general, level: .info)
    }
    
    private func callBalloonPredictionService(telemetry: TelemetryData) async {
        // Use the event-driven prediction policy to trigger prediction
        await MainActor.run {
            // Force prediction by publishing telemetry event
            EventBus.shared.publishTelemetry(TelemetryEvent(telemetryData: telemetry))
        }
        
        // Wait for prediction to complete (reasonable timeout)
        let timeout = Date().addingTimeInterval(10) // 10 seconds timeout
        while await balloonTracker.predictionCache.getStats()["totalEntries"] as? Int == 0 && Date() < timeout {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second intervals
        }
        
        appLog("StartupView: Balloon prediction service completed", category: .general, level: .debug)
    }
    
    private func callRoutingService(userLocation: LocationData, balloonPosition: CLLocationCoordinate2D) async {
        // Use the routing policy to trigger route calculation
        await MainActor.run {
            let _ = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)  // userCoordinate
            // Trigger routing by publishing location events
            EventBus.shared.publishUserLocation(UserLocationEvent(
                locationData: userLocation
            ))
        }
        
        // Wait for routing to complete (reasonable timeout)  
        let timeout = Date().addingTimeInterval(10) // 10 seconds timeout
        while await balloonTracker.routingCache.getStats()["totalEntries"] as? Int == 0 && Date() < timeout {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second intervals
        }
        
        appLog("StartupView: Routing service completed", category: .general, level: .debug)
    }
    
    private func callLandingPointService() async {
        // The landing point service is automatically triggered by the prediction policy
        // through the event-driven architecture, so we just wait for it to process
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second for processing
        
        appLog("StartupView: Landing point service completed", category: .general, level: .debug)
    }
    
    private func triggerInitialMapDisplay() async {
        // Trigger show all annotations to fit all data on screen
        await MainActor.run {
            EventBus.shared.publishUIEvent(.showAllAnnotationsRequested(timestamp: Date()))
        }
        
        // Give the event time to process
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        appLog("StartupView: Initial map display triggered to show all annotations with appropriate zoom", category: .general, level: .debug)
    }
}

enum StartupError: LocalizedError {
    case bleConnectionTimeout
    case firstTelemetryTimeout
    case locationTimeout
    
    var errorDescription: String? {
        switch self {
        case .bleConnectionTimeout:
            return "Could not connect to MySondyGo device"
        case .firstTelemetryTimeout:
            return "No telemetry data received from device"
        case .locationTimeout:
            return "Could not determine location"
        }
    }
}
