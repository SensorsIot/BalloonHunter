import Foundation
import RealmSwift
import CoreLocation

// MARK: - Realm Models

public class DeviceSettingsRecord: Object {
    @Persisted(primaryKey: true) public var id: ObjectId
    @Persisted public var deviceMode: Int
    @Persisted public var sampleRateHz: Double
    @Persisted public var dateSaved: Date = Date()
}

public class ForecastSettings: Object {
    @Persisted(primaryKey: true) public var id: ObjectId
    @Persisted public var burstAltitude: Double
    @Persisted public var ascentRate: Double
    @Persisted public var descentRate: Double
    @Persisted public var dateSaved: Date = Date()
}

public class BalloonTrackPoint: Object {
    @Persisted public var latitude: Double
    @Persisted public var longitude: Double
    @Persisted public var altitude: Double
    @Persisted public var timestamp: Date
}

public class BalloonTrack: Object {
    @Persisted(primaryKey: true) public var sondeName: String
    @Persisted public var points = List<BalloonTrackPoint>()
    @Persisted public var dateUpdated: Date = Date()
}

// MARK: - Service

public class PersistenceService {
    public static let shared = PersistenceService()
    private let realm = try! Realm()

    private init() {
        print("[Persistence] Realm initialized at:\n\(realm.configuration.fileURL?.path ?? "unknown")")
    }

    // Device Settings
    public func saveDeviceSettings(mode: Int, sampleRateHz: Double) {
        let record = DeviceSettingsRecord()
        record.deviceMode = mode
        record.sampleRateHz = sampleRateHz
        try! realm.write {
            realm.add(record)
        }
        print("[Persistence] Saved device settings: mode=\(mode), sampleRateHz=\(sampleRateHz)")
    }
    public func fetchLatestDeviceSettings() -> DeviceSettingsRecord? {
        let res = realm.objects(DeviceSettingsRecord.self).sorted(byKeyPath: "dateSaved", ascending: false).first
        print("[Persistence] Fetched latest device settings: \(String(describing: res))")
        return res
    }

    // Forecast Settings
    public func saveForecastSettings(burstAltitude: Double, ascentRate: Double, descentRate: Double) {
        let fs = ForecastSettings()
        fs.burstAltitude = burstAltitude
        fs.ascentRate = ascentRate
        fs.descentRate = descentRate
        try! realm.write {
            realm.add(fs)
        }
        print("[Persistence] Saved forecast settings: burst=\(burstAltitude) ascent=\(ascentRate) descent=\(descentRate)")
    }
    public func fetchLatestForecastSettings() -> ForecastSettings? {
        let res = realm.objects(ForecastSettings.self).sorted(byKeyPath: "dateSaved", ascending: false).first
        print("[Persistence] Fetched latest forecast settings: \(String(describing: res))")
        return res
    }

    // Balloon Track
    public func addTrackPoint(sondeName: String, point: BalloonTrackPoint) {
        if let track = realm.object(ofType: BalloonTrack.self, forPrimaryKey: sondeName) {
            try! realm.write {
                track.points.append(point)
                track.dateUpdated = Date()
            }
            print("[Persistence] Added point to track for sonde '\(sondeName)': \(point)")
        } else {
            let track = BalloonTrack()
            track.sondeName = sondeName
            track.points.append(point)
            try! realm.write {
                realm.add(track)
            }
            print("[Persistence] Created new track for sonde '\(sondeName)' with first point: \(point)")
        }
    }
    public func fetchTrack(for sondeName: String) -> BalloonTrack? {
        let track = realm.object(ofType: BalloonTrack.self, forPrimaryKey: sondeName)
        print("[Persistence] Fetch track for sonde '\(sondeName)': \(String(describing: track))")
        return track
    }
    public func fetchAllTracks() -> [BalloonTrack] {
        let tracks = Array(realm.objects(BalloonTrack.self))
        print("[Persistence] Fetch all tracks: count=\(tracks.count)")
        return tracks
    }
    public func clearAll() {
        try! realm.write {
            realm.deleteAll()
        }
        print("[Persistence] Cleared all persistence data.")
    }
}

