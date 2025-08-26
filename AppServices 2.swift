import SwiftUI
import Combine
import Foundation
import CoreLocation

// MARK: - Model and Utility Definitions

struct BalloonTrack: Codable, Identifiable {
    let id = UUID()
    let timestamp: Date
    let altitude: Double
    let latitude: Double
    let longitude: Double
    let temperature: Double?
    let pressure: Double?
    let humidity: Double?
}

struct AnyCodable: Codable {
    let value: Any

    init<T>(_ value: T?) {
        self.value = value ?? ()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = ()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is Void:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            let encodableArray = array.map { AnyCodable($0) }
            try container.encode(encodableArray)
        case let dictionary as [String: Any]:
            let encodableDict = dictionary.mapValues { AnyCodable($0) }
            try container.encode(encodableDict)
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported value")
            throw EncodingError.invalidValue(value, context)
        }
    }
}

struct TelemetryData: Codable {
    let altitude: Double
    let temperature: Double
    let pressure: Double
    let humidity: Double
    let location: LocationData
    let timestamp: Date
}

struct DeviceSettings: Codable {
    var deviceName: String
    var measurementInterval: TimeInterval
    var isTemperatureEnabled: Bool
    var isPressureEnabled: Bool
    var isHumidityEnabled: Bool
}

struct LocationData: Codable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
}

enum ConnectionStatus: String, Codable {
    case disconnected
    case connecting
    case connected
    case failed
}

// MARK: - Services

final class PersistenceService {
    private let balloonTracksKey = "balloonTracks"
    private let userDefaults = UserDefaults.standard

    func saveBalloonTracks(_ tracks: [BalloonTrack]) {
        do {
            let data = try JSONEncoder().encode(tracks)
            userDefaults.set(data, forKey: balloonTracksKey)
        } catch {
            print("Error saving balloon tracks: \(error)")
        }
    }

    func loadBalloonTracks() -> [BalloonTrack] {
        guard let data = userDefaults.data(forKey: balloonTracksKey) else {
            return []
        }
        do {
            let tracks = try JSONDecoder().decode([BalloonTrack].self, from: data)
            return tracks
        } catch {
            print("Error loading balloon tracks: \(error)")
            return []
        }
    }
}

final class BLECommunicationService: NSObject, ObservableObject {
    @Published var connectionStatus: ConnectionStatus = .disconnected

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        connectionStatus = .connecting
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }

    func stopScanning() {
        centralManager.stopScan()
    }
}

extension BLECommunicationService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanning()
        } else {
            connectionStatus = .disconnected
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        centralManager.stopScan()
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionStatus = .connected
        // Additional setup after connection if needed
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStatus = .failed
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionStatus = .disconnected
    }
}

final class RouteCalculationService {
    func calculateRoute(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        // Placeholder logic for route calculation
        return [start, end]
    }
}

final class AnnotationService {
    func createAnnotation(for location: CLLocationCoordinate2D, title: String) -> MKPointAnnotation {
        let annotation = MKPointAnnotation()
        annotation.coordinate = location
        annotation.title = title
        return annotation
    }
}

final class AppService: ObservableObject {
    @Published var currentSettings: DeviceSettings
    @Published var currentTelemetry: TelemetryData?
    @Published var balloonTracks: [BalloonTrack] = []

    private let persistenceService: PersistenceService
    private let bleService: BLECommunicationService
    private var cancellables = Set<AnyCancellable>()

    init(persistenceService: PersistenceService = PersistenceService(),
         bleService: BLECommunicationService = BLECommunicationService(),
         initialSettings: DeviceSettings = DeviceSettings(deviceName: "BalloonDevice",
                                                          measurementInterval: 10,
                                                          isTemperatureEnabled: true,
                                                          isPressureEnabled: true,
                                                          isHumidityEnabled: true)) {
        self.persistenceService = persistenceService
        self.bleService = bleService
        self.currentSettings = initialSettings

        self.balloonTracks = persistenceService.loadBalloonTracks()

        bleService.$connectionStatus
            .sink { status in
                // Handle connection status changes if needed
            }
            .store(in: &cancellables)
    }

    func updateSettings(_ settings: DeviceSettings) {
        currentSettings = settings
        // Save or propagate settings as needed
    }

    func addTelemetryData(_ telemetry: TelemetryData) {
        currentTelemetry = telemetry

        let newTrack = BalloonTrack(
            timestamp: telemetry.timestamp,
            altitude: telemetry.altitude,
            latitude: telemetry.location.latitude,
            longitude: telemetry.location.longitude,
            temperature: telemetry.temperature,
            pressure: telemetry.pressure,
            humidity: telemetry.humidity
        )
        balloonTracks.append(newTrack)
        persistenceService.saveBalloonTracks(balloonTracks)
    }
}

final class PredictionService {
    struct ForecastSettings {
        var forecastInterval: TimeInterval
        var modelVersion: String
        var enableWindPrediction: Bool
        var enableTemperaturePrediction: Bool
    }

    private var forecastSettings: ForecastSettings

    init(forecastSettings: ForecastSettings = ForecastSettings(forecastInterval: 3600,
                                                                modelVersion: "1.0",
                                                                enableWindPrediction: true,
                                                                enableTemperaturePrediction: true)) {
        self.forecastSettings = forecastSettings
    }

    func predictNextPosition(from currentLocation: CLLocationCoordinate2D,
                             with currentAltitude: Double,
                             and currentVelocity: CLLocationSpeed) -> CLLocationCoordinate2D {
        // Placeholder simplistic prediction logic moving north with a fixed speed
        let deltaLatitude = currentVelocity * forecastSettings.forecastInterval / 111000.0 // approx degrees per meter
        let predictedLatitude = currentLocation.latitude + deltaLatitude
        return CLLocationCoordinate2D(latitude: predictedLatitude, longitude: currentLocation.longitude)
    }

    func updateForecastSettings(_ settings: ForecastSettings) {
        self.forecastSettings = settings
    }
}
