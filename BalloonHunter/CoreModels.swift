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
}

enum TelemetrySource: String, Codable {
    case ble
    case aprs
}

struct TelemetryData {
    var sondeName: String = ""
    var probeType: String = ""
    var frequency: Double = 0.0
    var latitude: Double = 0.0
    var longitude: Double = 0.0
    var altitude: Double = 0.0
    var verticalSpeed: Double = 0.0
    var horizontalSpeed: Double = 0.0
    var heading: Double = 0.0
    var temperature: Double = 0.0
    var humidity: Double = 0.0
    var pressure: Double = 0.0
    var batteryVoltage: Double = 0.0
    var batteryPercentage: Int = 0
    var signalStrength: Int = 0
    var timestamp: Date = Date()
    var buzmute: Bool = false
    var afcFrequency: Int = 0
    var burstKillerEnabled: Bool = false
    var burstKillerTime: Int = 0
    var softwareVersion: String = ""
    
    mutating func parse(message: String) {
        let components = message.components(separatedBy: "/")
        guard components.count > 3 else { return }
        
        let packetType = components[0]
        timestamp = Date()
        
        switch packetType {
        case "0":
            guard components.count >= 8 else { return }
            probeType = normalizeProbeType(components[1])
            frequency = Double(components[2]) ?? 0.0
            signalStrength = Int(Double(components[3]) ?? 0.0)
            batteryPercentage = Int(components[4]) ?? 0
            batteryVoltage = Double(components[5]) ?? 0.0
            buzmute = components[6] == "1"
            softwareVersion = components[7]
            
        case "1":
            guard components.count >= 20 else { return }
            probeType = normalizeProbeType(components[1])
            frequency = Double(components[2]) ?? 0.0
            sondeName = components[3]
            latitude = Double(components[4]) ?? 0.0
            longitude = Double(components[5]) ?? 0.0
            altitude = Double(components[6]) ?? 0.0
            horizontalSpeed = Double(components[7]) ?? 0.0
            verticalSpeed = Double(components[8]) ?? 0.0
            signalStrength = Int(Double(components[9]) ?? 0.0)
            batteryPercentage = Int(components[10]) ?? 0
            afcFrequency = Int(components[11]) ?? 0
            burstKillerEnabled = components[12] == "1"
            burstKillerTime = Int(components[13]) ?? 0
            batteryVoltage = Double(components[14]) ?? 0.0
            buzmute = components[15] == "1"
            softwareVersion = components[19]
            
        case "2":
            guard components.count >= 10 else { return }
            probeType = normalizeProbeType(components[1])
            frequency = Double(components[2]) ?? 0.0
            sondeName = components[3]
            signalStrength = Int(Double(components[4]) ?? 0.0)
            batteryPercentage = Int(components[5]) ?? 0
            afcFrequency = Int(components[6]) ?? 0
            batteryVoltage = Double(components[7]) ?? 0.0
            buzmute = components[8] == "1"
            softwareVersion = components[9]
            latitude = 0.0
            longitude = 0.0
            altitude = 0.0
            horizontalSpeed = 0.0
            verticalSpeed = 0.0
            
        default:
            break
        }
    }
    
    private func normalizeProbeType(_ input: String) -> String {
        let upperCaseType = input.uppercased()
        switch upperCaseType {
        case "PIL":
            return "PILOT"
        default:
            return upperCaseType
        }
    }
}

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
