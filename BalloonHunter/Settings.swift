// Settings.swift
// Model struct for all app configuration

import Foundation

/// This struct holds all configuration settings for the app.
struct Settings {
    // Sonde and Frequency
    var sondeType: Int
    var frequency: Double

    // Pins Tab
    var oledSDA: Int
    var oledSCL: Int
    var oledRST: Int
    var ledPin: Int
    var buzPin: Int
    var lcdType: Int

    // Battery Tab
    var batPin: Int
    var batMin: Int
    var batMax: Int
    var batType: Int

    // Radio Tab
    var callSign: String
    var rs41Bandwidth: Int
    var m20Bandwidth: Int
    var m10Bandwidth: Int
    var pilotBandwidth: Int
    var dfmBandwidth: Int
    var frequencyCorrection: String

    // Others Tab
    var lcdStatus: Int
    var bluetoothStatus: Int
    var serialSpeed: Int
    var serialPort: Int
    var aprsName: Int

    /// Default settings for the app, matching hardware defaults.
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
            aprsName: 0
        )
    }
}
