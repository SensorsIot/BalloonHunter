import Foundation
import CoreLocation
import CoreData

// MARK: - Transfer Data Types

/// Codable, Equatable struct to represent telemetry for persistence.
public struct TelemetryTransferData: Codable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let signalStrength: Double
    public let batteryPercentage: Int
    public let firmwareVersion: String
    public let timestamp: Date
    // Add further fields as required.
}

/// Codable, Equatable struct to represent sonde settings data.
public struct SondeSettingsTransferData: Codable, Equatable {
    public let sondeType: String
    public let frequency: Double
    public let oledSDA: Int
    public let callSign: String
    public let threshold: Double
    // Add further fields as required.
}

// MARK: - DeviceSettings Entity Struct

/// Struct for device settings matching requirements.
public struct DeviceSettingsModel: Codable, Equatable {
    public let sondeType: String
    public let frequency: Double
    public let oledSDA: Int
    public let callSign: String
    public let threshold: Double
    public let deviceMode: String
    public static let `default` = DeviceSettingsModel(sondeType: "", frequency: 0, oledSDA: 0, callSign: "", threshold: 0, deviceMode: "")
}

// MARK: - Forecast Settings Entity Struct

public struct ForecastSettingsModel: Codable, Equatable {
    public let burstAltitude: Double
    public let ascentRate: Double
    public let descentRate: Double
    public static let `default` = ForecastSettingsModel(burstAltitude: 35000, ascentRate: 5, descentRate: 5)
}

// MARK: - Balloon Track Data Models

public struct TrackPoint: Codable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let timestamp: Date
}
public struct BalloonTrackModel: Codable, Equatable {
    public let sondeName: String
    public let points: [TrackPoint]
    public let dateUpdated: Date
}

public class PersistenceService {
    public static let shared = PersistenceService()
    
    private let container: NSPersistentContainer
    private var context: NSManagedObjectContext { container.viewContext }
    
    private init() {
        container = NSPersistentContainer(name: "BalloonHunterDataModel")
        container.loadPersistentStores { _, error in
            if let error = error {
                print("[PersistenceService] Failed to load persistent stores: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Device Settings

    /// Saves DeviceSettingsModel (all fields) asynchronously.
    public func saveDeviceSettings(_ settings: DeviceSettingsModel) async throws {
        do {
            try await context.perform {
                // TODO: Update Core Data entity "DeviceSettings" to match all struct fields.
                let entity = NSEntityDescription.insertNewObject(forEntityName: "DeviceSettings", into: self.context)
                entity.setValue(settings.sondeType, forKey: "sondeType")
                entity.setValue(settings.frequency, forKey: "frequency")
                entity.setValue(settings.oledSDA, forKey: "oledSDA")
                entity.setValue(settings.callSign, forKey: "callSign")
                entity.setValue(settings.threshold, forKey: "threshold")
                entity.setValue(settings.deviceMode, forKey: "deviceMode") // deviceMode is now a String
                entity.setValue(Date(), forKey: "dateSaved")
            }
            print("[PersistenceService] Saved DeviceSettingsModel: \(settings)")
            print("[DEBUG] Saved DeviceSettings:", settings)
            try await saveContext()
        } catch {
            print("[PersistenceService] Failed to save DeviceSettingsModel: \(error.localizedDescription)")
        }
    }
    /// Fetches the latest DeviceSettingsModel. Returns default if fetch fails or no data found.
    public func fetchLatestDeviceSettings() async throws -> DeviceSettingsModel {
        do {
            return try await context.perform {
                // TODO: Update Core Data fetch to match fields.
                let fetch = NSFetchRequest<NSManagedObject>(entityName: "DeviceSettings")
                fetch.sortDescriptors = [NSSortDescriptor(key: "dateSaved", ascending: false)]
                fetch.fetchLimit = 1
                guard let entity = try? self.context.fetch(fetch).first else {
                    // Return default if fetch fails or no data found
                    let settings = DeviceSettingsModel.default
                    print("[DEBUG] Loaded DeviceSettings:", settings)
                    return settings
                }
                let settings = DeviceSettingsModel(
                    sondeType: entity.value(forKey: "sondeType") as? String ?? "",
                    frequency: entity.value(forKey: "frequency") as? Double ?? 0,
                    oledSDA: entity.value(forKey: "oledSDA") as? Int ?? 0,
                    callSign: entity.value(forKey: "callSign") as? String ?? "",
                    threshold: entity.value(forKey: "threshold") as? Double ?? 0,
                    deviceMode: entity.value(forKey: "deviceMode") as? String ?? "" // deviceMode is String
                )
                print("[DEBUG] Loaded DeviceSettings:", settings)
                return settings
            }
        } catch {
            print("[PersistenceService] Failed to fetch DeviceSettingsModel: \(error.localizedDescription)")
            let settings = DeviceSettingsModel.default
            print("[DEBUG] Loaded DeviceSettings:", settings)
            return settings // Return default on error
        }
    }

    // MARK: - Telemetry Transfer
    /// Saves TelemetryTransferData as a new entity asynchronously.
    public func saveTelemetryTransfer(_ telemetry: TelemetryTransferData) async throws {
        do {
            try await context.perform {
                // TODO: Create Core Data entity "TelemetryTransferData" with all fields.
                let entity = NSEntityDescription.insertNewObject(forEntityName: "TelemetryTransferData", into: self.context)
                entity.setValue(telemetry.latitude, forKey: "latitude")
                entity.setValue(telemetry.longitude, forKey: "longitude")
                entity.setValue(telemetry.altitude, forKey: "altitude")
                entity.setValue(telemetry.signalStrength, forKey: "signalStrength")
                entity.setValue(telemetry.batteryPercentage, forKey: "batteryPercentage")
                entity.setValue(telemetry.firmwareVersion, forKey: "firmwareVersion")
                entity.setValue(telemetry.timestamp, forKey: "timestamp")
            }
            print("[PersistenceService] Saved TelemetryTransferData: \(telemetry)")
            try await saveContext()
        } catch {
            print("[PersistenceService] Failed to save TelemetryTransferData: \(error.localizedDescription)")
        }
    }
    /// Fetches latest TelemetryTransferData. Returns nil if fetch fails or no data found.
    public func fetchLatestTelemetryTransfer() async throws -> TelemetryTransferData? {
        do {
            return try await context.perform {
                // TODO: Update Core Data entity "TelemetryTransferData".
                let fetch = NSFetchRequest<NSManagedObject>(entityName: "TelemetryTransferData")
                fetch.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                fetch.fetchLimit = 1
                guard let entity = try? self.context.fetch(fetch).first else {
                    // Return nil if fetch fails or no data found
                    return nil
                }
                return TelemetryTransferData(
                    latitude: entity.value(forKey: "latitude") as? Double ?? 0,
                    longitude: entity.value(forKey: "longitude") as? Double ?? 0,
                    altitude: entity.value(forKey: "altitude") as? Double ?? 0,
                    signalStrength: entity.value(forKey: "signalStrength") as? Double ?? 0,
                    batteryPercentage: entity.value(forKey: "batteryPercentage") as? Int ?? 0,
                    firmwareVersion: entity.value(forKey: "firmwareVersion") as? String ?? "",
                    timestamp: entity.value(forKey: "timestamp") as? Date ?? Date()
                )
            }
        } catch {
            print("[PersistenceService] Failed to fetch TelemetryTransferData: \(error.localizedDescription)")
            return nil // Return nil on error
        }
    }

    // MARK: - Sonde Settings Transfer
    /// Saves SondeSettingsTransferData as a new entity asynchronously.
    public func saveSondeSettingsTransfer(_ transfer: SondeSettingsTransferData) async throws {
        do {
            try await context.perform {
                // TODO: Create Core Data entity "SondeSettingsTransferData" with all fields.
                let entity = NSEntityDescription.insertNewObject(forEntityName: "SondeSettingsTransferData", into: self.context)
                entity.setValue(transfer.sondeType, forKey: "sondeType")
                entity.setValue(transfer.frequency, forKey: "frequency")
                entity.setValue(transfer.oledSDA, forKey: "oledSDA")
                entity.setValue(transfer.callSign, forKey: "callSign")
                entity.setValue(transfer.threshold, forKey: "threshold")
            }
            print("[PersistenceService] Saved SondeSettingsTransferData: \(transfer)")
            print("[DEBUG] Saved SondeSettingsTransfer:", transfer)
            try await saveContext()
        } catch {
            print("[PersistenceService] Failed to save SondeSettingsTransferData: \(error.localizedDescription)")
        }
    }
    /// Fetches latest SondeSettingsTransferData. Returns nil if fetch fails or no data found.
    public func fetchLatestSondeSettingsTransfer() async throws -> SondeSettingsTransferData? {
        do {
            return try await context.perform {
                // TODO: Update Core Data entity "SondeSettingsTransferData".
                let fetch = NSFetchRequest<NSManagedObject>(entityName: "SondeSettingsTransferData")
                fetch.fetchLimit = 1
                guard let entity = try? self.context.fetch(fetch).first else {
                    // Return nil if fetch fails or no data found
                    return nil
                }
                let transfer = SondeSettingsTransferData(
                    sondeType: entity.value(forKey: "sondeType") as? String ?? "",
                    frequency: entity.value(forKey: "frequency") as? Double ?? 0,
                    oledSDA: entity.value(forKey: "oledSDA") as? Int ?? 0,
                    callSign: entity.value(forKey: "callSign") as? String ?? "",
                    threshold: entity.value(forKey: "threshold") as? Double ?? 0
                )
                print("[DEBUG] Loaded SondeSettingsTransfer:", transfer)
                return transfer
            }
        } catch {
            print("[PersistenceService] Failed to fetch SondeSettingsTransferData: \(error.localizedDescription)")
            return nil // Return nil on error
        }
    }
    
    // MARK: - Forecast Settings
    
    public func saveForecastSettings(_ settings: ForecastSettingsModel) async throws {
        do {
            try await context.perform {
                let entity = NSEntityDescription.insertNewObject(forEntityName: "ForecastSettings", into: self.context)
                entity.setValue(settings.burstAltitude, forKey: "burstAltitude")
                entity.setValue(settings.ascentRate, forKey: "ascentRate")
                entity.setValue(settings.descentRate, forKey: "descentRate")
                entity.setValue(Date(), forKey: "dateSaved")
            }
            try await saveContext()
            print("[PersistenceService] Saved ForecastSettingsModel: \(settings)")
            print("[DEBUG] Saved ForecastSettings:", settings)
        } catch {
            print("[PersistenceService] Failed to save ForecastSettingsModel: \(error.localizedDescription)")
        }
    }
    public func fetchLatestForecastSettings() async throws -> ForecastSettingsModel {
        do {
            return try await context.perform {
                let fetch = NSFetchRequest<NSManagedObject>(entityName: "ForecastSettings")
                fetch.sortDescriptors = [NSSortDescriptor(key: "dateSaved", ascending: false)]
                fetch.fetchLimit = 1
                guard let entity = try? self.context.fetch(fetch).first else {
                    // Return default if fetch fails or no data found
                    let settings = ForecastSettingsModel.default
                    print("[DEBUG] Loaded ForecastSettings:", settings)
                    return settings
                }
                let settings = ForecastSettingsModel(
                    burstAltitude: entity.value(forKey: "burstAltitude") as? Double ?? 35000,
                    ascentRate: entity.value(forKey: "ascentRate") as? Double ?? 5,
                    descentRate: entity.value(forKey: "descentRate") as? Double ?? 5
                )
                print("[DEBUG] Loaded ForecastSettings:", settings)
                return settings
            }
        } catch {
            print("[PersistenceService] Failed to fetch ForecastSettingsModel: \(error.localizedDescription)")
            let settings = ForecastSettingsModel.default
            print("[DEBUG] Loaded ForecastSettings:", settings)
            return settings // Return default on error
        }
    }
    
    // MARK: - Balloon Track
    
    public func saveBalloonTrack(_ track: BalloonTrackModel) async throws {
        do {
            try await context.perform {
                let trackEntity = NSEntityDescription.insertNewObject(forEntityName: "BalloonTrack", into: self.context)
                trackEntity.setValue(track.sondeName, forKey: "sondeName")
                trackEntity.setValue(track.dateUpdated, forKey: "dateUpdated")
                // Save points as child entities
                for point in track.points {
                    let pointEntity = NSEntityDescription.insertNewObject(forEntityName: "BalloonTrackPoint", into: self.context)
                    pointEntity.setValue(point.latitude, forKey: "latitude")
                    pointEntity.setValue(point.longitude, forKey: "longitude")
                    pointEntity.setValue(point.altitude, forKey: "altitude")
                    pointEntity.setValue(point.timestamp, forKey: "timestamp")
                    pointEntity.setValue(trackEntity, forKey: "track")
                }
            }
            try await saveContext()
            print("[PersistenceService] Saved BalloonTrackModel for sonde '" + track.sondeName + "' with \(track.points.count) points.")
        } catch {
            print("[PersistenceService] Failed to save BalloonTrackModel: \(error.localizedDescription)")
        }
    }
    public func fetchBalloonTrack(forSonde sondeName: String) async throws -> BalloonTrackModel? {
        do {
            return try await context.perform {
                let fetch = NSFetchRequest<NSManagedObject>(entityName: "BalloonTrack")
                fetch.predicate = NSPredicate(format: "sondeName == %@", sondeName)
                fetch.sortDescriptors = [NSSortDescriptor(key: "dateUpdated", ascending: false)]
                fetch.fetchLimit = 1
                guard let trackEntity = try? self.context.fetch(fetch).first else {
                    // Return nil if fetch fails or no data found
                    return nil
                }
                let sondeName = trackEntity.value(forKey: "sondeName") as? String ?? ""
                let dateUpdated = trackEntity.value(forKey: "dateUpdated") as? Date ?? Date()
                // Fetch child points
                let pointsSet = trackEntity.value(forKey: "points") as? Set<NSManagedObject> ?? []
                let points = pointsSet.compactMap { pt in
                    TrackPoint(
                        latitude: pt.value(forKey: "latitude") as? Double ?? 0,
                        longitude: pt.value(forKey: "longitude") as? Double ?? 0,
                        altitude: pt.value(forKey: "altitude") as? Double ?? 0,
                        timestamp: pt.value(forKey: "timestamp") as? Date ?? Date()
                    )
                }.sorted { $0.timestamp < $1.timestamp }
                return BalloonTrackModel(sondeName: sondeName, points: points, dateUpdated: dateUpdated)
            }
        } catch {
            print("[PersistenceService] Failed to fetch BalloonTrackModel: \(error.localizedDescription)")
            return nil // Return nil on error
        }
    }
    
    // You may add additional fetch-all/clear methods as needed for compliance.
    
    // MARK: - Helper
    private func saveContext() async throws {
        try await context.perform {
            if self.context.hasChanges {
                do {
                    try self.context.save()
                } catch {
                    print("[PersistenceService] Failed to save context: \(error.localizedDescription)")
                    throw error
                }
            }
        }
    }
}
