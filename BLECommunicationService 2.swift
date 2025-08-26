// BLECommunicationService.swift
// Provides BLE communication and publishes telemetry and settings for the app.

import Foundation
import Combine
import SwiftUI

// You can expand this implementation with real BLE logic as needed.
@MainActor
final class BLECommunicationService: ObservableObject {
    // Published properties used throughout the app
    @Published var latestTelemetry: TelemetryData? = nil
    @Published var deviceSettings: DeviceSettings = .default
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var telemetryData = PassthroughSubject<TelemetryData, Never>()

    // Example: Send a command to the BLE device
    func sendCommand(command: String) {
        print("[BLECommunicationService] sendCommand: \(command)")
        // TODO: Implement command sending via BLE
    }
    
    // Example: Simulate receiving telemetry data
    func simulateTelemetry(_ data: TelemetryData) {
        self.latestTelemetry = data
        self.telemetryData.send(data)
    }
}
