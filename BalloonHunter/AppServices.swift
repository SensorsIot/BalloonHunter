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
    private var writeCharacteristic: CBCharacteristic?

    init(persistenceService: PersistenceService) {
        self.persistenceService = persistenceService
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BLECommunicationService init")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BLE is powered on. Starting scan...")
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        } else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BLE is not available.")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let peripheralName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            if peripheralName.contains("MySondy") {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Found MySondy: \(peripheralName)")
                centralManager.stopScan()
                connectedPeripheral = peripheral
                connectionStatus = .connecting
                centralManager.connect(peripheral, options: nil)
            }
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Connected to MySondy")
        connectionStatus = .connected
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Failed to connect to MySondy: \(error?.localizedDescription ?? "Unknown error")")
        connectionStatus = .disconnected
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Disconnected from MySondy")
        connectionStatus = .disconnected
        connectedPeripheral = nil
        // Optionally, restart scanning
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Error discovering services: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Discovered service: \(service)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Discovered characteristic: \(characteristic)")
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                self.writeCharacteristic = characteristic
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
            afcHistory.append(telemetryData.afcFrequency)
            if !isReadyForCommands {
                isReadyForCommands = true
                readSettings()
            }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Error updating value for characteristic: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        if let string = String(data: data, encoding: .utf8) {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Received data: \(string)")
            self.parse(message: string)
        }
    }
    @Published var latestTelemetry: TelemetryData? = nil
    @Published var deviceSettings: DeviceSettings = .default
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var telemetryData = PassthroughSubject<TelemetryData, Never>()
    @Published var telemetryHistory: [TelemetryData] = []
    @Published var afcHistory: [Int] = []
    private let afcHistoryCapacity = 20

    func readSettings() {
        sendCommand(command: "o{?}o")
    }
    func sendCommand(command: String) {
        print("[BLECommunicationService][State: \(SharedAppState.shared.appState.rawValue)] sendCommand: \(command)")
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic,
              let data = command.data(using: .utf8) else {
            print("[BLECommunicationService][State: \(SharedAppState.shared.appState.rawValue)] Error: Not connected or write characteristic not found.")
            return
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }
    func simulateTelemetry(_ data: TelemetryData) {
        self.latestTelemetry = data
        self.telemetryData.send(data)
    }

    func disconnect() {
        if let connectedPeripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(connectedPeripheral)
        }
        centralManager.stopScan()
        connectionStatus = .disconnected
    }
}

// MARK: - CurrentLocationService
@MainActor
final class CurrentLocationService: NSObject, ObservableObject {
    @Published var locationData: LocationData?
    private let locationManager = CLLocationManager()
    override init() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] CurrentLocationService init")
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
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
        print("[CurrentLocationService][State: \(SharedAppState.shared.appState.rawValue)] Failed to get location: \(error.localizedDescription)")
    }
}

// MARK: - PersistenceService
@MainActor
final class PersistenceService: ObservableObject {
    @Published var deviceSettings: DeviceSettings? = nil
    @Published var userSettings: UserSettings = .default {
        didSet {
            // Save to UserDefaults whenever userSettings changes
            if let encoded = try? JSONEncoder().encode(userSettings) {
                UserDefaults.standard.set(encoded, forKey: "userSettings")
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] UserSettings saved to UserDefaults.")
            } else {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Failed to encode UserSettings for saving.")
            }
        }
    }

    func save(deviceSettings: DeviceSettings) {
        self.deviceSettings = deviceSettings
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: deviceSettings saved: \(deviceSettings)")
    }
    func save(userSettings: UserSettings) {
        self.userSettings = userSettings // This will trigger didSet
    }
    func readPredictionParameters() -> UserSettings? {
        return userSettings
    }
    init() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService init")
        // Load UserSettings from UserDefaults on init
        if let savedSettings = UserDefaults.standard.data(forKey: "userSettings") {
            if let decodedSettings = try? JSONDecoder().decode(UserSettings.self, from: savedSettings) {
                self.userSettings = decodedSettings
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] UserSettings loaded from UserDefaults.")
            } else {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Failed to decode UserSettings from UserDefaults.")
            }
        } else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] No UserSettings found in UserDefaults, using default.")
        }
        let fileManager = FileManager.default
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Current working directory: \(fileManager.currentDirectoryPath)")
    }
}

// MARK: - RouteCalculationService
@MainActor
final class RouteCalculationService: ObservableObject {
    init() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] RouteCalculationService init")
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

        switch transportType {
        case .car:
            request.transportType = .automobile
        case .bike:
            request.transportType = .cycling
        }

        let directions = MKDirections(request: request)
        directions.calculate { [weak self] response, error in
            guard let self = self else { return }
            if let error = error {
                print("[RouteCalculationService][State: \(SharedAppState.shared.appState.rawValue)] Route calculation error: \(error.localizedDescription)")
                return
            }
            guard let route = response?.routes.first else {
                print("[RouteCalculationService][State: \(SharedAppState.shared.appState.rawValue)] No route found.")
                return
            }

            var travelTime = route.expectedTravelTime
            if transportType == .bike {
                travelTime *= 0.7 // Reduce by 30% for bicycle
            }

            let routeData = RouteData(
                path: route.polyline.coordinates,
                distance: route.distance,
                expectedTravelTime: travelTime
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
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PredictionService init: \(Unmanaged.passUnretained(self).toOpaque())")
    }
    func debugPrintInstanceAddress(label: String = "") {
        print("[DEBUG][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Instance address \(label): \(Unmanaged.passUnretained(self).toOpaque())")
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
        print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Fetching prediction...")
        path = []
        burstPoint = nil
        landingPoint = nil
        landingTime = nil
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let launchDatetime = dateFormatter.string(from: Date().addingTimeInterval(60))
        let urlString = "https://api.v2.sondehub.org/tawhiri?launch_latitude=\(telemetry.latitude)&launch_longitude=\(telemetry.longitude)&launch_altitude=\(telemetry.altitude)&launch_datetime=\(launchDatetime)&ascent_rate=\(userSettings.ascentRate)&descent_rate=\(userSettings.descentRate)&burst_altitude=\(userSettings.burstAltitude)"
        self.lastAPICallURL = urlString
        print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] API Call: \(urlString)")
        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }
        Task.detached {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
                await MainActor.run { @MainActor in
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
                                    print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Landing point is at (0,0) -- likely invalid")
                                }
                                if let dt = last.datetime {
                                    let formatter = ISO8601DateFormatter()
                                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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
                        print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Prediction parsing finished, but no valid landing point found.")
                        if case .fetching = self.predictionStatus {
                            self.predictionStatus = .noValidPrediction
                        }
                    }
                    self.isLoading = false
                }
                // print("[Debug][PredictionService] Prediction fetch succeeded.")
            } catch {
                await MainActor.run { @MainActor in
                    print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Network or JSON parsing failed: \(error.localizedDescription)")
                    self.predictionStatus = .error(error.localizedDescription)
                    self.isLoading = false
                }
                print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Prediction fetch failed with error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - AnnotationService
@MainActor
final class AnnotationService: ObservableObject {
    @Published private(set) var appState: AppState = .startup {
        didSet {
            SharedAppState.shared.appState = appState
        }
    }
    @Published var annotations: [MapAnnotationItem] = []

    init() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] AnnotationService init")
    }

    func updateState(
        telemetry: TelemetryData?,
        userLocation: LocationData?,
        prediction: PredictionData?,
        route: RouteData?,
        telemetryHistory: [TelemetryData]
    ) {
        // First, update annotations regardless of state
        updateAnnotations(telemetry: telemetry, userLocation: userLocation, prediction: prediction)

        // Then, run the state machine
        switch appState {
        case .startup:
            // Trigger to move to long range tracking
            if telemetry != nil { // Only check telemetry for early map display
                print("[STATE][State: \(SharedAppState.shared.appState.rawValue)] Transitioning to Long Range Tracking")
                appState = .longRangeTracking
            }
        case .longRangeTracking:
            // Trigger to move to final approach
            guard let userLoc = userLocation,
                  let tel = telemetry,
                  telemetryHistory.count >= 10 else {
                return
            }

            let last10Telemetry = telemetryHistory.suffix(10)
            let isBalloonStable = last10Telemetry.allSatisfy { $0.verticalSpeed < 1 && $0.horizontalSpeed < 5 }

            if isBalloonStable {
                 let userCLLocation = CLLocation(latitude: userLoc.latitude, longitude: userLoc.longitude)
                 let balloonCLLocation = CLLocation(latitude: tel.latitude, longitude: tel.longitude)
                 let distance = userCLLocation.distance(from: balloonCLLocation)
                 let isUserClose = distance < 1000 // 1 km

                if isUserClose {
                    print("[STATE][State: \(SharedAppState.shared.appState.rawValue)] Transitioning to Final Approach")
                    appState = .finalApproach
                }
            }
        case .finalApproach:
            // No transition out of final approach defined yet
            break
        }
    }

    private func updateAnnotations(
        telemetry: TelemetryData?,
        userLocation: LocationData?,
        prediction: PredictionData?
    ) {
        var items: [MapAnnotationItem] = []
        // Add user annotation if available
        if let userLoc = userLocation {
            items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: userLoc.latitude, longitude: userLoc.longitude), kind: .user))
        }

        // Only add balloon-related annotations if in longRangeTracking or finalApproach state
        if self.appState == .longRangeTracking || self.appState == .finalApproach {
            // Add balloon annotation if telemetry available
            if let tel = telemetry {
                let isAscending = tel.verticalSpeed >= 0
                items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: tel.latitude, longitude: tel.longitude), kind: .balloon, isAscending: isAscending))
            }
            // Add burst point (prediction)
            if let burst = prediction?.burstPoint {
                items.append(MapAnnotationItem(coordinate: burst, kind: .burst))
            }
            // Add landing point (prediction)
            if let landing = prediction?.landingPoint {
                items.append(MapAnnotationItem(coordinate: landing, kind: .landing))
            }
            // Add landed annotation if vertical speed negative (descending/landed)
            if let tel = telemetry, tel.verticalSpeed < 0 {
                items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: tel.latitude, longitude: tel.longitude), kind: .landed))
            }
        }
        self.annotations = items
    }
}

// MARK: - ServiceManager
@MainActor
final class ServiceManager: ObservableObject {
    let bleCommunicationService: BLECommunicationService
    let currentLocationService: CurrentLocationService
    let persistenceService: PersistenceService
    let routeCalculationService: RouteCalculationService
    let predictionService: PredictionService
    let annotationService: AnnotationService

    init() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] ServiceManager init")
        self.persistenceService = PersistenceService()
        self.bleCommunicationService = BLECommunicationService(persistenceService: self.persistenceService)
        self.currentLocationService = CurrentLocationService()
        self.routeCalculationService = RouteCalculationService()
        self.predictionService = PredictionService()
        self.annotationService = AnnotationService()
    }
}