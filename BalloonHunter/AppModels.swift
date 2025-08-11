// AppModels.swift
// Core models and state/data representations for the BalloonHunter app

import Foundation
import CoreLocation

// MARK: - TelemetryStruct (for lightweight/decoded telemetry)
public struct TelemetryStruct: Equatable {
    public var probeType: String = ""
    public var frequency: Double = 0.0
    public var sondeName: String = ""
    public var latitude: Double = 0.0
    public var longitude: Double = 0.0
    public var altitude: Double = 0.0
    public var horizontalSpeed: Double = 0.0
    public var verticalSpeed: Double = 0.0
    public var rssi: Double = 0.0
    public var batPercentage: Int = 0
    public var afcFrequency: Int = 0
    public var burstKillerEnabled: Bool = false
    public var burstKillerTime: Int = 0
    public var batVoltage: Int = 0
    public var buzmute: Bool = false
    public var softwareVersion: String = ""
    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension CLLocationCoordinate2D: Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude &&
        lhs.longitude == rhs.longitude
    }
}

import CoreData

// MARK: - Core Data Entities

@objc(DeviceSettingsRecord)
public class DeviceSettingsRecord: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var deviceMode: Int16
    @NSManaged public var sampleRateHz: Double
    @NSManaged public var dateSaved: Date
}

@objc(ForecastSettings)
public class ForecastSettings: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var burstAltitude: Double
    @NSManaged public var ascentRate: Double
    @NSManaged public var descentRate: Double
    @NSManaged public var dateSaved: Date
}

@objc(BalloonTrackPoint)
public class BalloonTrackPoint: NSManagedObject {
    @NSManaged public var latitude: Double
    @NSManaged public var longitude: Double
    @NSManaged public var altitude: Double
    @NSManaged public var timestamp: Date
    @NSManaged public var track: BalloonTrack?
}

@objc(BalloonTrack)
public class BalloonTrack: NSManagedObject {
    @NSManaged public var sondeName: String
    @NSManaged public var dateUpdated: Date
    @NSManaged public var points: Set<BalloonTrackPoint>
}

@objc(MySondyGoSettings)
public class MySondyGoSettings: NSManagedObject {
    @NSManaged public var probeType: String
    @NSManaged public var frequency: Double
    @NSManaged public var oledSDA: Int64
    @NSManaged public var oledSCL: Int64
    @NSManaged public var oledRST: Int64
    @NSManaged public var ledPin: Int64
    @NSManaged public var rs41Bandwidth: Int64
    @NSManaged public var m20Bandwidth: Int64
    @NSManaged public var m10Bandwidth: Int64
    @NSManaged public var pilotBandwidth: Int64
    @NSManaged public var dfmBandwidth: Int64
    @NSManaged public var callSign: String
    @NSManaged public var frequencyCorrection: Int64
    @NSManaged public var batPin: Int64
    @NSManaged public var batMin: Int64
    @NSManaged public var batMax: Int64
    @NSManaged public var batType: Int64
    @NSManaged public var lcdType: Int64
    @NSManaged public var nameType: Int64
    @NSManaged public var buzPin: Int64
    @NSManaged public var softwareVersion: String
    @NSManaged public var dateSaved: Date
}
