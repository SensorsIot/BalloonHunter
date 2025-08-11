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
        // TODO: Implement long range tracking start logic here
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
        // Existing logic to update latestTelemetry etc.
    }
    func bleManager(_ manager: BLEManager, didUpdateDeviceSettings settings: BLEDeviceSettingsModel) {
        // Device settings received; persist if needed
    }
    func bleManager(_ manager: BLEManager, didChangeState state: BLEManager.ConnectionState) {}
}
