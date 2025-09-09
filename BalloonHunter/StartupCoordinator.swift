import Foundation
import Combine
import CoreLocation
import OSLog

@MainActor
final class StartupCoordinator: ObservableObject {
    private let serviceManager: ServiceManager
    private var cancellables = Set<AnyCancellable>()
    
    @Published var startupState: StartupState = .initializing
    @Published var startupProgress: String = "Initializing..."
    
    private var hasReceivedFirstTelemetry = false
    private var hasReadDeviceSettings = false
    private var persistenceDataLoaded = false
    
    enum StartupState {
        case initializing
        case connectingBLE
        case waitingForFirstTelemetry
        case readingDeviceSettings
        case loadingPersistenceData
        case callingServices
        case settingUpMap
        case completed
    }
    
    init(serviceManager: ServiceManager) {
        self.serviceManager = serviceManager
        appLog("StartupCoordinator: Initializing startup sequence", category: .service, level: .info)
        startStartupSequence()
    }
    
    private func startStartupSequence() {
        startupState = .connectingBLE
        startupProgress = "Connecting to MySondyGo device..."
        appLog("StartupCoordinator: Step 1 - BLE communication service connecting to device", category: .service, level: .info)
        
        // Step 1: Monitor BLE connection and first telemetry
        serviceManager.bleCommunicationService.$connectionStatus
            .sink { [weak self] status in
                self?.handleBLEConnectionChange(status)
            }
            .store(in: &cancellables)
        
        // Monitor for first telemetry package
        serviceManager.bleCommunicationService.$latestTelemetry
            .compactMap { $0 }
            .sink { [weak self] telemetry in
                self?.handleFirstTelemetry(telemetry)
            }
            .store(in: &cancellables)
        
        // Monitor for device settings
        serviceManager.bleCommunicationService.$deviceSettings
            .sink { [weak self] settings in
                self?.handleDeviceSettings(settings)
            }
            .store(in: &cancellables)
    }
    
    private func handleBLEConnectionChange(_ status: ConnectionStatus) {
        switch status {
        case .connecting:
            startupProgress = "Connecting to MySondyGo..."
        case .connected:
            startupProgress = "Connected! Waiting for first telemetry package..."
            startupState = .waitingForFirstTelemetry
            appLog("StartupCoordinator: BLE connected, waiting for first telemetry", category: .service, level: .info)
        case .disconnected:
            startupProgress = "Disconnected from MySondyGo"
            appLog("StartupCoordinator: BLE disconnected during startup", category: .service, level: .error)
        }
    }
    
    private func handleFirstTelemetry(_ telemetry: TelemetryData) {
        guard !hasReceivedFirstTelemetry else { return }
        hasReceivedFirstTelemetry = true
        
        appLog("StartupCoordinator: Step 2 - First telemetry received for \\(telemetry.sondeName)", category: .service, level: .info)
        startupState = .readingDeviceSettings
        startupProgress = "Reading device settings from MySondyGo..."
        
        // The BLE service automatically issues read settings command after first telemetry
        // We just need to wait for the response
    }
    
    private func handleDeviceSettings(_ settings: DeviceSettings) {
        guard hasReceivedFirstTelemetry && !hasReadDeviceSettings else { return }
        hasReadDeviceSettings = true
        
        appLog("StartupCoordinator: Step 3 - Device settings received and stored locally", category: .service, level: .info)
        startupState = .loadingPersistenceData
        startupProgress = "Loading persistence data..."
        
        // Step 4: Load persistence data
        loadPersistenceData()
    }
    
    private func loadPersistenceData() {
        appLog("StartupCoordinator: Step 4 - Reading persistence data", category: .service, level: .info)
        
        // Prediction parameters (already loaded in PersistenceService init)
        appLog("StartupCoordinator: - Prediction parameters loaded", category: .service, level: .debug)
        
        // Historic track data (will be loaded by BalloonTrackingService when processing telemetry)
        appLog("StartupCoordinator: - Historic track data will be loaded by BalloonTrackingService", category: .service, level: .debug)
        
        // Landing point (will be determined by LandingPointService)
        appLog("StartupCoordinator: - Landing point will be determined by LandingPointService", category: .service, level: .debug)
        
        persistenceDataLoaded = true
        
        // Step 5: Call services if telemetry is available
        if let currentTelemetry = serviceManager.bleCommunicationService.latestTelemetry {
            callRequiredServices(with: currentTelemetry)
        } else {
            appLog("StartupCoordinator: No telemetry available yet for service calls", category: .service, level: .error)
        }
    }
    
    private func callRequiredServices(with telemetry: TelemetryData) {
        startupState = .callingServices
        startupProgress = "Calling balloon prediction and routing services..."
        
        appLog("StartupCoordinator: Step 5 - Telemetry available, calling required services", category: .service, level: .info)
        
        Task {
            // Step 5a: Call balloon prediction service
            appLog("StartupCoordinator: - Calling balloon prediction service", category: .service, level: .info)
            if let userSettings = serviceManager.persistenceService.readPredictionParameters() {
                await serviceManager.predictionService.fetchPrediction(
                    telemetry: telemetry,
                    userSettings: userSettings,
                    measuredDescentRate: abs(serviceManager.balloonTrackingService.currentEffectiveDescentRate ?? userSettings.descentRate),
                    version: 0
                )
            }
            
            // Step 5b: Call landing point service
            appLog("StartupCoordinator: - Calling landing point service", category: .service, level: .info)
            // Landing point service is called automatically through Combine subscriptions
            
            // Step 5c: Call routing service if we have user location and landing point
            if let userLocationData = serviceManager.currentLocationService.locationData,
               let landingPoint = serviceManager.landingPointService.validLandingPoint {
                appLog("StartupCoordinator: - Calling routing service", category: .service, level: .info)
                serviceManager.routeCalculationService.calculateRoute(
                    from: CLLocationCoordinate2D(latitude: userLocationData.latitude, longitude: userLocationData.longitude),
                    to: landingPoint,
                    transportType: .car,
                    version: 0
                )
            } else {
                appLog("StartupCoordinator: - Cannot call routing service: missing user location or landing point", category: .service, level: .info)
            }
            
            // Step 6: Setup map
            await MainActor.run {
                setupMap()
            }
        }
    }
    
    private func setupMap() {
        startupState = .settingUpMap
        startupProgress = "Setting up map view..."
        
        appLog("StartupCoordinator: Step 6 - Setting up map to show required annotations", category: .service, level: .info)
        
        // The map setup is handled by TrackingMapView
        // We just need to signal that startup is complete
        completeStartup()
    }
    
    private func completeStartup() {
        startupState = .completed
        startupProgress = "Startup completed!"
        
        appLog("StartupCoordinator: Startup sequence completed successfully", category: .service, level: .info)
        
        // Notify that startup is complete
        NotificationCenter.default.post(name: .startupCompleted, object: nil)
    }
}

extension Notification.Name {
    static let startupCompleted = Notification.Name("startupCompleted")
}