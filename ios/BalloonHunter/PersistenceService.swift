import Foundation
import Combine
import CoreLocation
import OSLog

// MARK: - Persistence Service

@MainActor
final class PersistenceService: ObservableObject {

    // MARK: - Published Properties
    @Published var userSettings: UserSettings

    // Ephemeral (not persisted)
    @Published var deviceSettings: DeviceSettings?
    @Published var radioSettings: RadioSettings?

    // MARK: - File Names
    private let userSettingsFile = "userSettings.json"
    private let sondeNameFile = "sondeName.json"
    private let balloonTrackFile = "balloontrack.json"
    private let landingPointsFile = "landingPoints.json"

    init() {
        // Load only userSettings in init for backward compatibility
        self.userSettings = Self.loadUserSettings()

        // Ephemeral settings not persisted
        self.deviceSettings = nil
        self.radioSettings = nil

        appLog("PersistenceService: Initialized with 4-file model", category: .service, level: .info)
    }

    // MARK: - User Settings

    func save(userSettings: UserSettings) {
        self.userSettings = userSettings

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        if let encoded = try? encoder.encode(userSettings) {
            saveToDocumentsDirectory(data: encoded, filename: userSettingsFile)
            appLog("PersistenceService: UserSettings saved", category: .service, level: .debug)
        }
    }

    private static func loadUserSettings() -> UserSettings {
        let decoder = JSONDecoder()

        // Try Documents directory first
        if let data = loadFromDocumentsDirectory(filename: "userSettings.json"),
           let settings = try? decoder.decode(UserSettings.self, from: data) {
            appLog("PersistenceService: UserSettings loaded", category: .service, level: .debug)
            return settings
        }

        // Default settings
        appLog("PersistenceService: UserSettings not found, using defaults", category: .service, level: .debug)
        return UserSettings()
    }

    // MARK: - Device Settings (Ephemeral - In-Memory Only)

    func save(deviceSettings: DeviceSettings) {
        self.deviceSettings = deviceSettings
        // NOT persisted - stored in MySondyGo device
        appLog("PersistenceService: deviceSettings updated in memory (not persisted): \(deviceSettings)", category: .service, level: .debug)
    }

    // MARK: - Radio Settings (Ephemeral - In-Memory Only)

    func update(radioSettings: RadioSettings) {
        self.radioSettings = radioSettings
        // NOT persisted - comes from telemetry
        appLog("PersistenceService: radioSettings updated in memory: freq=\(String(format: "%.2f", radioSettings.frequency))MHz type=\(radioSettings.probeType)", category: .service, level: .debug)
    }

    // MARK: - Sonde Name

    func saveSondeName(_ sondeName: String) {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(sondeName) {
            saveToDocumentsDirectory(data: encoded, filename: sondeNameFile)
            appLog("PersistenceService: Sonde name saved: '\(sondeName)'", category: .service, level: .debug)
        }
    }

    func loadSondeName() -> String? {
        let decoder = JSONDecoder()
        if let data = Self.loadFromDocumentsDirectory(filename: sondeNameFile),
           let sondeName = try? decoder.decode(String.self, from: data) {
            appLog("PersistenceService: Sonde name loaded: '\(sondeName)'", category: .service, level: .debug)
            return sondeName
        }
        return nil
    }

    // MARK: - Balloon Track

    /// A track stored together with the sonde it belongs to.
    ///
    /// The two used to live in separate files, with nothing tying them together.
    /// A track could therefore hold points from one sonde while the name file
    /// claimed another, and no code could tell: `BalloonTrackPoint` carries no
    /// serial, so a mixed track is indistinguishable from a clean one.
    private struct PersistedTrack: Codable {
        let sondeName: String
        let points: [BalloonTrackPoint]
    }

    func saveBalloonTrack(_ track: [BalloonTrackPoint], sondeName: String?) {
        guard let sondeName, !sondeName.isEmpty else {
            // Nothing to bind the points to, so storing them would recreate the
            // very ambiguity this format exists to remove.
            appLog("PersistenceService: Balloon track not saved - no sonde name to bind it to", category: .service, level: .info)
            return
        }

        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(PersistedTrack(sondeName: sondeName, points: track)) {
            saveToDocumentsDirectory(data: encoded, filename: balloonTrackFile)
            appLog("PersistenceService: Balloon track saved (\(track.count) points for '\(sondeName)')", category: .service, level: .debug)
        }
    }

    /// Load the stored track, but only if it demonstrably belongs to `sondeName`.
    ///
    /// Anything else is discarded rather than shown: a track from another sonde,
    /// or one in the old format that names no owner and so cannot be vouched for.
    func loadBalloonTrack(expecting sondeName: String?) -> [BalloonTrackPoint]? {
        guard let data = Self.loadFromDocumentsDirectory(filename: balloonTrackFile) else { return nil }
        let decoder = JSONDecoder()

        guard let stored = try? decoder.decode(PersistedTrack.self, from: data) else {
            // Old format: a bare array of points with no owner recorded. It may
            // well be clean, but nothing in it can establish that, and an
            // unverifiable track is what put another sonde's position on the map.
            let count = (try? decoder.decode([BalloonTrackPoint].self, from: data))?.count
            appLog("PersistenceService: Discarding unattributed track\(count.map { " (\($0) points)" } ?? "") - stored without a sonde name", category: .service, level: .info)
            saveToDocumentsDirectory(data: Data("null".utf8), filename: balloonTrackFile)
            return nil
        }

        guard let sondeName, stored.sondeName == sondeName else {
            appLog("PersistenceService: Discarding track for '\(stored.sondeName)' (\(stored.points.count) points) - now tracking '\(sondeName ?? "nothing")'", category: .service, level: .info)
            return nil
        }

        appLog("PersistenceService: Balloon track loaded (\(stored.points.count) points for '\(stored.sondeName)')", category: .service, level: .debug)
        return stored.points
    }

    // MARK: - Landing Points

    func saveLandingPoints(_ landingPoints: [LandingPredictionPoint]) {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(landingPoints) {
            saveToDocumentsDirectory(data: encoded, filename: landingPointsFile)
            appLog("PersistenceService: Landing points saved (\(landingPoints.count) points)", category: .service, level: .debug)
        }
    }

    func loadLandingPoints() -> [LandingPredictionPoint]? {
        let decoder = JSONDecoder()
        if let data = Self.loadFromDocumentsDirectory(filename: landingPointsFile),
           let landingPoints = try? decoder.decode([LandingPredictionPoint].self, from: data) {
            appLog("PersistenceService: Landing points loaded (\(landingPoints.count) points)", category: .service, level: .debug)
            return landingPoints
        }
        return nil
    }

    // MARK: - App Close Persistence

    func saveOnAppClose(balloonTrackService: BalloonTrackService,
                        landingPointTrackingService: LandingPointTrackingService) {
        // Save current sonde name
        if let currentName = balloonTrackService.currentBalloonName {
            saveSondeName(currentName)
        }

        // Save current track
        let track = balloonTrackService.getAllTrackPoints()
        saveBalloonTrack(track, sondeName: balloonTrackService.currentBalloonName)

        // Save landing points
        let landingPoints = landingPointTrackingService.landingHistory
        saveLandingPoints(landingPoints)

        appLog("PersistenceService: All data saved on app close", category: .service, level: .info)
    }

    // MARK: - Documents Directory Helpers

    private func saveToDocumentsDirectory(data: Data, filename: String) {
        do {
            let documentsURL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let fileURL = documentsURL.appendingPathComponent(filename)
            try data.write(to: fileURL)
        } catch {
            appLog("PersistenceService: Failed to save \(filename): \(error)", category: .service, level: .error)
        }
    }

    private static func loadFromDocumentsDirectory(filename: String) -> Data? {
        do {
            let documentsURL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let fileURL = documentsURL.appendingPathComponent(filename)
            return try Data(contentsOf: fileURL)
        } catch {
            // Don't log error for missing files (normal on first run)
            return nil
        }
    }
}
