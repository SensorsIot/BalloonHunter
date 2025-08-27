// Unified services used throughout the BalloonHunter app.
import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

// MARK: - BLECommunicationService
@MainActor
final class BLECommunicationService: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var persistenceService: PersistenceService
    private var connectedPeripheral: CBPeripheral?
    init(persistenceService: PersistenceService) {
        self.persistenceService = persistenceService
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        print("[DEBUG] BLECommunicationService init")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            print("[DEBUG] BLE is powered on. Starting scan...")
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        } else {
            print("[DEBUG] BLE is not available.")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let peripheralName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            if peripheralName.contains("MySondy") {
                print("[DEBUG] Found MySondy: \(peripheralName)")
                centralManager.stopScan()
                connectedPeripheral = peripheral
                centralManager.connect(peripheral, options: nil)
            }
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[DEBUG] Connected to MySondy")
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[DEBUG] Failed to connect to MySondy: \(error?.localizedDescription ?? "Unknown error")")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[DEBUG] Error discovering services: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
            print("[DEBUG] Discovered service: \(service)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("[DEBUG] Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            print("[DEBUG] Discovered characteristic: \(characteristic)")
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }
    @Published var isReadyForCommands = false
    private func parse(message: String) {
        let components = message.components(separatedBy: "/")
        guard components.count > 1 else { return }
        let messageType = components[0]
        if messageType == "3" {
            var deviceSettings = DeviceSettings()
            deviceSettings.parse(message: message)
            persistenceService.save(deviceSettings: deviceSettings)
        } else {
            var telemetryData = TelemetryData()
            telemetryData.parse(message: message)
            self.latestTelemetry = telemetryData
            self.telemetryData.send(telemetryData)
            self.telemetryHistory.append(telemetryData)
            if !isReadyForCommands {
                isReadyForCommands = true
                readSettings()
            }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[DEBUG] Error updating value for characteristic: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        if let string = String(data: data, encoding: .utf8) {
            print("[DEBUG] Received data: \(string)")
            self.parse(message: string)
        }
    }
    @Published var latestTelemetry: TelemetryData? = nil
    @Published var deviceSettings: DeviceSettings = .default
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var telemetryData = PassthroughSubject<TelemetryData, Never>()
    @Published var telemetryHistory: [TelemetryData] = []
    func readSettings() {
        sendCommand(command: "o{?}o")
    }
    func sendCommand(command: String) {
        print("[BLECommunicationService] sendCommand: \(command)")
        // TODO: Implement command sending via BLE
    }
    func simulateTelemetry(_ data: TelemetryData) {
        self.latestTelemetry = data
        self.telemetryData.send(data)
    }
}

// MARK: - CurrentLocationService
@MainActor
final class CurrentLocationService: NSObject, ObservableObject {
    @Published var locationData: LocationData?
    private let locationManager = CLLocationManager()
    override init() {
        print("[DEBUG] CurrentLocationService init")
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
}
extension CurrentLocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let heading = location.course
        self.locationData = LocationData(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, heading: heading)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[CurrentLocationService] Failed to get location: \(error.localizedDescription)")
    }
}

// MARK: - PersistenceService
@MainActor
final class PersistenceService: ObservableObject {
    @Published var deviceSettings: DeviceSettings? = nil
    @Published var userSettings: UserSettings? = nil
    func save(deviceSettings: DeviceSettings) {
        self.deviceSettings = deviceSettings
    }
    func save(userSettings: UserSettings) {
        self.userSettings = userSettings
    }
    func readPredictionParameters() -> UserSettings? {
        return userSettings
    }
    init() {
        print("[DEBUG] PersistenceService init")
        let fileManager = FileManager.default
        print("[DEBUG] Current working directory: \(fileManager.currentDirectoryPath)")
    }
}

// MARK: - RouteCalculationService
@MainActor
final class RouteCalculationService: ObservableObject {
    init() {
        print("[DEBUG] RouteCalculationService init")
    }
    @Published var routeData: RouteData? = nil
    func calculateRoute(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        transportType: TransportationMode = .car
    ) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = (transportType == .car) ? .automobile : .walking
        let directions = MKDirections(request: request)
        directions.calculate { [weak self] response, error in
            guard let self = self else { return }
            if let error = error {
                print("[RouteCalculationService] Route calculation error: \(error.localizedDescription)")
                return
            }
            guard let route = response?.routes.first else {
                print("[RouteCalculationService] No route found.")
                return
            }
            let routeData = RouteData(
                path: route.polyline.coordinates,
                distance: route.distance,
                expectedTravelTime: route.expectedTravelTime
            )
            DispatchQueue.main.async {
                self.routeData = routeData
            }
        }
    }
}

// MARK: - PredictionService
@MainActor
final class PredictionService: NSObject, ObservableObject {
    @Published var appInitializationFinished: Bool = false
    override init() {
        super.init()
        print("[DEBUG] PredictionService init: \(Unmanaged.passUnretained(self).toOpaque())")
    }
    func debugPrintInstanceAddress(label: String = "") {
        print("[DEBUG][PredictionService] Instance address \(label): \(Unmanaged.passUnretained(self).toOpaque())")
    }
    @Published var predictionData: PredictionData? {
        didSet {
            // print("[Debug][PredictionService] predictionData didSet: \(String(describing: predictionData?.landingPoint))")
        }
    }
    @Published var lastAPICallURL: String? = nil
    @Published var isLoading: Bool = false

    private var path: [CLLocationCoordinate2D] = []
    private var burstPoint: CLLocationCoordinate2D? = nil
    private var landingPoint: CLLocationCoordinate2D? = nil
    private var landingTime: Date? = nil
    private var lastPredictionFetchTime: Date?
    @Published var predictionStatus: PredictionStatus = .noValidPrediction

    // JSON structs for parsing
    nonisolated private struct APIResponse: Codable {
        struct Prediction: Codable {
            struct TrajectoryPoint: Codable {
                let altitude: Double?
                let datetime: String?
                let latitude: Double?
                let longitude: Double?
            }
            let stage: String
            let trajectory: [TrajectoryPoint]
        }
        let prediction: [Prediction]
    }
    func fetchPrediction(telemetry: TelemetryData, userSettings: UserSettings) {
        if let lastFetchTime = lastPredictionFetchTime {
            let timeSinceLastFetch = Date().timeIntervalSince(lastFetchTime)
            if timeSinceLastFetch < 30 {
                // print("[Debug][PredictionService] Skipping fetch: time since last fetch = \(timeSinceLastFetch)")
                return
            }
        }
        lastPredictionFetchTime = Date()
        predictionStatus = .fetching
        isLoading = true
        print("[Debug][PredictionService] Fetching prediction...")
        path = []
        burstPoint = nil
        landingPoint = nil
        landingTime = nil
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let launchDatetime = dateFormatter.string(from: Date().addingTimeInterval(60))
        let urlString = "https://api.v2.sondehub.org/tawhiri?launch_latitude=\(telemetry.latitude)&launch_longitude=\(telemetry.longitude)&launch_altitude=\(telemetry.altitude)&launch_datetime=\(launchDatetime)&ascent_rate=\(userSettings.ascentRate)&descent_rate=\(userSettings.descentRate)&burst_altitude=\(userSettings.burstAltitude)"
        self.lastAPICallURL = urlString
        print("[Debug][PredictionService] API Call: \(urlString)")
        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }
        Task.detached {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
                await MainActor.run {
                    self.path = []
                    var ascentPoints: [CLLocationCoordinate2D] = []
                    var descentPoints: [CLLocationCoordinate2D] = []

                    for p in apiResponse.prediction {
                        if p.stage == "ascent" {
                            for point in p.trajectory {
                                if let lat = point.latitude, let lon = point.longitude {
                                    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                                    ascentPoints.append(coord)
                                }
                            }
                            self.burstPoint = ascentPoints.last
                        } else if p.stage == "descent" {
                            var lastDescentPoint: APIResponse.Prediction.TrajectoryPoint? = nil
                            for point in p.trajectory {
                                if let lat = point.latitude, let lon = point.longitude {
                                    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                                    descentPoints.append(coord)
                                    lastDescentPoint = point
                                }
                            }
                            if let last = lastDescentPoint, let lat = last.latitude, let lon = last.longitude {
                                self.landingPoint = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                                // print("[Debug][PredictionService] Parsed landing point: lat = \(lat), lon = \(lon)")
                                // print("[Debug][PredictionService] CLLocationCoordinate2DIsValid: \(CLLocationCoordinate2DIsValid(coord))")
                                if lat == 0 && lon == 0 {
                                    print("[Debug][PredictionService] Landing point is at (0,0) -- likely invalid")
                                }
                                if let dt = last.datetime {
                                    let formatter = ISO8601DateFormatter()
                                    self.landingTime = formatter.date(from: dt)
                                }
                            }
                        }
                    }
                    self.path = ascentPoints + descentPoints

                    if let landingPoint = self.landingPoint {
                        // print("[Debug][PredictionService] Prediction parsing finished. Valid prediction received.")
                        // print("[Debug][PredictionService] Final parsed landingPoint for PredictionData: \(landingPoint)")
                        // print("[Debug][PredictionService] about to set predictionData.landingPoint = \(String(describing: landingPoint))")
                        let newPredictionData = PredictionData(path: self.path, burstPoint: self.burstPoint, landingPoint: landingPoint, landingTime: self.landingTime)
                        self.predictionData = newPredictionData
                        // print("[Debug][PredictionService] predictionData set: \(String(describing: self.predictionData?.landingPoint))")
                        self.predictionStatus = .success
                        if self.appInitializationFinished == false {
                            self.appInitializationFinished = true
                            // print("[Debug][PredictionService] appInitializationFinished set to true")
                        }
                    } else {
                        print("[Debug][PredictionService] Prediction parsing finished, but no valid landing point found.")
                        if case .fetching = self.predictionStatus {
                            self.predictionStatus = .noValidPrediction
                        }
                    }
                    self.isLoading = false
                }
                // print("[Debug][PredictionService] Prediction fetch succeeded.")
            } catch {
                await MainActor.run {
                    print("[Debug][PredictionService] Network or JSON parsing failed: \(error.localizedDescription)")
                    self.predictionStatus = .error(error.localizedDescription)
                    self.isLoading = false
                }
                print("[Debug][PredictionService] Prediction fetch failed with error: \(error.localizedDescription)")
            }
        }
    }
}


