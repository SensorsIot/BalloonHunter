import Foundation
import Combine
import CoreLocation

class MainViewModel: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var latestTelemetry: TelemetryStruct? = nil
    @Published var balloonHistory: [CLLocationCoordinate2D] = []
    // BLEManager instance is now created on app start and kept alive for BLE operations
    @Published var bleManager = BLEManager()
    
    @Published var isReadyForCommands: Bool = false
    @Published var forecastSettings: ForecastSettingsModel = .default
    
    // Prevent multiple sends of the settings command
    private var didSendSettingsCommand = false

    init() {
        bleManager.delegate = self
        fetchForecastSettings()
        // BLE auto-connect happens inside BLEManager (already starts scanning)
    }

    private func fetchForecastSettings() {
        Task {
            if let latest = try? await PersistenceService.shared.fetchLatestForecastSettings() {
                await MainActor.run { self.forecastSettings = latest }
            }
        }
    }
    
    /// Starts long range tracking after sending initial settings command
    private func startLongRangeTracking() {
        // This function is called when the device is ready.
        print("[MainViewModel] Long range tracking started.")
    }
}

extension MainViewModel: BLEManagerDelegate {
    func bleManager(_ manager: BLEManager, didUpdateTelemetry telemetry: TelemetryPacket) {
        if !isReadyForCommands {
            isReadyForCommands = true
            if !didSendSettingsCommand {
                didSendSettingsCommand = true
                // Issue o{?}o command to fetch settings from device
                manager.send(data: "o{?}o".data(using: .utf8)!)
                // Start long range tracking if needed
                startLongRangeTracking()
            }
        }
        
        DispatchQueue.main.async {
            self.latestTelemetry = TelemetryStruct(
                probeType: telemetry.probeType,
                frequency: telemetry.frequency,
                sondeName: telemetry.sondeName,
                latitude: telemetry.latitude,
                longitude: telemetry.longitude,
                altitude: telemetry.altitude,
                horizontalSpeed: telemetry.horizontalSpeed,
                verticalSpeed: telemetry.verticalSpeed,
                rssi: telemetry.rssi,
                batPercentage: telemetry.batPercentage,
                afcFrequency: telemetry.afcFrequency,
                burstKillerEnabled: telemetry.burstKillerEnabled,
                burstKillerTime: telemetry.burstKillerTime,
                batVoltage: telemetry.batVoltage,
                buzmute: telemetry.buzmute,
                softwareVersion: telemetry.softwareVersion
            )
            
            let newCoordinate = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
            if self.balloonHistory.last != newCoordinate {
                self.balloonHistory.append(newCoordinate)
            }
        }
    }
    func bleManager(_ manager: BLEManager, didUpdateDeviceSettings settings: BLEDeviceSettingsModel) {
        Task {
            try? await PersistenceService.shared.saveMySondyGoSettings(settings)
        }
    }
    func bleManager(_ manager: BLEManager, didChangeState state: BLEManager.ConnectionState) {
        DispatchQueue.main.async {
            self.isConnected = (state == .connected || state == .ready)
        }
    }
}
