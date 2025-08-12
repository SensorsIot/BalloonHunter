import Foundation
import CoreLocation
import CoreData

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
    
    // MARK: - Forecast Settings
    
    public func saveForecastSettings(_ settings: ForecastSettingsModel) async throws {
        do {
            await context.perform {
                let fetchRequest = NSFetchRequest<ForecastSettings>(entityName: "ForecastSettings")
                // Assuming one settings object to be updated, or create a new one.
                let entity = (try? self.context.fetch(fetchRequest).first) ?? ForecastSettings(context: self.context)
                entity.burstAltitude = settings.burstAltitude
                entity.ascentRate = settings.ascentRate
                entity.descentRate = settings.descentRate
                entity.dateSaved = Date()
            }
            print("[PersistenceService] Saved ForecastSettingsModel: \(settings)")
            try await saveContext()
        } catch {
            print("[PersistenceService] Failed to save ForecastSettingsModel: \(error.localizedDescription)")
        }
    }
    public func fetchLatestForecastSettings() async throws -> ForecastSettingsModel {
        do {
            return try await context.perform {
                let fetch = NSFetchRequest<ForecastSettings>(entityName: "ForecastSettings")
                fetch.sortDescriptors = [NSSortDescriptor(key: "dateSaved", ascending: false)]
                fetch.fetchLimit = 1
                guard let entity = try self.context.fetch(fetch).first else {
                    // Return default if fetch fails or no data found
                    let settings = ForecastSettingsModel.default
                    print("[PersistenceService] No forecast settings found, returning default.")
                    return settings
                }
                let settings = ForecastSettingsModel(
                    burstAltitude: entity.burstAltitude,
                    ascentRate: entity.ascentRate,
                    descentRate: entity.descentRate
                )
                print("[PersistenceService] Loaded ForecastSettings: \(settings)")
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
            await context.perform {
                let trackEntity = BalloonTrack(context: self.context)
                trackEntity.sondeName = track.sondeName
                trackEntity.dateUpdated = track.dateUpdated
                
                var pointsSet = Set<BalloonTrackPoint>()
                // Save points as child entities
                for point in track.points {
                    let pointEntity = BalloonTrackPoint(context: self.context)
                    pointEntity.latitude = point.latitude
                    pointEntity.longitude = point.longitude
                    pointEntity.altitude = point.altitude
                    pointEntity.timestamp = point.timestamp
                    pointsSet.insert(pointEntity)
                }
                trackEntity.points = pointsSet
            }
            print("[PersistenceService] Saved BalloonTrackModel for sonde '" + track.sondeName + "' with \(track.points.count) points.")
            try await saveContext()
        } catch {
            print("[PersistenceService] Failed to save BalloonTrackModel: \(error.localizedDescription)")
        }
    }
    public func fetchBalloonTrack(forSonde sondeName: String) async throws -> BalloonTrackModel? {
        do {
            return try await context.perform {
                let fetch = NSFetchRequest<BalloonTrack>(entityName: "BalloonTrack")
                fetch.predicate = NSPredicate(format: "sondeName == %@", sondeName)
                fetch.sortDescriptors = [NSSortDescriptor(key: "dateUpdated", ascending: false)]
                fetch.fetchLimit = 1
                guard let trackEntity = try self.context.fetch(fetch).first else {
                    // Return nil if fetch fails or no data found
                    return nil
                }
                let sondeName = trackEntity.sondeName
                let dateUpdated = trackEntity.dateUpdated
                // Fetch child points
                let points = trackEntity.points.map { pt in
                    TrackPoint(
                        latitude: pt.latitude,
                        longitude: pt.longitude,
                        altitude: pt.altitude,
                        timestamp: pt.timestamp
                    )
                }.sorted { $0.timestamp < $1.timestamp }
                return BalloonTrackModel(sondeName: sondeName, points: points, dateUpdated: dateUpdated)
            }
        } catch {
            print("[PersistenceService] Failed to fetch BalloonTrackModel: \(error.localizedDescription)")
            return nil // Return nil on error
        }
    }
    
    // MARK: - MySondyGo Settings
    
    public func saveMySondyGoSettings(_ settings: BLEDeviceSettingsModel) async throws {
        await context.perform {
            // Fetch existing or create new. This logic assumes a single settings record.
            let fetchRequest = NSFetchRequest<MySondyGoSettings>(entityName: "MySondyGoSettings")
            fetchRequest.fetchLimit = 1
            
            let entity = (try? self.context.fetch(fetchRequest).first) ?? MySondyGoSettings(context: self.context)
            
            entity.probeType = settings.probeType
            entity.frequency = settings.frequency
            entity.oledSDA = Int64(settings.oledSDA)
            entity.oledSCL = Int64(settings.oledSCL)
            entity.oledRST = Int64(settings.oledRST)
            entity.ledPin = Int64(settings.ledPin)
            entity.rs41Bandwidth = Int64(settings.RS41Bandwidth)
            entity.m20Bandwidth = Int64(settings.M20Bandwidth)
            entity.m10Bandwidth = Int64(settings.M10Bandwidth)
            entity.pilotBandwidth = Int64(settings.PILOTBandwidth)
            entity.dfmBandwidth = Int64(settings.DFMBandwidth)
            entity.callSign = settings.callSign
            entity.frequencyCorrection = Int64(settings.frequencyCorrection)
            entity.batPin = Int64(settings.batPin)
            entity.batMin = Int64(settings.batMin)
            entity.batMax = Int64(settings.batMax)
            entity.batType = Int64(settings.batType)
            entity.lcdType = Int64(settings.lcdType)
            entity.nameType = Int64(settings.nameType)
            entity.buzPin = Int64(settings.buzPin)
            entity.softwareVersion = settings.softwareVersion
            entity.dateSaved = Date()
        }
        print("[PersistenceService] Saved MySondyGo settings.")
        try await saveContext()
    }
    
    // You may add additional fetch-all/clear methods as needed for compliance.
    
    // MARK: - Helper
    private func saveContext() async throws {
        if context.hasChanges {
            try await context.perform { try self.context.save() }
        }
    }
}

