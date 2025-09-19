import Foundation
import Combine
import OSLog

// MARK: - Notification Names

extension Notification.Name {
    static let transportModeChanged = Notification.Name("transportModeChanged")
}

// MARK: - App and User Settings

@MainActor
final class UserSettings: ObservableObject, Codable {
    @Published var burstAltitude: Double = 30000
    @Published var ascentRate: Double = 5.0
    @Published var descentRate: Double = 5.0

    enum CodingKeys: CodingKey {
        case burstAltitude, ascentRate, descentRate
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        burstAltitude = try container.decode(Double.self, forKey: .burstAltitude)
        ascentRate = try container.decode(Double.self, forKey: .ascentRate)
        descentRate = try container.decode(Double.self, forKey: .descentRate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(burstAltitude, forKey: .burstAltitude)
        try container.encode(ascentRate, forKey: .ascentRate)
        try container.encode(descentRate, forKey: .descentRate)
    }

    init() { }
}

@MainActor
final class AppSettings: ObservableObject {
    // App-level settings can be added here as needed
    @Published var debugMode: Bool = false

    // Transport mode with UserDefaults persistence
    @Published var transportMode: TransportationMode = .car {
        didSet {
            UserDefaults.standard.set(transportMode.rawValue, forKey: "transportMode")
            appLog("AppSettings: Transport mode saved to UserDefaults: \(transportMode.rawValue)", category: .general, level: .debug)

            // Notify about transport mode change for route recalculation
            NotificationCenter.default.post(name: .transportModeChanged, object: transportMode)
        }
    }

    init() {
        // Load transport mode from UserDefaults
        if let savedMode = UserDefaults.standard.object(forKey: "transportMode") as? String,
           let mode = TransportationMode(rawValue: savedMode) {
            transportMode = mode
            appLog("AppSettings: Loaded transport mode from UserDefaults: \(savedMode)", category: .general, level: .debug)
        } else {
            // Default to car mode if no saved preference
            transportMode = .car
            UserDefaults.standard.set(transportMode.rawValue, forKey: "transportMode")
            appLog("AppSettings: Using default transport mode: car", category: .general, level: .debug)
        }
    }

    // Static method for notification handler to read persisted transport mode
    static func getPersistedTransportMode() -> TransportationMode {
        if let savedMode = UserDefaults.standard.object(forKey: "transportMode") as? String,
           let mode = TransportationMode(rawValue: savedMode) {
            return mode
        }
        return .car // Default fallback
    }
}

// MARK: - ESP32 Pin Validation Rules (used by settings)

struct ESP32PinRules {
    static func outputWarning(pin: Int) -> String? {
        if (34...39).contains(pin) { return "GPIO34–39 are input-only on ESP32." }
        if (6...11).contains(pin) { return "GPIO6–11 are flash pins; avoid using them." }
        if [0, 2, 5, 12, 15].contains(pin) { return "Boot strap pin; avoid for outputs (may break boot)." }
        return nil
    }

    static func i2cWarning(pin: Int) -> String? {
        if (34...39).contains(pin) { return "GPIO34–39 are input-only; not valid for I²C." }
        if (6...11).contains(pin) { return "GPIO6–11 are flash pins; avoid using them." }
        if [0, 2, 5, 12, 15].contains(pin) { return "Boot strap pin; avoid for I²C (may affect boot)." }
        return nil
    }

    static func batteryWarning(pin: Int) -> String? {
        if !(32...39).contains(pin) { return "Prefer ADC1 GPIO32–39 for battery sensing." }
        return nil
    }
}

