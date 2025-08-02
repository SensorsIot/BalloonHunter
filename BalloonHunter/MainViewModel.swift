// MainViewModel.swift
// ViewModel for MVVM settings architecture

import Foundation
import SwiftUI

final class MainViewModel: ObservableObject {
    // The common settings structure, published to trigger UI updates.
    @Published var settings = Settings.default
    @Published var isShowingSondeConfig = false
    @Published var isShowingSettings = false
    
    // Dedicated manager for BLE communication
    private let bleManager = BLEManager.shared
    
    // Function to read settings from device.
    func readSettingsFromDevice() {
        // Logic to send the '?' command via BLEManager, and parse the Type 3 message.
        // Will populate self.settings once implemented.
        bleManager.sendCommand("?")
        // Parsing and population logic to be implemented in later refactor steps.
    }
    
    // Function to save all settings to the device.
    func saveAllSettingsToDevice() {
        // Logic to build the BLE command string based on self.settings
        // and send it via bleManager.
        // Will be implemented in a later step.
    }
    
    // Add any additional business logic or helpers as needed.
}
