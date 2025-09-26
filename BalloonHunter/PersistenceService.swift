import Foundation
import Combine
import CoreLocation
import OSLog

struct BurstKillerRecord: Codable {
    let seconds: Int
    let referenceDate: Date
}

// MARK: - Persistence Service

@MainActor
final class PersistenceService: ObservableObject {
    private let userDefaults = UserDefaults.standard
    
    // Internal storage for cached data
    @Published var userSettings: UserSettings
    @Published var deviceSettings: DeviceSettings?
    private var internalTracks: [String: [BalloonTrackPoint]] = [:]
    private var internalLandingHistories: [String: [LandingPredictionPoint]] = [:]
    private var burstKillerRecords: [String: BurstKillerRecord] = [:]
    
    init() {
        // PersistenceService initializing (log removed for reduction)
        
        // Load user settings
        self.userSettings = Self.loadUserSettings()
        
        // Load device settings
        self.deviceSettings = Self.loadDeviceSettings()
        
        // Load tracks
        self.internalTracks = Self.loadAllTracks()
        
        // Load landing point histories
        self.internalLandingHistories = Self.loadAllLandingHistories()
        
        // Load burst killer cache
        self.burstKillerRecords = Self.loadBurstKillerRecords()

        appLog("PersistenceService: Initialized - tracks: \(internalTracks.count), histories: \(internalLandingHistories.count)", category: .service, level: .info)
    }
    
    // MARK: - User Settings
    
    func save(userSettings: UserSettings) {
        self.userSettings = userSettings
        
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(userSettings) {
            userDefaults.set(encoded, forKey: "UserSettings")
            appLog("PersistenceService: UserSettings saved to UserDefaults.", category: .service, level: .debug)
        }
    }
    
    func readPredictionParameters() -> UserSettings? {
        return userSettings
    }
    
    private static func loadUserSettings() -> UserSettings {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "UserSettings"),
           let userSettings = try? decoder.decode(UserSettings.self, from: data) {
            appLog("PersistenceService: UserSettings loaded from UserDefaults.", category: .service, level: .debug)
            return userSettings
        } else {
            let defaultSettings = UserSettings()
            appLog("PersistenceService: UserSettings not found, using defaults.", category: .service, level: .debug)
            return defaultSettings
        }
    }
    
    // MARK: - Device Settings
    
    func save(deviceSettings: DeviceSettings) {
        self.deviceSettings = deviceSettings
        
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(deviceSettings) {
            userDefaults.set(encoded, forKey: "DeviceSettings")
            appLog("PersistenceService: deviceSettings saved: \(deviceSettings)", category: .service, level: .debug)
        }
    }
    
    private static func loadDeviceSettings() -> DeviceSettings? {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "DeviceSettings"),
           let deviceSettings = try? decoder.decode(DeviceSettings.self, from: data) {
            return deviceSettings
        }
        return nil
    }
    
    // MARK: - Track Management
    
    func saveBalloonTrack(sondeName: String, track: [BalloonTrackPoint]) {
        internalTracks[sondeName] = track
        saveAllTracks()
        appLog("PersistenceService: Saved track for '\(sondeName)' (\(track.count) points)", category: .service, level: .debug)
    }
    
    func loadTrackForCurrentSonde(sondeName: String) -> [BalloonTrackPoint]? {
        return internalTracks[sondeName]
    }
    
    func purgeAllTracks() {
        internalTracks.removeAll()
        userDefaults.removeObject(forKey: "BalloonTracks")
        appLog("PersistenceService: All balloon tracks purged.", category: .service, level: .debug)
    }
    
    func saveOnAppClose(balloonTrackService: BalloonTrackService,
                        landingPointTrackingService: LandingPointTrackingService) {
        if let currentName = balloonTrackService.currentBalloonName {
            let track = balloonTrackService.getAllTrackPoints()
            saveBalloonTrack(sondeName: currentName, track: track)
            appLog("PersistenceService: Saved current balloon track for sonde '\(currentName)' on app close.", category: .service, level: .info)
        }
        landingPointTrackingService.persistCurrentHistory()
    }
    
    private func saveAllTracks() {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(internalTracks) {
            // Save to both UserDefaults (for production) and Documents directory (for development persistence)
            userDefaults.set(encoded, forKey: "BalloonTracks")
            saveToDocumentsDirectory(data: encoded, filename: "BalloonTracks.json")
        }
    }
    
    private static func loadAllTracks() -> [String: [BalloonTrackPoint]] {
        let decoder = JSONDecoder()
        
        // Try Documents directory first (survives development installs)
        if let data = loadFromDocumentsDirectory(filename: "BalloonTracks.json"),
           let tracks = try? decoder.decode([String: [BalloonTrackPoint]].self, from: data) {
            // Loaded tracks successfully
            return tracks
        }
        
        // Fallback to UserDefaults (for production)
        if let data = UserDefaults.standard.data(forKey: "BalloonTracks"),
           let tracks = try? decoder.decode([String: [BalloonTrackPoint]].self, from: data) {
            appLog("PersistenceService: Loaded tracks from UserDefaults", category: .service, level: .debug)
            return tracks
        }
        
        appLog("PersistenceService: No existing tracks found", category: .service, level: .debug)
        return [:]
    }
    
    // MARK: - Landing Points
    
    func saveLandingHistory(sondeName: String, history: [LandingPredictionPoint]) {
        internalLandingHistories[sondeName] = history
        saveAllLandingHistories()
    }

    func loadLandingHistory(sondeName: String) -> [LandingPredictionPoint]? {
        internalLandingHistories[sondeName]
    }

    func updateBurstKillerTime(for sondeName: String, time: Int, referenceDate: Date) {
        guard !sondeName.isEmpty, time > 0 else { return }
        burstKillerRecords[sondeName] = BurstKillerRecord(seconds: time, referenceDate: referenceDate)
        
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(burstKillerRecords) {
            userDefaults.set(encoded, forKey: "BurstKillerTimes")
        }
    }
    
    func loadBurstKillerRecord(for sondeName: String) -> BurstKillerRecord? {
        burstKillerRecords[sondeName]
    }

    func removeLandingHistory(for sondeName: String) {
        internalLandingHistories.removeValue(forKey: sondeName)
        saveAllLandingHistories()
    }

    func purgeAllLandingHistories() {
        internalLandingHistories.removeAll()
        userDefaults.removeObject(forKey: "LandingPointHistories")
        removeFromDocumentsDirectory(filename: "LandingPointHistories.json")
        appLog("PersistenceService: Purged all landing point histories", category: .service, level: .debug)
    }

    private func saveAllLandingHistories() {
        let encoder = JSONEncoder()
        guard let encoded = try? encoder.encode(internalLandingHistories) else { return }
        userDefaults.set(encoded, forKey: "LandingPointHistories")
        saveToDocumentsDirectory(data: encoded, filename: "LandingPointHistories.json")
    }

    private static func loadAllLandingHistories() -> [String: [LandingPredictionPoint]] {
        let decoder = JSONDecoder()

        if let data = loadFromDocumentsDirectory(filename: "LandingPointHistories.json"),
           let histories = try? decoder.decode([String: [LandingPredictionPoint]].self, from: data) {
            // Loaded landing histories successfully
            return histories
        }

        if let data = UserDefaults.standard.data(forKey: "LandingPointHistories"),
           let histories = try? decoder.decode([String: [LandingPredictionPoint]].self, from: data) {
            appLog("PersistenceService: Loaded landing histories from UserDefaults", category: .service, level: .debug)
            return histories
        }

        return [:]
    }

    private static func loadBurstKillerRecords() -> [String: BurstKillerRecord] {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "BurstKillerTimes") {
            if let records = try? decoder.decode([String: BurstKillerRecord].self, from: data) {
                return records
            }
            if let legacy = try? decoder.decode([String: Int].self, from: data) {
                let now = Date()
                return legacy.mapValues { BurstKillerRecord(seconds: $0, referenceDate: now) }
            }
        }
        return [:]
    }
    
    // MARK: - Documents Directory Helpers
    
    private func saveToDocumentsDirectory(data: Data, filename: String) {
        do {
            let documentsURL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let fileURL = documentsURL.appendingPathComponent(filename)
            try data.write(to: fileURL)
            // File saved successfully (logged at higher level)
        } catch {
            appLog("PersistenceService: Failed to save \(filename) to Documents directory: \(error)", category: .service, level: .error)
        }
    }
    
    private func removeFromDocumentsDirectory(filename: String) {
        do {
            let documentsURL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let fileURL = documentsURL.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            appLog("PersistenceService: Failed to remove \(filename) from Documents directory: \(error)", category: .service, level: .debug)
        }
    }

    private static func loadFromDocumentsDirectory(filename: String) -> Data? {
        do {
            let documentsURL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let fileURL = documentsURL.appendingPathComponent(filename)
            let data = try Data(contentsOf: fileURL)
            // File loaded successfully
            return data
        } catch {
            appLog("PersistenceService: Failed to load \(filename) from Documents directory: \(error)", category: .service, level: .debug)
            return nil
        }
    }
}
