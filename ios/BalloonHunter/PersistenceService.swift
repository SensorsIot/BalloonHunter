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

    init() {
        // Load only userSettings in init for backward compatibility
        self.userSettings = Self.loadUserSettings()

        // Ephemeral settings not persisted
        self.deviceSettings = nil
        self.radioSettings = nil

        removeRetiredFiles()
        appLog("PersistenceService: Initialized - settings and the BLE hunt tail; the flight itself is not stored", category: .service, level: .info)
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



    // MARK: - The BLE hunt tail

    private let huntTailFile = "hunttail.json"

    /// Write the stretch of BLE the network never saw. See `HuntTail`.
    ///
    /// Called when the app enters the **background** and nowhere else: the
    /// background is the only thing persistence exists to survive. Nothing is
    /// written when the app merely goes inactive, because iOS passes through
    /// `.inactive` in both directions and the return trip has nothing new to save.
    func saveHuntTail(_ tail: HuntTail?) {
        guard let tail else {
            // Nothing irreplaceable to keep — drop any stale tail rather than leave
            // a previous hunt's data to be offered to the next one.
            deleteFromDocumentsDirectory(filename: huntTailFile)
            appLog("PersistenceService: No BLE hunt tail to save (APRS holds everything)", category: .service, level: .debug)
            return
        }
        guard let encoded = try? JSONEncoder().encode(tail) else { return }
        saveToDocumentsDirectory(data: encoded, filename: huntTailFile)
        appLog("PersistenceService: BLE hunt tail saved (\(tail.points.count) points for '\(tail.serial)')", category: .service, level: .info)
    }

    /// The stored tail, whatever sonde it belongs to. Whether it may be used is
    /// `HuntTail.points(for:now:)`'s decision, not this one's.
    func loadHuntTail() -> HuntTail? {
        guard let data = Self.loadFromDocumentsDirectory(filename: huntTailFile),
              let tail = try? JSONDecoder().decode(HuntTail.self, from: data) else { return nil }
        appLog("PersistenceService: BLE hunt tail loaded (\(tail.points.count) points for '\(tail.serial)')", category: .service, level: .debug)
        return tail
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

    /// Files earlier versions wrote and nothing reads any more.
    ///
    /// `balloontrack.json` and `sondeName.json` are gone because the flight comes
    /// from SondeHub and the hunted serial is the picker's answer; `landingPoints.json`
    /// was written on every new landing point and never once read back. Left alone
    /// they would sit in Documents forever — the track file was 129 KB — and, worse,
    /// invite someone to start reading them again. Safe to delete this method once
    /// no installed build still writes them.
    private func removeRetiredFiles() {
        for filename in ["balloontrack.json", "sondeName.json", "landingPoints.json"] {
            deleteFromDocumentsDirectory(filename: filename)
        }
    }

    private func deleteFromDocumentsDirectory(filename: String) {
        guard let documentsURL = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        try? FileManager.default.removeItem(at: documentsURL.appendingPathComponent(filename))
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
