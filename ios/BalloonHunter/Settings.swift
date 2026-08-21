import Foundation
import Combine
import OSLog

// MARK: - Notification Names

extension Notification.Name {
    static let transportModeChanged = Notification.Name("transportModeChanged")
}

// MARK: - App and User Settings

/// Which server answers a prediction request.
///
/// Two servers speak the same Tawhiri contract, so choosing between them is a
/// base-URL change and nothing else in the app moves. SondeHub is the fallback
/// whenever the chosen one cannot be used: a hunt must not lose its predictions
/// because the newer server is down or not yet deployed.
enum PredictionEndpoint {

    static let sondeHub = URL(string: "https://api.v2.sondehub.org/tawhiri")!

    /// Where a failed request is retried. Fixed, and never the server that just
    /// failed — that would be a retry loop, not a fallback.
    static var fallback: URL { sondeHub }

    static let swissPredictorDefault = "https://predictor.fabia.ch/tawhiri"

    /// The server to ask first.
    ///
    /// A URL that cannot work is refused here rather than at request time. Plain
    /// HTTP is blocked by App Transport Security, so accepting one would turn a
    /// typo into a silent fallback on every prediction for the rest of a flight.
    static func base(useSwiss: Bool, swissURL: String) -> URL {
        guard useSwiss else { return sondeHub }

        let trimmed = swissURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return sondeHub
        }
        return url
    }

    /// Name for the log. An A/B run is worthless if the log cannot say who
    /// answered.
    static func name(for url: URL) -> String {
        url == sondeHub ? "SondeHub" : (url.host ?? url.absoluteString)
    }

    static func shouldFallBack(from url: URL) -> Bool { url != sondeHub }
}

@MainActor
final class UserSettings: ObservableObject, Codable {
    @Published var burstAltitude: Double = 35000
    @Published var ascentRate: Double = 5.0
    @Published var descentRate: Double = 5.0
    @Published var stationId: String = "06610" // Default to Payerne

    /// Ask the Swiss-Balloon-Predictor first. SondeHub remains the fallback.
    @Published var useSwissPredictor: Bool = true
    /// Editable so a moved or renamed server needs no rebuild.
    @Published var swissPredictorURL: String = PredictionEndpoint.swissPredictorDefault

    enum CodingKeys: CodingKey {
        case burstAltitude, ascentRate, descentRate, stationId
        case useSwissPredictor, swissPredictorURL
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        burstAltitude = try container.decode(Double.self, forKey: .burstAltitude)
        ascentRate = try container.decode(Double.self, forKey: .ascentRate)
        descentRate = try container.decode(Double.self, forKey: .descentRate)
        stationId = try container.decodeIfPresent(String.self, forKey: .stationId) ?? "06610"
        // decodeIfPresent: settings files written before the predictor switch
        // existed must keep loading, and land on the new default.
        useSwissPredictor = try container.decodeIfPresent(Bool.self, forKey: .useSwissPredictor) ?? true
        swissPredictorURL = try container.decodeIfPresent(String.self, forKey: .swissPredictorURL)
            ?? PredictionEndpoint.swissPredictorDefault
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(burstAltitude, forKey: .burstAltitude)
        try container.encode(ascentRate, forKey: .ascentRate)
        try container.encode(descentRate, forKey: .descentRate)
        try container.encode(stationId, forKey: .stationId)
        try container.encode(useSwissPredictor, forKey: .useSwissPredictor)
        try container.encode(swissPredictorURL, forKey: .swissPredictorURL)
    }

    init() { }
}

@MainActor
final class AppSettings: ObservableObject {
    // App-level settings can be added here as needed
    var debugMode: Bool = false

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

