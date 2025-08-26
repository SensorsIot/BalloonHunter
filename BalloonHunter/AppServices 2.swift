// Unified services used throughout the BalloonHunter app.
import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

// MARK: - AnnotationService
@MainActor
final class AnnotationService: ObservableObject {
    init() {
        print("[DEBUG] AnnotationService init")
    }
    @Published var annotations: [MapAnnotationItem] = []
    private let isFinalApproachSubject = PassthroughSubject<Bool, Never>()
    var isFinalApproach: AnyPublisher<Bool, Never> { isFinalApproachSubject.eraseToAnyPublisher() }
    func updateAnnotations(
        telemetry: TelemetryData?,
        userLocation: LocationData?,
        prediction: PredictionData?
    ) {
        var items: [MapAnnotationItem] = []
        if let userLoc = userLocation {
            items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: userLoc.latitude, longitude: userLoc.longitude), kind: .user))
        }
        if let tel = telemetry {
            items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: tel.latitude, longitude: tel.longitude), kind: .balloon))
        }
        if let burst = prediction?.burstPoint {
            items.append(MapAnnotationItem(coordinate: burst, kind: .burst))
        }
        if let landing = prediction?.landingPoint {
            items.append(MapAnnotationItem(coordinate: landing, kind: .landing))
        }
        if let tel = telemetry, tel.verticalSpeed < 0 {
            items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: tel.latitude, longitude: tel.longitude), kind: .landed))
            isFinalApproachSubject.send(true)
        } else {
            isFinalApproachSubject.send(false)
        }
        self.annotations = items
    }
}

// MARK: - BLECommunicationService
@MainActor
final class BLECommunicationService: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var persistenceService: PersistenceService
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
                centralManager.connect(peripheral, options: nil)
            }
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[DEBUG] Connected to MySondy")
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
