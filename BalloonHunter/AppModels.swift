// AppModels.swift
// Contains all model structs, enums, and lightweight ObservableObjects used throughout the app.

import Foundation
import Combine

// MARK: - Settings model (was Settings.swift)

struct Settings {
    var sondeType: Int
    var frequency: Double
    var oledSDA: Int
    var oledSCL: Int
    var oledRST: Int
    var ledPin: Int
    var buzPin: Int
    var lcdType: Int
    var batPin: Int
    var batMin: Int
    var batMax: Int
    var batType: Int
    var callSign: String
    var rs41Bandwidth: Int
    var m20Bandwidth: Int
    var m10Bandwidth: Int
    var pilotBandwidth: Int
    var dfmBandwidth: Int
    var frequencyCorrection: String
    var lcdStatus: Int
    var bluetoothStatus: Int
    var serialSpeed: Int
    var serialPort: Int
    var aprsName: Int
    var threshold: Double = 0.5
    var isEnabled: Bool = true
    var darkMode: Bool = false
    var deviceName: String = ""

    static var `default`: Settings {
        Settings(
            sondeType: 1,
            frequency: 404.600,
            oledSDA: 21,
            oledSCL: 22,
            oledRST: 16,
            ledPin: 25,
            buzPin: 0,
            lcdType: 0,
            batPin: 35,
            batMin: 2950,
            batMax: 4180,
            batType: 1,
            callSign: "MYCALL",
            rs41Bandwidth: 4,
            m20Bandwidth: 7,
            m10Bandwidth: 7,
            pilotBandwidth: 7,
            dfmBandwidth: 6,
            frequencyCorrection: "0",
            lcdStatus: 1,
            bluetoothStatus: 1,
            serialSpeed: 1,
            serialPort: 0,
            aprsName: 0,
            threshold: 0.5,
            isEnabled: true,
            darkMode: false,
            deviceName: ""
        )
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var settings: Settings = Settings.default
    private init() {}
    func update(_ newSettings: Settings) {
        settings = newSettings
    }
}

// MARK: - PredictionInfo model (was PredictionInfo.swift)

class PredictionInfo: ObservableObject {
    @Published var landingTime: Date? = nil
    @Published var arrivalTime: Date? = nil
    @Published var routeDistanceMeters: Double? = nil
}
