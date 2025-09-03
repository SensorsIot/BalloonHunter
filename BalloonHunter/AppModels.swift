import Foundation
import SwiftUI
import MapKit
import Combine

enum AppState: String {
    case startup
    case longRangeTracking
    case finalApproach
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
struct TelemetryData: Identifiable, Equatable {
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

    let id = UUID()
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


// A struct that serves as a lightweight, serializable representation of telemetry data
struct TelemetryTransferData: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitude: Double

    init(telemetryData: TelemetryData) {
        self.latitude = telemetryData.latitude
        self.longitude = telemetryData.longitude
        self.altitude = telemetryData.altitude
    }
}

// A Codable and Equatable struct used for representing the settings received from or sent to the BLE device.
struct SondeSettingsTransferData: Codable, Equatable {
    var sondeType: String
    var frequency: Double
}

// A Identifiable struct used to represent markers on the map.
struct MapAnnotationItem: Identifiable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D
    var kind: AnnotationKind
    var isAscending: Bool? = nil
    var status: AnnotationStatus = .fresh
    var lastUpdateTime: Date? = nil
    var altitude: Double? = nil

    enum AnnotationKind {
        case user
        case balloon
        case burst
        case landing
        case landed
    }
    
    enum AnnotationStatus {
        case fresh
        case stale
    }
    
    @ViewBuilder
    var view: some View {
        switch kind {
        case .user:
            Image(systemName: "figure.walk")
                .foregroundColor(.blue)
                .font(.title)
        case .balloon:
            let color: Color = {
                if let lastUpdate = lastUpdateTime, Date().timeIntervalSince(lastUpdate) <= 3 {
                    return .green
                } else {
                    return .red
                }
            }()
            ZStack(alignment: .top) { // Use ZStack to layer image and text
                Image(systemName: "balloon.fill")
                    .font(.system(size: 90)) // Make balloon larger to fit text
                    .foregroundColor(color)

                if let altitude = altitude {
                    Text("\(Int(altitude))")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.85), radius: 4, x: 0, y: 2)
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                        .frame(width: 54, height: 40)
                        .position(x: 38, y: 34) // Center within 76x76 balloon
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
            Image(systemName: "mappin.circle.fill")
                .foregroundColor(.red)
                .font(.title)
        }
    }
}

// A simple enum to represent the user's preferred mode of transport for route calculations.
enum TransportationMode: Sendable, Equatable {
    case car
    case bike

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

struct PredictionData: Equatable {
    var path: [CLLocationCoordinate2D]?
    var burstPoint: CLLocationCoordinate2D?
    var landingPoint: CLLocationCoordinate2D?
    var landingTime: Date?
    var latestTelemetry: TelemetryData?
    
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
            pathsEqual = lhsPath.elementsEqual(rhsPath) { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        } else {
            pathsEqual = lhs.path == nil && rhs.path == nil
        }

        let burstPointsEqual: Bool
        if let lhsBurst = lhs.burstPoint, let rhsBurst = rhs.burstPoint {
            burstPointsEqual = lhsBurst.latitude == rhsBurst.latitude && lhsBurst.longitude == rhsBurst.longitude
        } else {
            burstPointsEqual = lhs.burstPoint == nil && rhs.burstPoint == nil
        }

        let landingPointsEqual: Bool
        if let lhsLanding = lhs.landingPoint, let rhsLanding = rhs.landingPoint {
            landingPointsEqual = lhsLanding.latitude == rhsLanding.latitude && lhsLanding.longitude == rhsLanding.longitude
        } else {
            landingPointsEqual = lhs.landingPoint == nil && rhs.landingPoint == nil
        }

        return pathsEqual && burstPointsEqual && landingPointsEqual && lhs.landingTime == rhs.landingTime && lhs.latestTelemetry == rhs.latestTelemetry
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

    static func == (lhs: RouteData, rhs: RouteData) -> Bool {
        let pathsEqual: Bool
        if let lhsPath = lhs.path, let rhsPath = rhs.path {
            pathsEqual = lhsPath.elementsEqual(rhsPath) { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
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

struct AFCData {
    var values: [Int]
}

// Ensured ObservableObject conformance and class type for SwiftUI compatibility.
final class AppSettings: ObservableObject {
    init() {
        print("[DEBUG] AppSettings init")
    }
    @Published var deviceSettings: DeviceSettings = .default
}

// Ensured ObservableObject conformance and class type for SwiftUI compatibility.
final class UserSettings: ObservableObject, Codable { // Added Codable
    required init() {
        print("[DEBUG] UserSettings init")
    }
    
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

