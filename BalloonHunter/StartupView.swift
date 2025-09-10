import SwiftUI
import OSLog
import Combine
import CoreLocation
import MapKit
import CoreBluetooth

struct StartupView: View {
    @EnvironmentObject var serviceManager: ServiceManager
    @EnvironmentObject var userSettings: UserSettings
    
    @State private var startupProgress: String = "Initializing..."
    @State private var isInitialized: Bool = false
    @State private var bleConnectionStatus: ConnectionStatus = .disconnected
    @State private var hasReceivedFirstTelemetry: Bool = false

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            VStack {
                Text(startupProgress)
                    .font(.headline)
                    .foregroundColor(.white)
            }
        }
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
            serviceManager.initializeEventDrivenFlow()
            
            // Step 3: Connect to MySondyGo and wait for first telemetry
            startupProgress = "Connecting to MySondyGo..."
            try await waitForBLEConnectionAndFirstTelemetry()
            
            // Step 4: Read device settings after first telemetry
            startupProgress = "Reading device settings..."
            await requestDeviceSettings()
            
            // Step 5: Setup location services with 25km zoom
            startupProgress = "Getting location..."
            try await setupLocationWith25kmZoom()
            
            // Step 6: Load all persistence data
            startupProgress = "Loading saved data..."
            await loadAllPersistenceData()
            
            // Step 7: Initial map display setup
            startupProgress = "Setting up initial map view..."
            await triggerInitialMapDisplay()
            
            startupProgress = "Ready!"
            
            // Signal startup completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .startupCompleted, object: nil)
            }
            
            appLog("StartupView: Complete startup sequence finished", category: .general, level: .info)
            
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
        if let persisted = serviceManager.persistenceService.readPredictionParameters() {
            await MainActor.run {
                userSettings.burstAltitude = persisted.burstAltitude
                userSettings.ascentRate = persisted.ascentRate
                userSettings.descentRate = persisted.descentRate
            }
        }
        appLog("StartupView: User settings loaded", category: .general, level: .debug)
    }
    
    private func waitForBLEConnectionAndFirstTelemetry() async throws {
        // Wait for Bluetooth to be powered on first
        let bluetoothTimeout = Date().addingTimeInterval(10) // 10 seconds timeout for Bluetooth
        while serviceManager.bleCommunicationService.centralManager.state != .poweredOn && Date() < bluetoothTimeout {
            appLog("StartupView: Waiting for Bluetooth to power on, current state: \(serviceManager.bleCommunicationService.centralManager.state.rawValue)", category: .general, level: .info)
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second check interval
        }
        
        guard serviceManager.bleCommunicationService.centralManager.state == .poweredOn else {
            appLog("StartupView: Bluetooth not powered on, current state: \(serviceManager.bleCommunicationService.centralManager.state.rawValue)", category: .general, level: .error)
            throw StartupError.bleConnectionTimeout
        }
        
        appLog("StartupView: Bluetooth powered on, starting scan", category: .general, level: .info)
        
        // Now start BLE scanning
        serviceManager.bleCommunicationService.startScanning()
        
        // Wait for BLE connection (with timeout)
        let connectionTimeout = Date().addingTimeInterval(30) // 30 seconds timeout
        while bleConnectionStatus != .connected && Date() < connectionTimeout {
            await observeBLEConnectionStatus()
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second check interval
        }
        
        guard bleConnectionStatus == .connected else {
            throw StartupError.bleConnectionTimeout
        }
        
        appLog("StartupView: BLE connection established", category: .general, level: .info)
        
        // Wait for first telemetry (with timeout)
        let telemetryTimeout = Date().addingTimeInterval(10) // 10 seconds timeout
        while !hasReceivedFirstTelemetry && Date() < telemetryTimeout {
            await observeFirstTelemetry()
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second check interval
        }
        
        guard hasReceivedFirstTelemetry else {
            throw StartupError.firstTelemetryTimeout
        }
        
        appLog("StartupView: First telemetry received", category: .general, level: .info)
    }
    
    private func observeBLEConnectionStatus() async {
        await MainActor.run {
            bleConnectionStatus = serviceManager.bleCommunicationService.connectionStatus
        }
    }
    
    private func observeFirstTelemetry() async {
        await MainActor.run {
            if serviceManager.bleCommunicationService.latestTelemetry != nil {
                hasReceivedFirstTelemetry = true
            }
        }
    }
    
    private func requestDeviceSettings() async {
        // Send settings read command to device
        await MainActor.run {
            serviceManager.bleCommunicationService.readSettings()
        }
        
        // Wait a moment for settings response
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        appLog("StartupView: Device settings read command sent", category: .general, level: .debug)
    }
    
    private func setupLocationWith25kmZoom() async throws {
        // Start location services
        await MainActor.run {
            serviceManager.currentLocationService.requestPermission()
            serviceManager.currentLocationService.startUpdating()
        }
        
        // Wait for initial location (with timeout)
        let locationTimeout = Date().addingTimeInterval(10) // 10 seconds timeout
        var hasLocation = false
        
        while !hasLocation && Date() < locationTimeout {
            await MainActor.run {
                if serviceManager.currentLocationService.locationData != nil {
                    hasLocation = true
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second check interval
        }
        
        guard hasLocation else {
            appLog("StartupView: Location timeout, continuing without location", category: .general, level: .error)
            throw StartupError.locationTimeout
        }
        
        // Set 25km zoom region
        await MainActor.run {
            if let locationData = serviceManager.currentLocationService.locationData {
                let center = CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude)
                let span = MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25) // ~25km span
                let region = MKCoordinateRegion(center: center, span: span)
                
                let update = MapStateUpdate(
                    source: "StartupView",
                    version: 1,
                    region: region
                )
                
                EventBus.shared.publishMapStateUpdate(update)
                appLog("StartupView: Set initial 25km zoom region", category: .general, level: .info)
            }
        }
    }
    
    private func loadAllPersistenceData() async {
        // This will be handled by individual services as they initialize
        // Track history will be loaded by BalloonTrackService
        // Landing points will be loaded by LandingPointService
        // Prediction parameters already loaded in loadUserSettings()
        
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds for data loading
        appLog("StartupView: Persistence data loading triggered", category: .general, level: .debug)
    }
    
    private func triggerInitialMapDisplay() async {
        // Trigger show all annotations to fit all data on screen
        await MainActor.run {
            EventBus.shared.publishUIEvent(.showAllAnnotationsRequested(timestamp: Date()))
        }
        
        appLog("StartupView: Initial map display triggered", category: .general, level: .debug)
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
