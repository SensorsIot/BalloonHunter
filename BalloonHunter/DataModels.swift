import Foundation
import SwiftUI
import MapKit
import Combine
import OSLog

// MARK: - Custom Codable Wrappers

struct CodableCoordinate: Codable {
    let latitude: Double
    let longitude: Double
    
    nonisolated init(_ coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
    
    nonisolated var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Compares two CLLocationCoordinate2D values for equality by latitude and longitude only.
@inline(__always)
func coordinatesEqual(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
    lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
}

extension CLLocationCoordinate2D {
    func bearing(to otherCoordinate: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = self.latitude.degreesToRadians
        let lon1 = self.longitude.degreesToRadians

        let lat2 = otherCoordinate.latitude.degreesToRadians
        let lon2 = otherCoordinate.longitude.degreesToRadians

        let dLon = lon2 - lon1

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        let radiansBearing = atan2(y, x)

        return radiansBearing.radiansToDegrees // Convert to degrees
    }
}

extension Double {
    var degreesToRadians: Double { return self * .pi / 180 }
    var radiansToDegrees: Double { return self * 180 / .pi }
}

enum AppState: String {
    case startup
    case longRangeTracking
}

enum AppMode: String, CaseIterable, Identifiable, Codable {
    case explore
    case follow
    case finalApproach
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .explore:
            return "Explore"
        case .follow:
            return "Follow"
        case .finalApproach:
            return "Final Approach"
        }
    }
}

class SharedAppState {
    static let shared = SharedAppState()
    private init() {}
    var appState: AppState = .startup
}

// MARK: - Core Data Models from FSD

// 7. Data Structures (Models)

// Represents the detailed configuration parameters of the sonde device.
struct DeviceSettings: Codable, Equatable {
    var sondeType: String = "RS41"
    var frequency: Double = 403.500
    var oledSDA: Int = 21
    var oledSCL: Int = 22
    var oledRST: Int = 16
    var ledPin: Int = 25
    var RS41Bandwidth: Int = 1
    var M20Bandwidth: Int = 7
    var M10Bandwidth: Int = 7
    var PILOTBandwidth: Int = 7
    var DFMBandwidth: Int = 6
    var callSign: String = "MYCALL"
    var frequencyCorrection: Int = 0
    var batPin: Int = 35
    var batMin: Int = 2950
    var batMax: Int = 4180
    var batType: Int = 1
    var lcdType: Int = 0
    var nameType: Int = 0
    var buzPin: Int = 0
    var lcdStatus: Int = 1
    var bluetoothStatus: Int = 1
    var serialSpeed: Int = 1
    var serialPort: Int = 0
    var aprsName: Int = 0
    var softwareVersion: String = "0.0"

    static var `default`: DeviceSettings {
        DeviceSettings()
    }

    mutating func parse(message: String) {
        let components = message.components(separatedBy: "/")
        guard components.count >= 22, components[0] == "3" else { return }

        self.sondeType = components[1]
        self.frequency = Double(components[2]) ?? 0.0
        self.oledSDA = Int(components[3]) ?? 0
        self.oledSCL = Int(components[4]) ?? 0
        self.oledRST = Int(components[5]) ?? 0
        self.ledPin = Int(components[6]) ?? 0
        self.RS41Bandwidth = Int(components[7]) ?? 0
        self.M20Bandwidth = Int(components[8]) ?? 0
        self.M10Bandwidth = Int(components[9]) ?? 0
        self.PILOTBandwidth = Int(components[10]) ?? 0
        self.DFMBandwidth = Int(components[11]) ?? 0
        self.callSign = components[12]
        self.frequencyCorrection = Int(components[13]) ?? 0
        self.batPin = Int(components[14]) ?? 0
        self.batMin = Int(components[15]) ?? 0
        self.batMax = Int(components[16]) ?? 0
        self.batType = Int(components[17]) ?? 0
        self.lcdType = Int(components[18]) ?? 0
        self.nameType = Int(components[19]) ?? 0
        self.buzPin = Int(components[20]) ?? 0
        self.softwareVersion = components[21]
    }
}

// MARK: - MySondyGo Message Types

// Type 0: Device status (no probe received)
struct DeviceStatusData {
    let probeType: String
    let frequency: Double
    let rssi: Double
    let batPercentage: Int
    let batVoltage: Int
    let buzmute: Bool
    let softwareVersion: String
}

// Type 2: Name only (no coordinates available)  
struct NameOnlyData {
    let probeType: String
    let frequency: Double
    let sondeName: String
    let rssi: Double
    let batPercentage: Int
    let afcFrequency: Int
    let batVoltage: Int
    let buzmute: Bool
    let softwareVersion: String
}

extension DeviceSettings {
    var probeTypeCode: Int {
        switch sondeType.uppercased() {
        case "RS41": return 1
        case "M20": return 2
        case "M10": return 3
        case "PILOT": return 4
        case "DFM": return 5
        default: return 1
        }
    }

    func toCommandString() -> String {
        return "3/\(probeTypeCode)/\(String(format: "%.3f", frequency))/\(oledSDA)/\(oledSCL)/\(oledRST)/\(ledPin)/\(RS41Bandwidth)/\(M20Bandwidth)/\(M10Bandwidth)/\(PILOTBandwidth)/\(DFMBandwidth)/\(callSign)/\(frequencyCorrection)/\(batPin)/\(batMin)/\(batMax)/\(batType)/\(lcdType)/\(nameType)/\(buzPin)/\(softwareVersion)"
    }
}

// A class intended to hold prediction-related data that can be shared across the app
class PredictionInfo: ObservableObject {
    @Published var landingTime: Date?
    @Published var arrivalTime: Date?
    @Published var routeDistanceMeters: Double?
}

// A comprehensive class representing a single telemetry data point from the sonde
struct TelemetryData: Identifiable, Equatable, Codable {
    static func == (lhs: TelemetryData, rhs: TelemetryData) -> Bool {
        lhs.latitude == rhs.latitude &&
        lhs.longitude == rhs.longitude &&
        lhs.altitude == rhs.altitude &&
        lhs.signalStrength == rhs.signalStrength &&
        lhs.batteryPercentage == rhs.batteryPercentage &&
        lhs.firmwareVersion == rhs.firmwareVersion &&
        lhs.sondeName == rhs.sondeName &&
        lhs.probeType == rhs.probeType &&
        lhs.frequency == rhs.frequency &&
        lhs.horizontalSpeed == rhs.horizontalSpeed &&
        lhs.verticalSpeed == rhs.verticalSpeed &&
        lhs.afcFrequency == rhs.afcFrequency &&
        lhs.burstKillerEnabled == rhs.burstKillerEnabled &&
        lhs.burstKillerTime == rhs.burstKillerTime &&
        lhs.batVoltage == rhs.batVoltage &&
        lhs.buzmute == rhs.buzmute
    }

    let id: UUID
    var latitude: Double = 0.0
    var longitude: Double = 0.0
    var altitude: Double = 0.0
    var signalStrength: Double = 0.0
    var batteryPercentage: Int = 0
    var firmwareVersion: String = ""
    var sondeName: String = ""
    var probeType: String = ""
    var frequency: Double = 0.0
    var horizontalSpeed: Double = 0.0
    var verticalSpeed: Double = 0.0
    var afcFrequency: Int = 0
    var burstKillerEnabled: Bool = false
    var burstKillerTime: Int = 0
    var batVoltage: Int = 0
    var buzmute: Bool = false
    var lastUpdateTime: TimeInterval? = nil
    
    // Default initializer
    init() {
        self.id = UUID()
    }
    
    // Codable implementation
    private enum CodingKeys: String, CodingKey {
        case latitude, longitude, altitude, signalStrength, batteryPercentage
        case firmwareVersion, sondeName, probeType, frequency, horizontalSpeed
        case verticalSpeed, afcFrequency, burstKillerEnabled, burstKillerTime
        case batVoltage, buzmute, lastUpdateTime
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(altitude, forKey: .altitude)
        try container.encode(signalStrength, forKey: .signalStrength)
        try container.encode(batteryPercentage, forKey: .batteryPercentage)
        try container.encode(firmwareVersion, forKey: .firmwareVersion)
        try container.encode(sondeName, forKey: .sondeName)
        try container.encode(probeType, forKey: .probeType)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(horizontalSpeed, forKey: .horizontalSpeed)
        try container.encode(verticalSpeed, forKey: .verticalSpeed)
        try container.encode(afcFrequency, forKey: .afcFrequency)
        try container.encode(burstKillerEnabled, forKey: .burstKillerEnabled)
        try container.encode(burstKillerTime, forKey: .burstKillerTime)
        try container.encode(batVoltage, forKey: .batVoltage)
        try container.encode(buzmute, forKey: .buzmute)
        try container.encodeIfPresent(lastUpdateTime, forKey: .lastUpdateTime)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.latitude = try container.decode(Double.self, forKey: .latitude)
        self.longitude = try container.decode(Double.self, forKey: .longitude)
        self.altitude = try container.decode(Double.self, forKey: .altitude)
        self.signalStrength = try container.decode(Double.self, forKey: .signalStrength)
        self.batteryPercentage = try container.decode(Int.self, forKey: .batteryPercentage)
        self.firmwareVersion = try container.decode(String.self, forKey: .firmwareVersion)
        self.sondeName = try container.decode(String.self, forKey: .sondeName)
        self.probeType = try container.decode(String.self, forKey: .probeType)
        self.frequency = try container.decode(Double.self, forKey: .frequency)
        self.horizontalSpeed = try container.decode(Double.self, forKey: .horizontalSpeed)
        self.verticalSpeed = try container.decode(Double.self, forKey: .verticalSpeed)
        self.afcFrequency = try container.decode(Int.self, forKey: .afcFrequency)
        self.burstKillerEnabled = try container.decode(Bool.self, forKey: .burstKillerEnabled)
        self.burstKillerTime = try container.decode(Int.self, forKey: .burstKillerTime)
        self.batVoltage = try container.decode(Int.self, forKey: .batVoltage)
        self.buzmute = try container.decode(Bool.self, forKey: .buzmute)
        self.lastUpdateTime = try container.decodeIfPresent(TimeInterval.self, forKey: .lastUpdateTime)
    }
    
    private enum Type0Index: Int {
        case probeType = 1, frequency, signalStrength, batteryPercentage, batVoltage, buzmute, firmwareVersion
    }
    
    private enum Type1Index: Int {
        case probeType = 1, frequency, sondeName, latitude, longitude, altitude, horizontalSpeed, verticalSpeed, signalStrength, batteryPercentage, afcFrequency, burstKillerEnabled, burstKillerTime, batVoltage, buzmute
        case firmwareVersion = 19
    }
    
    private enum Type2Index: Int {
        case probeType = 1, frequency, sondeName, signalStrength, batteryPercentage, afcFrequency, batVoltage, buzmute, firmwareVersion
    }

    // Method to parse different types of telemetry messages
    mutating func parse(message: String) {
        let components = message.components(separatedBy: "/")
        guard components.count > 1 else { return }
        
        let messageType = components[0]
        
        switch messageType {
        case "0":
            parseType0(components: components)
        case "1":
            parseType1(components: components)
        case "2":
            parseType2(components: components)
        case "3":
            // Type 3 is configuration, not telemetry for this model
            break
        default:
            break
        }
    }
    
    private mutating func parseType0(components: [String]) {
        guard components.count >= 8 else { return }
        self.probeType = components[Type0Index.probeType.rawValue]
        self.frequency = Double(components[Type0Index.frequency.rawValue]) ?? 0.0
        self.signalStrength = Double(components[Type0Index.signalStrength.rawValue]) ?? 0.0
        self.batteryPercentage = Int(components[Type0Index.batteryPercentage.rawValue]) ?? 0
        self.batVoltage = Int(components[Type0Index.batVoltage.rawValue]) ?? 0
        self.buzmute = (components[Type0Index.buzmute.rawValue] == "1")
        self.firmwareVersion = components[Type0Index.firmwareVersion.rawValue]
    }
    
    private mutating func parseType1(components: [String]) {
        guard components.count >= 20 else { return }
        // print("[DEBUG][TelemetryData] Received type 1 packet: \(components.joined(separator: ", "))")
        self.probeType = components[Type1Index.probeType.rawValue]
        self.frequency = Double(components[Type1Index.frequency.rawValue]) ?? 0.0
        self.sondeName = components[Type1Index.sondeName.rawValue]
        self.latitude = Double(components[Type1Index.latitude.rawValue]) ?? 0.0
        self.longitude = Double(components[Type1Index.longitude.rawValue]) ?? 0.0
        self.altitude = Double(components[Type1Index.altitude.rawValue]) ?? 0.0
        self.horizontalSpeed = Double(components[Type1Index.horizontalSpeed.rawValue]) ?? 0.0
        self.verticalSpeed = Double(components[Type1Index.verticalSpeed.rawValue]) ?? 0.0
        self.signalStrength = Double(components[Type1Index.signalStrength.rawValue]) ?? 0.0
        self.batteryPercentage = Int(components[Type1Index.batteryPercentage.rawValue]) ?? 0
        self.afcFrequency = Int(components[Type1Index.afcFrequency.rawValue]) ?? 0
        self.burstKillerEnabled = (components[Type1Index.burstKillerEnabled.rawValue] == "1")
        self.burstKillerTime = Int(components[Type1Index.burstKillerTime.rawValue]) ?? 0
        self.batVoltage = Int(components[Type1Index.batVoltage.rawValue]) ?? 0
        self.buzmute = (components[Type1Index.buzmute.rawValue] == "1")
        self.firmwareVersion = components[Type1Index.firmwareVersion.rawValue]
        self.lastUpdateTime = Date().timeIntervalSince1970
    }
    
    private mutating func parseType2(components: [String]) {
        guard components.count >= 10 else { return }
        self.probeType = components[Type2Index.probeType.rawValue]
        self.frequency = Double(components[Type2Index.frequency.rawValue]) ?? 0.0
        self.sondeName = components[Type2Index.sondeName.rawValue]
        self.signalStrength = Double(components[Type2Index.signalStrength.rawValue]) ?? 0.0
        self.batteryPercentage = Int(components[Type2Index.batteryPercentage.rawValue]) ?? 0
        self.afcFrequency = Int(components[Type2Index.afcFrequency.rawValue]) ?? 0
        self.batVoltage = Int(components[Type2Index.batVoltage.rawValue]) ?? 0
        self.buzmute = (components[Type2Index.buzmute.rawValue] == "1")
        self.firmwareVersion = components[Type2Index.firmwareVersion.rawValue]
    }
}

// A struct that serves as a lightweight, serializable representation of a balloon track point
struct BalloonTrackPoint: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var timestamp: Date

    init(telemetryData: TelemetryData) {
        self.latitude = telemetryData.latitude
        self.longitude = telemetryData.longitude
        self.altitude = telemetryData.altitude
        self.timestamp = telemetryData.lastUpdateTime != nil ? Date(timeIntervalSince1970: telemetryData.lastUpdateTime!) : Date() // Use the time from telemetryData if possible
    }
}

// A Codable and Equatable struct used for representing the settings received from or sent to the BLE device.
struct SondeSettingsTransferData: Codable, Equatable {
    var sondeType: String
    var frequency: Double
}

// A Identifiable struct used to represent markers on the map.
final class MapAnnotationItem: ObservableObject, Identifiable, Equatable {
    @Published var coordinate: CLLocationCoordinate2D
    @Published var kind: AnnotationKind
    @Published var isAscending: Bool? = nil
    @Published var status: AnnotationStatus = .fresh
    @Published var lastUpdateTime: Date? = nil
    @Published var altitude: Double? = nil

    enum AnnotationKind: Equatable {
        case user
        case balloon
        case burst
        case landing
        case landed
    }
    
    enum AnnotationStatus: Equatable {
        case fresh
        case stale
    }
    
    var id: String {
        switch kind {
        case .user: return "user_annotation"
        case .balloon: return "balloon_annotation"
        case .burst: return "burst_annotation"
        case .landing: return "landing_annotation"
        case .landed: return "landed_annotation"
        }
    }
    
    // For classes, Equatable needs to compare content, not just references.
    static func == (lhs: MapAnnotationItem, rhs: MapAnnotationItem) -> Bool {
        return coordinatesEqual(lhs.coordinate, rhs.coordinate) &&
            lhs.kind == rhs.kind &&
            lhs.isAscending == rhs.isAscending &&
            lhs.status == rhs.status &&
            lhs.lastUpdateTime == rhs.lastUpdateTime &&
            lhs.altitude == rhs.altitude
    }

    init(coordinate: CLLocationCoordinate2D, kind: AnnotationKind, isAscending: Bool? = nil, status: AnnotationStatus = .fresh, lastUpdateTime: Date? = nil, altitude: Double? = nil) {
        self.coordinate = coordinate
        self.kind = kind
        self.isAscending = isAscending
        self.status = status
        self.lastUpdateTime = lastUpdateTime
        self.altitude = altitude
    }
    
    @ViewBuilder
    var view: some View {
        switch kind {
        case .user:
            Image(systemName: "figure.walk")
                .foregroundColor(.blue)
                .font(.title) // Increased size
        case .balloon:
            let color: Color = {
                if let isAscending = isAscending {
                    return isAscending ? .green : .red
                } else {
                    return .gray // Default or unknown state
                }
            }()
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 76, height: 76)
                    .overlay(
                        Image(systemName: "balloon.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundColor(.white)
                            .frame(width: 76, height: 76)
                    )
                if let altitude = altitude {
                    Text("\(Int(altitude))")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .shadow(color: .white.opacity(0.8), radius: 5, x: 0, y: 0)
                        .padding(.top, 8)
                        .frame(width: 54, height: 28, alignment: .center)
                        .position(x: 38, y: 28) // upper third
                }
            }
        case .burst:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title)
        case .landing:
            Image(systemName: "mappin.and.ellipse")
                .foregroundColor(.purple)
                .font(.title)
        case .landed:
            Image(systemName: "balloon.fill")
                .foregroundColor(.blue)
                .font(.title)
        }
    }
}

// A simple enum to represent the user's preferred mode of transport for route calculations.
enum TransportationMode: Sendable, Equatable {
    case car
    case bike

    var identifier: String {
        switch self {
        case .car: return "car"
        case .bike: return "bike"
        }
    }

    nonisolated static func == (lhs: TransportationMode, rhs: TransportationMode) -> Bool {
        switch (lhs, rhs) {
        case (.car, .car): return true
        case (.bike, .bike): return true
        default: return false
        }
    }
}

// Additional models from the FSD that are useful
struct LocationData: Equatable {
    var latitude: Double
    var longitude: Double
    var heading: Double
}

struct PredictionData: Equatable, Codable {
    var path: [CLLocationCoordinate2D]?
    var burstPoint: CLLocationCoordinate2D?
    var landingPoint: CLLocationCoordinate2D?
    var landingTime: Date?
    var latestTelemetry: TelemetryData?
    var version: Int = 0
    
    var isDescending: Bool {
        guard let telemetry = self.latestTelemetry else { return false }
        return telemetry.verticalSpeed < 0
    }
    
    init(path: [CLLocationCoordinate2D]? = nil,
         burstPoint: CLLocationCoordinate2D? = nil,
         landingPoint: CLLocationCoordinate2D? = nil,
         landingTime: Date? = nil,
         latestTelemetry: TelemetryData? = nil) {
        self.path = path
        self.burstPoint = burstPoint
        self.landingPoint = landingPoint
        self.landingTime = landingTime
        self.latestTelemetry = latestTelemetry
    }

    static func == (lhs: PredictionData, rhs: PredictionData) -> Bool {
        let pathsEqual: Bool
        if let lhsPath = lhs.path, let rhsPath = rhs.path {
            pathsEqual = lhsPath.elementsEqual(rhsPath, by: coordinatesEqual)
        } else {
            pathsEqual = lhs.path == nil && rhs.path == nil
        }

        let burstPointsEqual: Bool
        if let lhsBurst = lhs.burstPoint, let rhsBurst = rhs.burstPoint {
            burstPointsEqual = coordinatesEqual(lhsBurst, rhsBurst)
        } else {
            burstPointsEqual = lhs.burstPoint == nil && rhs.burstPoint == nil
        }

        let landingPointsEqual: Bool
        if let lhsLanding = lhs.landingPoint, let rhsLanding = rhs.landingPoint {
            landingPointsEqual = coordinatesEqual(lhsLanding, rhsLanding)
        } else {
            landingPointsEqual = lhs.landingPoint == nil && rhs.landingPoint == nil
        }

        return pathsEqual && burstPointsEqual && landingPointsEqual && lhs.landingTime == rhs.landingTime && lhs.latestTelemetry == rhs.latestTelemetry
    }
    
    // Custom Codable implementation to handle CLLocationCoordinate2D fields
    private enum CodingKeys: String, CodingKey {
        case path, burstPoint, landingPoint, landingTime, latestTelemetry, version
    }
    
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(path?.map(CodableCoordinate.init), forKey: .path)
        try container.encodeIfPresent(burstPoint.map(CodableCoordinate.init), forKey: .burstPoint)
        try container.encodeIfPresent(landingPoint.map(CodableCoordinate.init), forKey: .landingPoint)
        try container.encodeIfPresent(landingTime, forKey: .landingTime)
        try container.encodeIfPresent(latestTelemetry, forKey: .latestTelemetry)
        try container.encode(version, forKey: .version)
    }
    
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pathCodable = try container.decodeIfPresent([CodableCoordinate].self, forKey: .path)
        self.path = pathCodable?.map { $0.coordinate }
        let burstPointCodable = try container.decodeIfPresent(CodableCoordinate.self, forKey: .burstPoint)
        self.burstPoint = burstPointCodable?.coordinate
        let landingPointCodable = try container.decodeIfPresent(CodableCoordinate.self, forKey: .landingPoint)
        self.landingPoint = landingPointCodable?.coordinate
        self.landingTime = try container.decodeIfPresent(Date.self, forKey: .landingTime)
        self.latestTelemetry = try container.decodeIfPresent(TelemetryData.self, forKey: .latestTelemetry)
        self.version = try container.decode(Int.self, forKey: .version)
    }
}

enum PredictionStatus: Equatable {
    case success
    case fetching
    case noValidPrediction // Initial state or when parsing fails to yield a valid prediction
    case error(String) // Network error or explicit API error
}

struct RouteData: Equatable {
    var path: [CLLocationCoordinate2D]?
    var distance: Double // in meters
    var expectedTravelTime: TimeInterval // in seconds
    var version: Int = 0

    static func == (lhs: RouteData, rhs: RouteData) -> Bool {
        let pathsEqual: Bool
        if let lhsPath = lhs.path, let rhsPath = rhs.path {
            pathsEqual = lhsPath.elementsEqual(rhsPath, by: coordinatesEqual)
        } else {
            pathsEqual = lhs.path == nil && rhs.path == nil
        }
        return pathsEqual && lhs.distance == rhs.distance && lhs.expectedTravelTime == rhs.expectedTravelTime
    }
}

extension RouteData {
    var arrivalTime: Date? {
        return Date(timeIntervalSinceNow: expectedTravelTime)
    }
}

enum ConnectionStatus {
    case disconnected
    case connecting
    case connected
}

enum ServiceHealth: String, Codable {
    case healthy
    case degraded
    case unhealthy
}

struct AFCData {
    var values: [Int]
}

// Ensured ObservableObject conformance and class type for SwiftUI compatibility.
final class AppSettings: ObservableObject {
    @Published var deviceSettings: DeviceSettings = .default
}

// Ensured ObservableObject conformance and class type for SwiftUI compatibility.
final class UserSettings: ObservableObject, Codable { // Added Codable
    init() { } // Default initializer

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        burstAltitude = try container.decode(Double.self, forKey: .burstAltitude)
        ascentRate = try container.decode(Double.self, forKey: .ascentRate)
        descentRate = try container.decode(Double.self, forKey: .descentRate)
    }
    
    @Published var burstAltitude: Double = 35000.0
    @Published var ascentRate: Double = 5.0
    @Published var descentRate: Double = 5.0

    static var `default`: UserSettings { UserSettings() }

    // Manual Codable implementation because @Published properties are not automatically encoded/decoded
    enum CodingKeys: String, CodingKey {
        case burstAltitude
        case ascentRate
        case descentRate
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(burstAltitude, forKey: .burstAltitude)
        try container.encode(ascentRate, forKey: .ascentRate)
        try container.encode(descentRate, forKey: .descentRate)
    }
}

// MARK: - Notification Extensions

extension NSNotification.Name {
    static let startupCompleted = NSNotification.Name("startupCompleted")
    static let locationReady = NSNotification.Name("locationReady")
}

// MARK: - Map State Management

@MainActor
final class MapState: ObservableObject {
    // Map visual elements
    @Published var annotations: [MapAnnotationItem] = []
    @Published var balloonTrackPath: MKPolyline? = nil
    @Published var predictionPath: MKPolyline? = nil
    @Published var userRoute: MKPolyline? = nil
    @Published var region: MKCoordinateRegion? = nil
    @Published var cameraUpdate: CameraUpdate? = nil
    
    // Data state
    @Published var balloonTelemetry: TelemetryData? = nil
    @Published var userLocation: LocationData? = nil
    @Published var landingPoint: CLLocationCoordinate2D? = nil
    
    // Additional data for DataPanelView
    @Published var predictionData: PredictionData? = nil
    @Published var routeData: RouteData? = nil
    @Published var balloonTrackHistory: [TelemetryData] = []
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var smoothedDescentRate: Double? = nil
    
    // UI state
    @Published var currentMode: AppMode = .explore
    @Published var transportMode: TransportationMode = .car
    @Published var isHeadingMode: Bool = false
    @Published var isPredictionPathVisible: Bool = true
    @Published var isRouteVisible: Bool = true
    @Published var isBuzzerMuted: Bool = false
    @Published var showAllAnnotations: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private var currentVersion: [String: Int] = [:]
    private let maxVersionHistory = 10
    private var lastUpdateTime: [String: Date] = [:]
    
    init() {
        setupEventSubscriptions()
    }
    
    private func setupEventSubscriptions() {
        // Subscribe to map state updates from policies
        EventBus.shared.mapStateUpdatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                self?.applyUpdate(update)
            }
            .store(in: &cancellables)
        
        // Subscribe to telemetry events to update data state
        EventBus.shared.telemetryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.balloonTelemetry = event.telemetryData
            }
            .store(in: &cancellables)
        
        // Subscribe to user location events to update data state
        EventBus.shared.userLocationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.userLocation = event.locationData
            }
            .store(in: &cancellables)
        
        // Subscribe to UI events to update UI state
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUIEvent(event)
            }
            .store(in: &cancellables)
        
        // Subscribe to service health events to track connection status
        EventBus.shared.serviceHealthPublisher
            .receive(on: DispatchQueue.main)
            .sink { event in
                // ServiceHealthEvent doesn't contain connection status data
                // Connection status updates will come through other event channels
                appLog("MapState: Received service health event from \(event.serviceName): \(event.health)", 
                       category: .general, level: .debug)
            }
            .store(in: &cancellables)
    }
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .transportModeChanged(let mode, _):
            updateTransportMode(mode)
        case .predictionVisibilityToggled(let visible, _):
            updatePredictionVisibility(visible)
        case .routeVisibilityToggled(let visible, _):
            updateRouteVisibility(visible)
        case .headingModeToggled(let enabled, _):
            updateHeadingMode(enabled)
        case .buzzerMuteToggled(let muted, _):
            updateBuzzerMute(muted)
        case .showAllAnnotationsRequested(_):
            triggerShowAllAnnotations()
        case .modeSwitched(let mode, _):
            updateMode(mode)
        default:
            break
        }
    }
    
    func applyUpdate(_ update: MapStateUpdate) {
        let currentVer = currentVersion[update.source] ?? -1
        
        if update.version < currentVer {
            appLog("MapState: Ignoring stale update from \(update.source), version \(update.version) < \(currentVer)", 
                   category: .general, level: .debug)
            return
        }
        
        currentVersion[update.source] = update.version
        
        // Track update frequency
        let now = Date.now
        let timeSinceLastUpdate = lastUpdateTime[update.source].map { now.timeIntervalSince($0) } ?? 0
        lastUpdateTime[update.source] = now
        
        appLog("MapState: Applying update from \(update.source), version \(update.version), interval: \(String(format: "%.3f", timeSinceLastUpdate))s", 
               category: .general, level: .debug)
        
        var hasChanges = false
        
        if let newAnnotations = update.annotations {
            if !annotationsEqual(annotations, newAnnotations) {
                annotations = newAnnotations
                hasChanges = true
                appLog("MapState: Updated \(newAnnotations.count) annotations from \(update.source)", 
                       category: .general, level: .debug)
            }
        }
        
        if let newBalloonTrack = update.balloonTrack {
            if !polylinesEqual(balloonTrackPath, newBalloonTrack) {
                balloonTrackPath = newBalloonTrack
                hasChanges = true
                appLog("MapState: Updated balloon track from \(update.source)", 
                       category: .general, level: .debug)
            }
        } else if balloonTrackPath != nil && update.balloonTrack == nil {
            balloonTrackPath = nil
            hasChanges = true
        }
        
        if let newPredictionPath = update.predictionPath {
            if !polylinesEqual(predictionPath, newPredictionPath) {
                predictionPath = newPredictionPath
                hasChanges = true
                appLog("MapState: Updated prediction path from \(update.source)", 
                       category: .general, level: .debug)
            }
        } else if predictionPath != nil && update.predictionPath == nil {
            predictionPath = nil
            hasChanges = true
        }
        
        if let newUserRoute = update.userRoute {
            if !polylinesEqual(userRoute, newUserRoute) {
                userRoute = newUserRoute
                hasChanges = true
                appLog("MapState: Updated user route from \(update.source)", 
                       category: .general, level: .debug)
            }
        } else if userRoute != nil && update.userRoute == nil {
            userRoute = nil
            hasChanges = true
        }
        
        if let newRegion = update.region {
            if !regionsEqual(region, newRegion) {
                region = newRegion
                hasChanges = true
                appLog("MapState: Updated region from \(update.source)", category: .general, level: .debug)
            }
        }
        
        if let newCameraUpdate = update.cameraUpdate {
            cameraUpdate = newCameraUpdate
            hasChanges = true
            appLog("MapState: Updated camera from \(update.source)", 
                   category: .general, level: .debug)
        }
        
        if let newPredictionData = update.predictionData {
            predictionData = newPredictionData
            hasChanges = true
            appLog("MapState: Updated prediction data from \(update.source)", 
                   category: .general, level: .debug)
        }
        
        if let newRouteData = update.routeData {
            routeData = newRouteData
            hasChanges = true
            appLog("MapState: Updated route data from \(update.source)", 
                   category: .general, level: .debug)
        }
        
        if let newTrackHistory = update.balloonTrackHistory {
            balloonTrackHistory = newTrackHistory
            hasChanges = true
            appLog("MapState: Updated track history from \(update.source)", 
                   category: .general, level: .debug)
        }
        
        if let newDescentRate = update.smoothedDescentRate {
            smoothedDescentRate = newDescentRate
            hasChanges = true
            appLog("MapState: Updated smoothed descent rate from \(update.source)", 
                   category: .general, level: .debug)
        }
        
        if hasChanges {
            objectWillChange.send()
        }
    }
    
    func updateMode(_ mode: AppMode) {
        if currentMode != mode {
            currentMode = mode
            appLog("MapState: Mode changed to \(mode.displayName)", 
                   category: .general, level: .info)
        }
    }
    
    func updateTransportMode(_ mode: TransportationMode) {
        if transportMode != mode {
            transportMode = mode
            appLog("MapState: Transport mode changed to \(mode)", 
                   category: .general, level: .info)
        }
    }
    
    func updateHeadingMode(_ enabled: Bool) {
        if isHeadingMode != enabled {
            isHeadingMode = enabled
            appLog("MapState: Heading mode \(enabled ? "enabled" : "disabled")", 
                   category: .general, level: .info)
        }
    }
    
    func updatePredictionVisibility(_ visible: Bool) {
        if isPredictionPathVisible != visible {
            isPredictionPathVisible = visible
            appLog("MapState: Prediction visibility \(visible ? "enabled" : "disabled")", 
                   category: .general, level: .info)
        }
    }
    
    func updateRouteVisibility(_ visible: Bool) {
        if isRouteVisible != visible {
            isRouteVisible = visible
            appLog("MapState: Route visibility \(visible ? "enabled" : "disabled")", 
                   category: .general, level: .info)
        }
    }
    
    func updateBuzzerMute(_ muted: Bool) {
        if isBuzzerMuted != muted {
            isBuzzerMuted = muted
            appLog("MapState: Buzzer \(muted ? "muted" : "unmuted")", 
                   category: .general, level: .info)
        }
    }
    
    func triggerShowAllAnnotations() {
        showAllAnnotations = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.showAllAnnotations = false
        }
    }
    
    func clearCameraUpdate() {
        cameraUpdate = nil
    }
    
    func getStats() -> [String: Any] {
        return [
            "annotationCount": annotations.count,
            "hasBalloonTrack": balloonTrackPath != nil,
            "hasPredictionPath": predictionPath != nil,
            "hasUserRoute": userRoute != nil,
            "currentMode": currentMode.displayName,
            "transportMode": transportMode,
            "isHeadingMode": isHeadingMode,
            "versionCount": currentVersion.count
        ]
    }
}

private func annotationsEqual(_ lhs: [MapAnnotationItem], _ rhs: [MapAnnotationItem]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (a, b) in zip(lhs, rhs) {
        if a != b { return false }
    }
    return true
}

private func polylinesEqual(_ lhs: MKPolyline?, _ rhs: MKPolyline?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case (let lhsPolyline?, let rhsPolyline?):
        guard lhsPolyline.pointCount == rhsPolyline.pointCount else { return false }
        let lhsCoords = lhsPolyline.coordinates
        let rhsCoords = rhsPolyline.coordinates
        for (a, b) in zip(lhsCoords, rhsCoords) {
            if a.latitude != b.latitude || a.longitude != b.longitude { return false }
        }
        return true
    default:
        return false
    }
}

private func regionsEqual(_ lhs: MKCoordinateRegion?, _ rhs: MKCoordinateRegion) -> Bool {
    guard let lhs = lhs else { return false }
    return abs(lhs.center.latitude - rhs.center.latitude) < 0.0001 &&
           abs(lhs.center.longitude - rhs.center.longitude) < 0.0001 &&
           abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < 0.0001 &&
           abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < 0.0001
}

// MARK: - Mode State Machine

@MainActor
final class ModeStateMachine: ObservableObject {
    @Published private(set) var currentMode: AppMode = .explore
    @Published private(set) var modeTransitionHistory: [(AppMode, Date)] = []
    
    private var cancellables = Set<AnyCancellable>()
    private let hysteresisThreshold: TimeInterval = 5.0 // Prevent mode flapping
    private var lastTransitionTime = Date.distantPast
    
    struct ModeThresholds {
        // Follow mode entry thresholds
        static let balloonFlightAltitudeThreshold: Double = 100.0 // meters
        static let balloonSignalStrengthThreshold: Double = -80.0 // dBm
        static let continuousTelemetryDuration: TimeInterval = 30.0 // seconds
        
        // Final approach entry thresholds
        static let lowVerticalSpeedThreshold: Double = 1.0 // m/s
        static let lowAltitudeThreshold: Double = 1000.0 // meters
        static let proximityDistanceThreshold: Double = 1000.0 // meters
        static let finalApproachDuration: TimeInterval = 60.0 // seconds
        
        // Explore mode fallback thresholds
        static let signalLossTimeout: TimeInterval = 300.0 // 5 minutes
        static let maxDistanceFromBalloon: Double = 50000.0 // 50km
    }
    
    private struct ModeContext {
        var balloonAltitude: Double?
        var balloonVerticalSpeed: Double?
        var balloonSignalStrength: Double?
        var distanceToBalloon: Double?
        var lastTelemetryTime: Date?
        var userLocation: LocationData?
        var isBalloonFlying: Bool = false
        var continuousTelemetryStart: Date?
        var lowSpeedStart: Date?
    }
    
    private var context = ModeContext()
    
    init() {
        setupEventSubscriptions()
        recordTransition(to: .explore, reason: "Initial state")
    }
    
    private func setupEventSubscriptions() {
        // Subscribe to telemetry events
        EventBus.shared.telemetryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.updateTelemetryContext(event)
                self?.evaluateTransitions()
            }
            .store(in: &cancellables)
        
        // Subscribe to user location events
        EventBus.shared.userLocationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.updateLocationContext(event)
                self?.evaluateTransitions()
            }
            .store(in: &cancellables)
        
        // Periodic evaluation for timeout-based transitions
        Timer.publish(every: 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.evaluateTransitions()
            }
            .store(in: &cancellables)
    }
    
    private func updateTelemetryContext(_ event: TelemetryEvent) {
        let telemetry = event.telemetryData
        
        context.balloonAltitude = telemetry.altitude
        context.balloonVerticalSpeed = telemetry.verticalSpeed
        context.balloonSignalStrength = telemetry.signalStrength
        context.lastTelemetryTime = Date()
        context.isBalloonFlying = telemetry.altitude > ModeThresholds.balloonFlightAltitudeThreshold
        
        // Track continuous telemetry
        if telemetry.signalStrength > ModeThresholds.balloonSignalStrengthThreshold {
            if context.continuousTelemetryStart == nil {
                context.continuousTelemetryStart = Date()
            }
        } else {
            context.continuousTelemetryStart = nil
        }
        
        // Track low speed duration
        if abs(telemetry.verticalSpeed) < ModeThresholds.lowVerticalSpeedThreshold {
            if context.lowSpeedStart == nil {
                context.lowSpeedStart = Date()
            }
        } else {
            context.lowSpeedStart = nil
        }
        
        // Calculate distance to balloon if user location is available
        if let userLocation = context.userLocation {
            let balloonLocation = CLLocation(latitude: telemetry.latitude, longitude: telemetry.longitude)
            let userCLLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
            context.distanceToBalloon = userCLLocation.distance(from: balloonLocation)
        }
        
        appLog("ModeStateMachine: Updated telemetry context - alt: \(String(format: "%.0f", telemetry.altitude))m, vspeed: \(String(format: "%.1f", telemetry.verticalSpeed))m/s, signal: \(String(format: "%.1f", telemetry.signalStrength))dBm", 
               category: .general, level: .debug)
    }
    
    private func updateLocationContext(_ event: UserLocationEvent) {
        context.userLocation = event.locationData
        
        // Recalculate distance to balloon if telemetry is available
        if let lastTelemetry = context.lastTelemetryTime,
           Date().timeIntervalSince(lastTelemetry) < 60 {
            // Subscribe to balloon position service for distance calculation
            // Note: This would typically be done via EventBus subscription to position updates
            // For now, we set distance to nil until we get balloon coordinates
            context.distanceToBalloon = nil
        }
    }
    
    private func evaluateTransitions() {
        let now = Date()
        
        // Prevent mode flapping
        if now.timeIntervalSince(lastTransitionTime) < hysteresisThreshold {
            return
        }
        
        let newMode = determineOptimalMode()
        
        if newMode != currentMode {
            transitionTo(newMode)
        }
    }
    
    private func determineOptimalMode() -> AppMode {
        let now = Date()
        
        // Check for signal loss - fallback to explore
        if let lastTelemetry = context.lastTelemetryTime,
           now.timeIntervalSince(lastTelemetry) > ModeThresholds.signalLossTimeout {
            return .explore
        }
        
        // Check for extreme distance - fallback to explore
        if let distance = context.distanceToBalloon,
           distance > ModeThresholds.maxDistanceFromBalloon {
            return .explore
        }
        
        // Check for final approach conditions
        if canTransitionToFinalApproach() {
            return .finalApproach
        }
        
        // Check for follow mode conditions
        if canTransitionToFollow() {
            return .follow
        }
        
        // Default to explore mode
        return .explore
    }
    
    private func canTransitionToFollow() -> Bool {
        guard context.isBalloonFlying else { return false }
        
        // Good signal strength
        guard let signalStrength = context.balloonSignalStrength,
              signalStrength > ModeThresholds.balloonSignalStrengthThreshold else { return false }
        
        // Continuous telemetry
        guard let continuousStart = context.continuousTelemetryStart,
              Date().timeIntervalSince(continuousStart) >= ModeThresholds.continuousTelemetryDuration else { return false }
        
        return true
    }
    
    private func canTransitionToFinalApproach() -> Bool {
        guard context.isBalloonFlying else { return false }
        
        let hasLowVerticalSpeed: Bool = {
            guard let lowSpeedStart = context.lowSpeedStart else { return false }
            return Date().timeIntervalSince(lowSpeedStart) >= ModeThresholds.finalApproachDuration
        }()
        
        let isAtLowAltitude: Bool = {
            guard let altitude = context.balloonAltitude else { return false }
            return altitude < ModeThresholds.lowAltitudeThreshold
        }()
        
        let isInProximity: Bool = {
            guard let distance = context.distanceToBalloon else { return false }
            return distance < ModeThresholds.proximityDistanceThreshold
        }()
        
        // Need either low speed for extended period OR (low altitude AND proximity)
        return hasLowVerticalSpeed || (isAtLowAltitude && isInProximity)
    }
    
    private func transitionTo(_ newMode: AppMode) {
        let previousMode = currentMode
        currentMode = newMode
        lastTransitionTime = Date()
        
        recordTransition(to: newMode, reason: getTransitionReason(from: previousMode, to: newMode))
        
        // Publish mode change event
        EventBus.shared.publishUIEvent(.modeSwitched(newMode))
        
        appLog("ModeStateMachine: Transitioned from \(previousMode.displayName) to \(newMode.displayName)", 
               category: .general, level: .info)
        
        // Execute mode-specific entry actions
        executeEntryActions(for: newMode)
    }
    
    private func recordTransition(to mode: AppMode, reason: String) {
        modeTransitionHistory.append((mode, Date()))
        
        // Keep only last 20 transitions
        if modeTransitionHistory.count > 20 {
            modeTransitionHistory.removeFirst()
        }
        
        appLog("ModeStateMachine: Mode transition - \(mode.displayName) (\(reason))", 
               category: .general, level: .info)
    }
    
    private func getTransitionReason(from: AppMode, to: AppMode) -> String {
        switch (from, to) {
        case (_, .explore):
            if context.lastTelemetryTime == nil {
                return "No telemetry data"
            } else if let lastTelemetry = context.lastTelemetryTime,
                      Date().timeIntervalSince(lastTelemetry) > ModeThresholds.signalLossTimeout {
                return "Signal loss timeout"
            } else if let distance = context.distanceToBalloon,
                      distance > ModeThresholds.maxDistanceFromBalloon {
                return "Balloon too far away"
            } else {
                return "Balloon not flying or poor signal"
            }
            
        case (_, .follow):
            return "Good signal and balloon flying"
            
        case (_, .finalApproach):
            if let _ = context.lowSpeedStart {
                return "Low vertical speed detected"
            } else {
                return "Low altitude and close proximity"
            }
        }
    }
    
    private func executeEntryActions(for mode: AppMode) {
        switch mode {
        case .explore:
            // Light fetching mode - reduce update frequency
            break
            
        case .follow:
            // Active tracking mode - enable routing, periodic predictions
            break
            
        case .finalApproach:
            // High frequency updates, tight thresholds, landing preparation
            break
        }
    }
    
    func forceTransition(to mode: AppMode, reason: String = "Manual override") {
        transitionTo(mode)
        recordTransition(to: mode, reason: reason)
    }
    
    func getModeConfig(for mode: AppMode) -> ModeConfiguration {
        switch mode {
        case .explore:
            return ModeConfiguration(
                predictionInterval: 300.0, // 5 minutes
                routingEnabled: false,
                cameraFollowEnabled: false,
                updateFrequency: .low
            )
            
        case .follow:
            return ModeConfiguration(
                predictionInterval: 120.0, // 2 minutes
                routingEnabled: true,
                cameraFollowEnabled: true,
                updateFrequency: .normal
            )
            
        case .finalApproach:
            return ModeConfiguration(
                predictionInterval: 30.0, // 30 seconds
                routingEnabled: true,
                cameraFollowEnabled: true,
                updateFrequency: .high
            )
        }
    }
    
    func getStats() -> [String: Any] {
        let now = Date()
        return [
            "currentMode": currentMode.displayName,
            "timeInCurrentMode": lastTransitionTime.timeIntervalSince(now),
            "totalTransitions": modeTransitionHistory.count,
            "balloonFlying": context.isBalloonFlying,
            "hasRecentTelemetry": context.lastTelemetryTime?.timeIntervalSince(now) ?? -1 > -60,
            "distanceToBalloon": context.distanceToBalloon ?? -1,
            "balloonAltitude": context.balloonAltitude ?? -1,
            "balloonVerticalSpeed": context.balloonVerticalSpeed ?? 0
        ]
    }
}

struct ModeConfiguration {
    let predictionInterval: TimeInterval
    let routingEnabled: Bool
    let cameraFollowEnabled: Bool
    let updateFrequency: UpdateFrequency
    
    enum UpdateFrequency {
        case low, normal, high
        
        var intervalSeconds: TimeInterval {
            switch self {
            case .low: return 60.0
            case .normal: return 30.0  
            case .high: return 10.0
            }
        }
    }
}

