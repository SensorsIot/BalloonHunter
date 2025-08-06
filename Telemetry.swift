// Telemetry.swift
// Central class for all telemetry-related functionality (parsing, validation, helpers)

import Foundation
import CoreLocation

class Telemetry: Equatable, CustomStringConvertible {
    let probeType: String
    let frequency: Double
    let name: String
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalSpeed: Double
    let verticalSpeed: Double
    let signalStrength: Double
    let batteryPercentage: Int
    let afc: Int
    let burstKiller: Bool
    let burstKillerTime: Int
    let batteryVoltage: Int
    let buzzerMute: Int
    let firmwareVersion: String

    // MARK: - Initializer
    init(
        probeType: String,
        frequency: Double,
        name: String,
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalSpeed: Double,
        verticalSpeed: Double,
        signalStrength: Double,
        batteryPercentage: Int,
        afc: Int,
        burstKiller: Bool,
        burstKillerTime: Int,
        batteryVoltage: Int,
        buzzerMute: Int,
        firmwareVersion: String
    ) {
        self.probeType = probeType
        self.frequency = frequency
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalSpeed = horizontalSpeed
        self.verticalSpeed = verticalSpeed
        self.signalStrength = signalStrength
        self.batteryPercentage = batteryPercentage
        self.afc = afc
        self.burstKiller = burstKiller
        self.burstKillerTime = burstKillerTime
        self.batteryVoltage = batteryVoltage
        self.buzzerMute = buzzerMute
        self.firmwareVersion = firmwareVersion
    }

    // MARK: - Parsing
    static func parseLongFormat(from components: [Substring]) -> Telemetry? {
        guard components.count >= 21,
            let frequency = Double(components[2]),
            let latitude = Double(components[4]),
            let longitude = Double(components[5]),
            let altitude = Double(components[6]),
            let hSpeed = Double(components[7]),
            let vSpeed = Double(components[8]),
            let signal = Double(components[9]),
            let batteryPercent = Int(components[10]),
            let afc = Int(components[11]),
            let bkTime = Int(components[13]),
            let batteryVoltage = Int(components[14]),
            let buzzerMute = Int(components[18]) else {
            return nil
        }
        return Telemetry(
            probeType: String(components[1]),
            frequency: frequency,
            name: String(components[3]),
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalSpeed: hSpeed,
            verticalSpeed: vSpeed,
            signalStrength: signal,
            batteryPercentage: batteryPercent,
            afc: afc,
            burstKiller: components[12] == "1",
            burstKillerTime: bkTime,
            batteryVoltage: batteryVoltage,
            buzzerMute: buzzerMute,
            firmwareVersion: String(components[19])
        )
    }

    static func parseShortFormat(from components: [Substring]) -> Telemetry? {
        guard components.count >= 8 else { return nil }
        let probeType = String(components[1])
        let frequency = Double(components[2]) ?? 0
        let altitude = Double(components[3]) ?? 0
        let batteryPercentage = Int(components[4]) ?? 0
        let afc = Int(components[5]) ?? 0
        let burstKiller = (components[6] == "1")
        let firmwareVersion = String(components[7])

        return Telemetry(
            probeType: probeType,
            frequency: frequency,
            name: "-",
            latitude: 0,
            longitude: 0,
            altitude: altitude,
            horizontalSpeed: 0,
            verticalSpeed: 0,
            signalStrength: 0,
            batteryPercentage: batteryPercentage,
            afc: afc,
            burstKiller: burstKiller,
            burstKillerTime: 0,
            batteryVoltage: 0,
            buzzerMute: 0,
            firmwareVersion: firmwareVersion
        )
    }

    // MARK: - Equatable
    static func ==(lhs: Telemetry, rhs: Telemetry) -> Bool {
        return lhs.probeType == rhs.probeType &&
            lhs.frequency == rhs.frequency &&
            lhs.name == rhs.name &&
            lhs.latitude == rhs.latitude &&
            lhs.longitude == rhs.longitude &&
            lhs.altitude == rhs.altitude &&
            lhs.horizontalSpeed == rhs.horizontalSpeed &&
            lhs.verticalSpeed == rhs.verticalSpeed &&
            lhs.signalStrength == rhs.signalStrength &&
            lhs.batteryPercentage == rhs.batteryPercentage &&
            lhs.afc == rhs.afc &&
            lhs.burstKiller == rhs.burstKiller &&
            lhs.burstKillerTime == rhs.burstKillerTime &&
            lhs.batteryVoltage == rhs.batteryVoltage &&
            lhs.buzzerMute == rhs.buzzerMute &&
            lhs.firmwareVersion == rhs.firmwareVersion
    }

    // MARK: - Description
    var description: String {
        "Type: \(probeType), Freq: \(frequency), Name: \(name), Lat: \(latitude), Lon: \(longitude), Alt: \(altitude), HSpeed: \(horizontalSpeed), VSpeed: \(verticalSpeed), Signal: \(signalStrength), Batt: \(batteryPercentage)%, AFC: \(afc), BurstKiller: \(burstKiller), BurstKillerTime: \(burstKillerTime), BattVolt: \(batteryVoltage), BuzzerMute: \(buzzerMute), FW: \(firmwareVersion)"
    }

    // MARK: - Utility
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
