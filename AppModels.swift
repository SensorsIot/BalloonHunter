import Foundation
import SwiftUI
import MapKit
import Combine

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

// A class intended to hold prediction-related data that can be shared across the app
class PredictionInfo: ObservableObject {
    @Published var landingTime: Date?
    @Published var arrivalTime: Date?
    @Published var routeDistanceMeters: Double?
}

// A comprehensive class representing a single telemetry data point from the sonde
struct TelemetryData: Identifiable {
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
        self.probeType = components[1]
        self.frequency = Double(components[2]) ?? 0.0
        self.signalStrength = Double(components[3]) ?? 0.0
        self.batteryPercentage = Int(components[4]) ?? 0
        self.batVoltage = Int(components[5]) ?? 0
        self.buzmute = (components[6] == "1")
        self.firmwareVersion = components[7]
    }
    
    private mutating func parseType1(components: [String]) {
        guard components.count >= 20 else { return }
        self.probeType = components[1]
        self.frequency = Double(components[2]) ?? 0.0
        self.sondeName = components[3]
        self.latitude = Double(components[4]) ?? 0.0
        self.longitude = Double(components[5]) ?? 0.0
        self.altitude = Double(components[6]) ?? 0.0
        self.horizontalSpeed = Double(components[7]) ?? 0.0
        self.verticalSpeed = Double(components[8]) ?? 0.0
        self.signalStrength = Double(components[9]) ?? 0.0
        self.batteryPercentage = Int(components[10]) ?? 0
        self.afcFrequency = Int(components[11]) ?? 0
        self.burstKillerEnabled = (components[12] == "1")
        self.burstKillerTime = Int(components[13]) ?? 0
        self.batVoltage = Int(components[14]) ?? 0
        self.buzmute = (components[15] == "1")
        self.firmwareVersion = components[19]
    }
    
    private mutating func parseType2(components: [String]) {
        guard components.count >= 10 else { return }
        self.probeType = components[1]
        self.frequency = Double(components[2]) ?? 0.0
        self.sondeName = components[3]
        self.signalStrength = Double(components[4]) ?? 0.0
        self.batteryPercentage = Int(components[5]) ?? 0
        self.afcFrequency = Int(components[6]) ?? 0
        self.batVoltage = Int(components[7]) ?? 0
        self.buzmute = (components[8] == "1")
        self.firmwareVersion = components[9]
    }
}


// A struct that serves as a lightweight, serializable representation of telemetry data
struct TelemetryTransferData: Codable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
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
    var status: AnnotationStatus = .fresh

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
            Image(systemName: "balloon.fill")
                .foregroundColor(status == .fresh ? .green : .red)
                .font(.title)
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
enum TransportationMode {
    case car
    case bike
}

// Additional models from the FSD that are useful
struct LocationData: Equatable {
    var latitude: Double
    var longitude: Double
    var heading: Double
}

struct PredictionData {
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
}

enum PredictionStatus: Equatable {
    case success
    case fetching
    case noValidPrediction // Initial state or when parsing fails to yield a valid prediction
    case error(String) // Network error or explicit API error
}

struct RouteData {
    var path: [CLLocationCoordinate2D]?
    var distance: Double // in meters
    var expectedTravelTime: TimeInterval // in seconds
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
    @Published var deviceSettings: DeviceSettings = .default
}

// Ensured ObservableObject conformance and class type for SwiftUI compatibility.
final class UserSettings: ObservableObject {
    @Published var burstAltitude: Double = 35000.0
    @Published var ascentRate: Double = 5.0
    @Published var descentRate: Double = 5.0
}

