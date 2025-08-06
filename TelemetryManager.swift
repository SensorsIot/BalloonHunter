// TelemetryManager.swift
// Centralizes all telemetry collection, history, and publishing.

import Foundation
import Combine

final class TelemetryManager: ObservableObject {
    static let shared = TelemetryManager()
    
    @Published private(set) var latestTelemetry: Telemetry?
    @Published private(set) var telemetryHistory: [Telemetry] = []
    @Published private(set) var validSignalReceived: Bool = false
    @Published private(set) var signalStrength: Double? = nil
    
    private let maxHistoryLength = 100
    
    private init() {}
    
    /// Called by BLEManager when a new telemetry is received
    func receiveTelemetry(_ telemetry: Telemetry, signalStrength: Double? = nil, validSignal: Bool = false) {
        latestTelemetry = telemetry
        if telemetryHistory.last != telemetry {
            telemetryHistory.append(telemetry)
            if telemetryHistory.count > maxHistoryLength {
                telemetryHistory.removeFirst(telemetryHistory.count - maxHistoryLength)
            }
        }
        self.signalStrength = signalStrength
        self.validSignalReceived = validSignal
    }

    func clearHistory() {
        telemetryHistory.removeAll()
    }
}
