import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

struct CodableCoordinate: Codable {
    var latitude: Double
    var longitude: Double

    init(coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@MainActor
final class PersistenceService: ObservableObject {
    @Published var deviceSettings: DeviceSettings? = nil
    @Published var userSettings: UserSettings = .default {
        didSet {
            if let encoded = try? JSONEncoder().encode(userSettings) {
                UserDefaults.standard.set(encoded, forKey: "userSettings")
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] UserSettings saved to UserDefaults.")
            } else {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Failed to encode UserSettings for saving.")
            }
        }
    }

    private let tracksUserDefaultsKey = "balloonTracks"
    private var internalTracks: [String: [BalloonTrackPoint]] = [:]
    private let landingPointsUserDefaultsKey = "landingPoints"
    private var internalLandingPoints: [String: CodableCoordinate] = [:]

    func save(deviceSettings: DeviceSettings) {
        self.deviceSettings = deviceSettings
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: deviceSettings saved: \(deviceSettings)")
    }
    func save(userSettings: UserSettings) {
        self.userSettings = userSettings
    }
    func readPredictionParameters() -> UserSettings? {
        return userSettings
    }

    func loadTrackForCurrentSonde(sondeName: String) -> [BalloonTrackPoint]? {
        return internalTracks[sondeName]
    }

    func saveCurrentBalloonTrack(sondeName: String, track: [BalloonTrackPoint]) {
        internalTracks[sondeName] = track
        if let encoded = try? JSONEncoder().encode(internalTracks) {
            UserDefaults.standard.set(encoded, forKey: tracksUserDefaultsKey)
        } else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: Failed to encode internalTracks for saving.")
        }
    }

    func purgeAllTracks() {
        internalTracks = [:]
        if let encoded = try? JSONEncoder().encode(internalTracks) {
            UserDefaults.standard.set(encoded, forKey: tracksUserDefaultsKey)
        } else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: Failed to encode internalTracks for purging.")
        }
    }

    func saveLandingPoint(sondeName: String, coordinate: CLLocationCoordinate2D) {
        internalLandingPoints[sondeName] = CodableCoordinate(coordinate: coordinate)
        if let encoded = try? JSONEncoder().encode(internalLandingPoints) {
            UserDefaults.standard.set(encoded, forKey: landingPointsUserDefaultsKey)
        }
    }

    func loadLandingPoint(sondeName: String) -> CLLocationCoordinate2D? {
        return internalLandingPoints[sondeName]?.coordinate
    }

    func clearLandingPoint(sondeName: String) {
        internalLandingPoints.removeValue(forKey: sondeName)
        if let encoded = try? JSONEncoder().encode(internalLandingPoints) {
            UserDefaults.standard.set(encoded, forKey: landingPointsUserDefaultsKey)
        }
    }

    /// Unified save-on-close approach: Saves the current balloon track from the given BalloonTrackingService if available.
    func saveOnAppClose(balloonTrackingService: BalloonTrackingService) {
        if let currentSondeName = balloonTrackingService.currentBalloonName, !balloonTrackingService.currentBalloonTrack.isEmpty {
            saveCurrentBalloonTrack(sondeName: currentSondeName, track: balloonTrackingService.currentBalloonTrack)
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: Saved current balloon track for sonde '\(currentSondeName)' on app close.")
        }
    }

    init() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService init")
        if let savedSettings = UserDefaults.standard.data(forKey: "userSettings") {
            if let decodedSettings = try? JSONDecoder().decode(UserSettings.self, from: savedSettings) {
                self.userSettings = decodedSettings
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] UserSettings loaded from UserDefaults.")
            } else {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Failed to decode UserSettings from UserDefaults.")
            }
        } else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] No UserSettings found in UserDefaults, using default.")
        }

        if let savedTracksData = UserDefaults.standard.data(forKey: tracksUserDefaultsKey) {
            if let decodedTracks = try? JSONDecoder().decode([String: [BalloonTrackPoint]].self, from: savedTracksData) {
                self.internalTracks = decodedTracks
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: Tracks loaded from UserDefaults. Total tracks: \(internalTracks.count)")
            } else {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: Failed to decode tracks from UserDefaults.")
            }
        } else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: No tracks found in UserDefaults, initializing empty.")
        }

        if let savedLandingPointsData = UserDefaults.standard.data(forKey: landingPointsUserDefaultsKey) {
            if let decodedLandingPoints = try? JSONDecoder().decode([String: CodableCoordinate].self, from: savedLandingPointsData) {
                self.internalLandingPoints = decodedLandingPoints
            }
        }
    }
}
