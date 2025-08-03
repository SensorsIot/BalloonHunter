// MainViewModel.swift
// ViewModel for MVVM settings architecture

import Foundation
import Combine
import SwiftUI

final class MainViewModel: ObservableObject {
    // The common settings structure, published to trigger UI updates.
    @Published var settings = Settings.default
    @Published var isShowingSondeConfig = false
    @Published var isShowingSettings = false
    
    // Error message for BLE operations, to show user feedback
    @Published var bleError: String? = nil
    
    // Loading state for BLE operations
    @Published var isLoading: Bool = false
    
    // Dedicated manager for BLE communication
    private let bleManager = BLEManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init() {
        // Subscribe to BLEManager's sondeSettings updates and update local settings accordingly
        bleManager.$sondeSettings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sondeSettings in
                print("[DEBUG] sondeSettings: probeType=\(sondeSettings.probeType), frequency=\(sondeSettings.frequency), oledSDA=\(sondeSettings.oledSDA), oledSCL=\(sondeSettings.oledSCL), oledRST=\(sondeSettings.oledRST), ledPin=\(sondeSettings.ledPin), buzPin=\(sondeSettings.buzPin), batPin=\(sondeSettings.batPin), lcdType=\(sondeSettings.lcdType), batMin=\(sondeSettings.batMin), batMax=\(sondeSettings.batMax), batType=\(sondeSettings.batType), callSign=\(sondeSettings.callSign), rs41Bandwidth=\(sondeSettings.rs41Bandwidth), m20Bandwidth=\(sondeSettings.m20Bandwidth), m10Bandwidth=\(sondeSettings.m10Bandwidth), pilotBandwidth=\(sondeSettings.pilotBandwidth), dfmBandwidth=\(sondeSettings.dfmBandwidth), frequencyCorrection=\(sondeSettings.frequencyCorrection), lcdOn=\(sondeSettings.lcdOn), blu=\(sondeSettings.blu), baud=\(sondeSettings.baud), com=\(sondeSettings.com), nameType=\(sondeSettings.nameType)")
                guard let self = self else { return }
                // Only update settings if Sonde config view is NOT being shown
                if !self.isShowingSondeConfig {
                    self.settings = self.convertFromSondeSettings(sondeSettings)
                    self.isLoading = false
                }
            }
            .store(in: &cancellables)
        
        // Optionally, subscribe to BLEManager error publisher (if exists),
        // here assumed to be bleManager.$bleError as a String? for example
        if let bleErrorPublisher = bleManager as? ObservableObject & HasBLEErrorPublisher {
            bleErrorPublisher.bleErrorPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] errorMsg in
                    self?.bleError = errorMsg
                    self?.isLoading = false
                }
                .store(in: &cancellables)
        }
    }
    
    // MARK: - Public Methods
    
    // Function to read settings from device.
    func readSettingsFromDevice() {
        // Clear previous error and indicate loading state
        bleError = nil
        isLoading = true
        
        // Send the '?' command to ask device for its settings
        bleManager.sendCommand("?")
        
        // Parsing and population logic handled by BLEManager updates sondeSettings,
        // which on subscription updates self.settings and clears loading.
    }
    
    // Function to save all settings to the device.
    func saveAllSettingsToDevice() {
        // Clear previous error and indicate loading state
        bleError = nil
        isLoading = true
        
        // Build the BLE command string based on current self.settings
        let command = buildCommandString(from: settings)
        
        // Send the command via BLEManager
        bleManager.sendCommand(command)
        
        // Assume BLEManager updates sondeSettings or signals errors,
        // loading cleared on those subscriptions in init.
    }
    
    // MARK: - Helpers
    
    /// Converts SondeSettings to Settings struct
    private func convertFromSondeSettings(_ sondeSettings: SondeSettings) -> Settings {
        var settings = Settings.default
        // Sonde and Frequency
        settings.sondeType = sondeSettings.probeType
        settings.frequency = sondeSettings.frequency

        // Pins Tab
        settings.oledSDA = Int(sondeSettings.oledSDA) ?? Settings.default.oledSDA // Correct: SDA pin
        settings.oledSCL = Int(sondeSettings.oledSCL) ?? Settings.default.oledSCL // Correct: SCL pin
        settings.oledRST = Int(sondeSettings.oledRST) ?? Settings.default.oledRST // Correct: RST pin
        settings.ledPin = Int(sondeSettings.ledPin) ?? Settings.default.ledPin     // Correct: LED pin
        settings.buzPin = Int(sondeSettings.buzPin) ?? Settings.default.buzPin     // Correct: Buzzer pin
        settings.lcdType = sondeSettings.lcdType                                   // LCD driver type

        // Battery Tab
        settings.batPin = Int(sondeSettings.batPin) ?? Settings.default.batPin     // Battery pin
        settings.batMin = Int(sondeSettings.batMin) ?? Settings.default.batMin     // Battery min mV
        settings.batMax = Int(sondeSettings.batMax) ?? Settings.default.batMax     // Battery max mV
        settings.batType = sondeSettings.batType                                  // Battery type

        // Radio Tab
        settings.callSign = sondeSettings.callSign                                 // MyCall
        settings.rs41Bandwidth = sondeSettings.rs41Bandwidth                      // RS41 bandwidth
        settings.m20Bandwidth = sondeSettings.m20Bandwidth                        // M20 bandwidth
        settings.m10Bandwidth = sondeSettings.m10Bandwidth                        // M10 bandwidth
        settings.pilotBandwidth = sondeSettings.pilotBandwidth                    // PILOT bandwidth
        settings.dfmBandwidth = sondeSettings.dfmBandwidth                        // DFM bandwidth
        settings.frequencyCorrection = sondeSettings.frequencyCorrection          // Correction

        // Others
        settings.lcdStatus = sondeSettings.lcdOn                                   // LCD On/Off
        settings.bluetoothStatus = sondeSettings.blu                              // BLE On/Off
        settings.serialSpeed = sondeSettings.baud                                 // Baud rate
        settings.serialPort = sondeSettings.com                                   // Com port
        settings.aprsName = sondeSettings.nameType                                // APRS name type

        return settings
    }
    
    /// Builds BLE command string from current Settings
    private func buildCommandString(from settings: Settings) -> String {
        // Compose command string that represents all settings according to device protocol
        var commandParts: [String] = []
        
        // Map each setting to a command part string, matching BLE protocol usage
        commandParts.append("sondeType=\(settings.sondeType)")
        commandParts.append("frequency=\(settings.frequency)")

        // Pins Tab
        commandParts.append("oledSDA=\(settings.oledSDA)")
        commandParts.append("oledSCL=\(settings.oledSCL)")
        commandParts.append("oledRST=\(settings.oledRST)")
        commandParts.append("ledPin=\(settings.ledPin)")
        commandParts.append("buzPin=\(settings.buzPin)")
        commandParts.append("lcdType=\(settings.lcdType)")

        // Battery Tab
        commandParts.append("batPin=\(settings.batPin)")
        commandParts.append("batMin=\(settings.batMin)")
        commandParts.append("batMax=\(settings.batMax)")
        commandParts.append("batType=\(settings.batType)")

        // Radio Tab
        commandParts.append("callSign=\(settings.callSign)")
        commandParts.append("rs41Bandwidth=\(settings.rs41Bandwidth)")
        commandParts.append("m20Bandwidth=\(settings.m20Bandwidth)")
        commandParts.append("m10Bandwidth=\(settings.m10Bandwidth)")
        commandParts.append("pilotBandwidth=\(settings.pilotBandwidth)")
        commandParts.append("dfmBandwidth=\(settings.dfmBandwidth)")
        commandParts.append("frequencyCorrection=\(settings.frequencyCorrection)")

        // Others
        commandParts.append("lcdStatus=\(settings.lcdStatus)")
        commandParts.append("bluetoothStatus=\(settings.bluetoothStatus)")
        commandParts.append("serialSpeed=\(settings.serialSpeed)")
        commandParts.append("serialPort=\(settings.serialPort)")
        commandParts.append("aprsName=\(settings.aprsName)")

        // Join all parts with '/' as the BLE command separator
        return commandParts.joined(separator: "/")
    }
}

// Protocol to support BLEManager error publisher subscription (if applicable)
protocol HasBLEErrorPublisher {
    var bleErrorPublisher: AnyPublisher<String?, Never> { get }
}
