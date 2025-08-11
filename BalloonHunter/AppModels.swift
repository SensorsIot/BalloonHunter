// AppModels.swift
// Core models and state/data representations for the BalloonHunter app

import Foundation
import CoreLocation

// MARK: - TelemetryStruct (for lightweight/decoded telemetry)
public struct TelemetryStruct: Equatable {
    public var probeType: String = ""
    public var frequency: Double = 0.0
    public var name: String = ""
    public var latitude: Double = 0.0
    public var longitude: Double = 0.0
    public var altitude: Double = 0.0
    public var horizontalSpeed: Double = 0.0
    public var verticalSpeed: Double = 0.0
    public var signalStrength: Double = 0.0
    public var batteryPercentage: Int = 0
    public var afc: Int = 0
    public var burstKiller: Bool = false
    public var burstKillerTime: Int = 0
    public var batteryVoltage: Int = 0
    public var buzzerMute: Int = 0
    public var firmwareVersion: String = ""
    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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
