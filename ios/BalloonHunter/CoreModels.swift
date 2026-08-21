import Foundation
import CoreLocation
import MapKit
import OSLog

// MARK: - Core Data Models

enum TransportationMode: String, CaseIterable, Codable {
    case car = "car"
    case bike = "bike"
}

// Flight phase of the balloon
enum BalloonPhase: String, Codable {
    case ascending
    case descendingAbove10k
    case descendingBelow10k
    case landed
    case unknown

    /// True when the balloon is up. `unknown` is not airborne — it means the
    /// detector could not tell, which must never be read as "still flying".
    var isAirborne: Bool {
        switch self {
        case .ascending, .descendingAbove10k, .descendingBelow10k: return true
        case .landed, .unknown: return false
        }
    }

    /// True once the balloon has burst: falling, or already down.
    ///
    /// Before burst a landing prediction rests on an *assumed* burst altitude,
    /// so successive estimates are guesswork rather than convergence. Anything
    /// that reads meaning into how the estimates move has to wait for this.
    var isAfterBurst: Bool {
        switch self {
        case .descendingAbove10k, .descendingBelow10k, .landed: return true
        case .ascending, .unknown: return false
        }
    }
}

enum TelemetrySource: String, Codable {
    case ble
    case aprs
}

enum BLEConnectionState: String, Codable, CaseIterable {
    case notConnected = "notConnected"
    case readyForCommands = "readyForCommands"
    case dataReady = "dataReady"

    // Computed properties for cleaner UI bindings
    var isConnected: Bool {
        return self != .notConnected
    }

    var canReceiveCommands: Bool {
        return self == .readyForCommands || self == .dataReady
    }

    var hasTelemetry: Bool {
        return self == .dataReady
    }
}

// MARK: - Three-Channel Data Architecture

/// Position data from Type 1 BLE packets - balloon location and motion
struct PositionData {
    var sondeName: String = ""
    var latitude: Double = 0.0
    var longitude: Double = 0.0
    var altitude: Double = 0.0
    var verticalSpeed: Double = 0.0
    var horizontalSpeed: Double = 0.0
    var heading: Double = 0.0
    var temperature: Double = 0.0
    var humidity: Double = 0.0
    var pressure: Double = 0.0
    var timestamp: Date = Date()
    var apiCallTimestamp: Date? = nil
    var burstKillerTime: Int = 0
    var telemetrySource: TelemetrySource = .ble
}

/// Radio channel data from Type 0, 1, 2 BLE packets - device radio status (includes shared Type 1 fields)
struct RadioChannelData {
    var sondeName: String = ""
    var timestamp: Date = Date()
    var telemetrySource: TelemetrySource = .ble

    // Runtime radio data (including shared fields from Type 1 and Type 3)
    var probeType: String = ""          // Shared: Type 1 + Type 3
    var frequency: Double = 0.0         // Shared: Type 1 + Type 3
    var softwareVersion: String = ""    // Shared: Type 1 + Type 3
    var batteryVoltage: Double = 0.0
    var batteryPercentage: Int = 0
    var signalStrength: Int = 0
    var buzmute: Bool = false
    var afcFrequency: Int = 0
    var burstKillerEnabled: Bool = false
    var burstKillerTime: Int = 0
}

/// Settings data from Type 3 BLE packets - pure device configuration (no Type 1 field overlap)
struct SettingsData {
    var sondeName: String = ""
    var timestamp: Date = Date()
    var telemetrySource: TelemetrySource = .ble

    // Pure Type 3 configuration fields (not in Type 1)
    var oledSDA: Int = 21
    var oledSCL: Int = 22
    var oledRST: Int = 16
    var ledPin: Int = 25
    var RS41Bandwidth: Int = 1
    var M20Bandwidth: Int = 7
    var M10Bandwidth: Int = 7
    var PILOTBandwidth: Int = 7
    var DFMBandwidth: Int = 6
    var frequencyCorrection: Int = 0
    var batPin: Int = 35
    var batMin: Int = 2950
    var batMax: Int = 4180
    var batType: Int = 1
    var lcdType: Int = 0
    var nameType: Int = 0
    var buzPin: Int = 0
    var callSign: String = ""
    var bluetoothStatus: Int = 1
    var lcdStatus: Int = 1
    var serialSpeed: Int = 115200
    var serialPort: Int = 0
    var aprsName: Int = 0
    // Additional Type 3 specific fields can be added here
}

// TelemetryData struct completely removed - app now uses pure three-channel architecture

struct LocationData {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let heading: Double
    let timestamp: Date
}

struct BalloonTrackPoint: Codable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let verticalSpeed: Double
    let horizontalSpeed: Double
    /// Which source delivered this sample. Optional so tracks persisted before
    /// source tracking existed still decode (as nil). Informational — dedup keys
    /// on position, not this.
    var source: TelemetrySource? = nil

    /// Physical-position identity, used to deduplicate the track.
    ///
    /// BLE and APRS decode the *same* sonde frame, so they report identical
    /// GPS position — but BLE stamps arrival time while APRS carries the sonde's
    /// frame time, and the two differ by the relay latency (~17 s observed). So
    /// time cannot identify a sample across sources; position can. Rounded to
    /// ~1 m (5 decimals lat/lon, 1 m altitude): two decodes of one frame collide,
    /// while distinct 1 Hz descent samples (several metres apart) do not.
    /// See FSD *Track Assembly → Deduplication*.
    var positionKey: String {
        String(format: "%.5f,%.5f,%.0f", latitude, longitude, altitude)
    }
}

extension Array where Element == BalloonTrackPoint {
    /// Merge `incoming` points into this track, skipping any whose physical
    /// position is already present, and return the result in chronological order.
    ///
    /// This is what makes gap-filling from APRS safe while BLE flaps in and out:
    /// a genuine gap (no point at that position) is filled, but an APRS copy of a
    /// point BLE already laid down is recognized by position and dropped — no
    /// matter that its timestamp differs by the relay latency.
    func mergingByPosition(_ incoming: [BalloonTrackPoint]) -> [BalloonTrackPoint] {
        var occupied = Set(map { $0.positionKey })
        var result = self
        for point in incoming where !occupied.contains(point.positionKey) {
            occupied.insert(point.positionKey)
            result.append(point)
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }
}

struct BalloonMotionMetrics {
    let rawHorizontalSpeedMS: Double
    let rawVerticalSpeedMS: Double
    let smoothedHorizontalSpeedMS: Double
    let smoothedVerticalSpeedMS: Double
    let adjustedDescentRateMS: Double?
}

struct FrequencySyncProposal: Identifiable, Equatable {
    let id = UUID()
    let frequency: Double
    let probeType: String
    let sondeName: String  // Track which sonde triggered this proposal
}

struct AFCData {
    let currentFrequency: Double
    let smoothedFrequency: Double
}

struct PredictionData {
    let path: [CLLocationCoordinate2D]?
    let burstPoint: CLLocationCoordinate2D?
    let landingPoint: CLLocationCoordinate2D?
    let landingTime: Date?
    let launchPoint: CLLocationCoordinate2D?
    let burstAltitude: Double?
    let flightTime: TimeInterval?
    let metadata: [String: Any]?
}

enum LandingPredictionSource: String, Codable {
    case sondehub
    case manual
}

struct LandingPredictionPoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let predictedAt: Date
    let landingEta: Date?
    let source: LandingPredictionSource

    init(coordinate: CLLocationCoordinate2D, predictedAt: Date, landingEta: Date?, source: LandingPredictionSource) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.predictedAt = predictedAt
        self.landingEta = landingEta
        self.source = source
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distance(from other: LandingPredictionPoint) -> CLLocationDistance {
        coordinate.distance(from: other.coordinate)
    }
}

struct RouteData {
    let coordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let transportType: TransportationMode
}

struct MapAnnotationItem: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let title: String
    let type: AnnotationType
    
    enum AnnotationType {
        case balloon
        case user
        case landing
        case burst
    }
}

// MARK: - Application Logging

enum LogCategory: String {
    case event = "Event"
    case service = "Service"
    case ui = "UI"
    case cache = "Cache"
    case general = "General"
    case persistence = "Persistence"
    case ble = "BLE"
    case lifecycle = "Lifecycle"
}

nonisolated func appLog(_ message: String, category: LogCategory, level: OSLogType = .default) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timestamp = formatter.string(from: Date.now)
    let timestampedMessage = "[\(timestamp)] \(message)"

    let logger = Logger(subsystem: "com.yourcompany.BalloonHunter", category: category.rawValue)

    switch level {
    case OSLogType.debug: logger.debug("\(timestampedMessage, privacy: .public)")
    case OSLogType.info: logger.info("\(timestampedMessage, privacy: .public)")
    case OSLogType.error: logger.error("\(timestampedMessage, privacy: .public)")
    case OSLogType.fault: logger.fault("\(timestampedMessage, privacy: .public)")
    default: logger.log("\(timestampedMessage, privacy: .public)")
    }

    // Mirror to a single on-device file — the one log we pull for diagnosis,
    // exactly what the Xcode console shows, so there is no need for the
    // multi-GB unified-log archive. Rotated so it never grows without bound.
    AppLogFile.shared.write("\(timestamp),\(category.rawValue),\(levelName(level)),\(csvEscape(message))")
}

private func levelName(_ level: OSLogType) -> String {
    switch level {
    case .debug: return "debug"
    case .info: return "info"
    case .error: return "error"
    case .fault: return "fault"
    default: return "log"
    }
}

private func csvEscape(_ s: String) -> String {
    (s.contains(",") || s.contains("\"") || s.contains("\n"))
        ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        : s
}

/// The single diagnostic log file (`balloonhunter.log.csv` in the app
/// container): every `appLog` line, the same content as the Xcode console.
/// Thread-safe, size-capped — when it passes the ceiling the oldest half is
/// dropped, so it stays small and pullable without the unified-log archive.
final class AppLogFile: @unchecked Sendable {
    static let shared = AppLogFile()
    private init() {}

    private let queue = DispatchQueue(label: "com.balloonhunter.applogfile")
    private let maxBytes = 512 * 1024
    private lazy var url: URL? = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("balloonhunter.log.csv")

    func write(_ line: String) {
        queue.async { [self] in
            guard let url else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                try? "timestamp,category,level,message\n".data(using: .utf8)?.write(to: url)
            }
            if let data = (line + "\n").data(using: .utf8), let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                _ = try? h.write(contentsOf: data)
            }
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > maxBytes,
               let content = try? String(contentsOf: url, encoding: .utf8) {
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                guard lines.count > 3 else { return }
                let kept = [lines.first ?? "timestamp,category,level,message"] + Array(lines.dropFirst().suffix(lines.count / 2))
                try? kept.joined(separator: "\n").data(using: .utf8)?.write(to: url)
            }
        }
    }
}

// MARK: - Support Types

enum PredictionError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case noData
    case networkUnavailable(String)
    case decodingError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from prediction service"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .noData:
            return "No data received"
        case .networkUnavailable(let reason):
            return "Network unavailable: \(reason)"
        case .decodingError(let description):
            return "JSON decoding failed: \(description)"
        }
    }
}

enum RouteError: Error, LocalizedError {
    case noRouteFound
    case invalidLocation
    
    var errorDescription: String? {
        switch self {
        case .noRouteFound:
            return "No route could be calculated"
        case .invalidLocation:
            return "Invalid location coordinates"
        }
    }
}

extension CLLocationCoordinate2D {
    func distance(from other: CLLocationCoordinate2D) -> CLLocationDistance {
        let loc1 = CLLocation(latitude: latitude, longitude: longitude)
        let loc2 = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return loc1.distance(from: loc2)
    }
}
