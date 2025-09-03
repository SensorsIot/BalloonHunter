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

    // Injected annotationService reference (weak to avoid retain cycles)
    weak var annotationService: AnnotationService?
    
    // Injected predictionService reference for new requirement
    weak var predictionService: PredictionService?
    
    // Injected userLocationService reference for new requirement
    weak var currentLocationService: CurrentLocationService?

    // Define UUIDs as constants
    // Never touch these UUIDS!!!
    private let UART_SERVICE_UUID = CBUUID(string: "53797269-614D-6972-6B6F-44616C6D6F6E")
    private let UART_RX_CHARACTERISTIC_UUID = CBUUID(string: "53797267-614D-6972-6B6F-44616C6D6F8E")
    private let UART_TX_CHARACTERISTIC_UUID = CBUUID(string: "53797268-614D-6972-6B6F-44616C6D6F7E")

    private var hasSentReadSettingsCommand = false

    /// Published telemetry availability state. Updated solely by timer-based validity check.
    /// Other services (e.g. AnnotationService) can observe this to trigger annotation updates on transitions.
    @Published var telemetryAvailabilityState: Bool = false

    init(persistenceService: PersistenceService) {
        self.persistenceService = persistenceService
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BLECommunicationService init")

        // Phase 1: Populate currentSondeTrack at BLECommunicationService Init
        // Load the track for the first sonde found in persistenceService.tracks if any exist
        if let firstSondeName = persistenceService.tracks.keys.first {
            self.currentSondeName = firstSondeName
            self.currentSondeTrack = persistenceService.retrieveTrack(sondeName: firstSondeName)
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BLECommunicationService: Loaded initial track for \(firstSondeName) with \(self.currentSondeTrack.count) points.")
        }
        
        // Setup timer to update telemetryAvailabilityState based on lastTelemetryUpdateTime
        // Telemetry validity is managed exclusively by timer-based checks now.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateTelemetryAvailabilityState()
            }
        }
    }

    // Timer-based update of telemetryAvailabilityState:
    // If lastTelemetryUpdateTime is within the last 3 seconds, set telemetryAvailabilityState to true,
    // otherwise set it to false. This replaces previous direct setting in checkTelemetryAvailability.
    private func updateTelemetryAvailabilityState() {
        guard let lastUpdate = lastTelemetryUpdateTime else {
            if telemetryAvailabilityState != false {
                telemetryAvailabilityState = false
            }
            return
        }
        let interval = Date().timeIntervalSince(lastUpdate)
        let isAvailable = interval <= 3.0
        if telemetryAvailabilityState != isAvailable {
            telemetryAvailabilityState = isAvailable
            if isAvailable {
                print("[BLECommunicationService] Telemetry GAINED: lastTelemetryUpdateTime within 3 seconds.")
            } else {
                print("[BLECommunicationService] Telemetry LOST: lastTelemetryUpdateTime older than 3 seconds.")
            }
        }
    }

    // This method is retained but empty as telemetry availability state is now managed solely by timer updates.
    private func checkTelemetryAvailability(_ newTelemetry: TelemetryData?) {
        // Intentionally left empty to avoid duplicate state changes and logging.
        // Telemetry availability is managed exclusively by updateTelemetryAvailabilityState timer.
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Central Manager did update state: \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BLE is powered on. Starting scan...")
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        case .poweredOff:
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BLE is powered off.")
            connectionStatus = .disconnected
        case .resetting:
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BLE is resetting.")
        case .unauthorized:
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BLE is unauthorized.")
        case .unknown:
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BLE state is unknown.")
        case .unsupported:
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BLE is unsupported.")
        @unknown default:
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Unknown BLE state.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Did discover peripheral: \(peripheral.name ?? "Unknown") (UUID: \(peripheral.identifier.uuidString)), RSSI: \(RSSI)")

        if let peripheralName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            if peripheralName.contains("MySondy") {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Found MySondy: \(peripheralName). Stopping scan and connecting...")
                centralManager.stopScan()
                connectedPeripheral = peripheral
                connectionStatus = .connecting
                centralManager.connect(peripheral, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Successfully connected to peripheral: \(peripheral.name ?? "Unknown")")
        connectionStatus = .connected
        connectedPeripheral = peripheral
        peripheral.delegate = self
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Discovering services for peripheral: \(peripheral.name ?? "Unknown") with UUID: \(UART_SERVICE_UUID.uuidString)")
        peripheral.discoverServices([UART_SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Failed to connect to peripheral: \(peripheral.name ?? "Unknown"). Error: \(error?.localizedDescription ?? "Unknown error")")
        connectionStatus = .disconnected
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Disconnected from peripheral: \(peripheral.name ?? "Unknown"). Error: \(error?.localizedDescription ?? "No error")")
        connectionStatus = .disconnected
        connectedPeripheral = nil
        // Optionally, restart scanning
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Restarting scan after disconnection...")
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Error discovering services for \(peripheral.name ?? "Unknown"): \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] No services found for \(peripheral.name ?? "Unknown").")
            return
        }
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Discovered \(services.count) service(s) for \(peripheral.name ?? "Unknown").")
        for service in services {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Discovered service: \(service.uuid.uuidString)")
            if service.uuid == UART_SERVICE_UUID {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Found UART Service. Discovering characteristics for service: \(service.uuid.uuidString) with RX: \(UART_RX_CHARACTERISTIC_UUID.uuidString) and TX: \(UART_TX_CHARACTERISTIC_UUID.uuidString)")
                peripheral.discoverCharacteristics([UART_RX_CHARACTERISTIC_UUID, UART_TX_CHARACTERISTIC_UUID], for: service)
            } else {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Skipping non-UART service: \(service.uuid.uuidString)")
            }
        }
        if services.allSatisfy({ $0.uuid != UART_SERVICE_UUID }) {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] UART Service not found among discovered services. Is the BLE device advertising the correct service?")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Error discovering characteristics for service \(service.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        guard let characteristics = service.characteristics else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] No characteristics found for service \(service.uuid.uuidString).")
            return
        }
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Discovered \(characteristics.count) characteristic(s) for service \(service.uuid.uuidString).")
        for characteristic in characteristics {
            if characteristic.uuid == UART_RX_CHARACTERISTIC_UUID {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Found UART RX Characteristic. Checking notify property...")
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                    print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Set notify value to true for RX characteristic.")
                } else {
                    print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] UART RX Characteristic does not have notify property.")
                }
            } else if characteristic.uuid == UART_TX_CHARACTERISTIC_UUID {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Found UART TX Characteristic. Checking write properties...")
                if characteristic.properties.contains(.write) {
                    self.writeCharacteristic = characteristic
                    print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Assigned TX characteristic for writing (write).")
                } else if characteristic.properties.contains(.writeWithoutResponse) {
                    self.writeCharacteristic = characteristic
                    print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Assigned TX characteristic for writing (writeWithoutResponse).")
                } else {
                    print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] UART TX Characteristic does not have write or writeWithoutResponse properties.")
                }
            }
        }
        // Additional debug if TX characteristic is missing among discovered characteristics
        if writeCharacteristic == nil {
            isReadyForCommands = false
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil {
            _ = error
            return
        }
        guard let data = characteristic.value else {
            return
        }
        if let string = String(data: data, encoding: .utf8) {
            self.parse(message: string)
        } else {
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil {
            _ = error
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil {
            _ = error
        } else {
        }
    }

    @Published var isReadyForCommands = false // Managed actively based on characteristic discovery

    private func parse(message: String) {
        if !isReadyForCommands {
            isReadyForCommands = true
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] First BLE message received. isReadyForCommands is now true.")
        }
        
        let components = message.components(separatedBy: "/")
        guard components.count > 1 else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Parse: Message too short or invalid format: \(message)")
            return
        }
        let messageType = components[0]
        // print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Parse: Message type: \(messageType)")
        if messageType == "3" {
            var deviceSettings = DeviceSettings()
            deviceSettings.parse(message: message)
            persistenceService.save(deviceSettings: deviceSettings)
            
            // After settings saved, read settings from persistence and trigger prediction
            triggerPredictionIfPossible()
            
        } else {
            var telemetryData = TelemetryData()
            telemetryData.parse(message: message)
            self.latestTelemetry = telemetryData
            
            // Set lastTelemetryUpdateTime here after confirming valid telemetry parsed
            self.lastTelemetryUpdateTime = Date()
            
            self.telemetryData.send(telemetryData)

            // Save track data using PersistenceService
            _ = persistenceService.saveTrack(sondeName: telemetryData.sondeName, telemetryPoint: telemetryData)
            self.currentSondeTrack = persistenceService.retrieveTrack(sondeName: telemetryData.sondeName)
            self.currentSondeName = telemetryData.sondeName

            if !hasSentReadSettingsCommand && isReadyForCommands {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] First type 1 message parsed and TX ready. Reading settings...")
                readSettings()
                hasSentReadSettingsCommand = true
            }
            
            // After parsing telemetry, try triggering prediction if possible
            triggerPredictionIfPossible()

            // Removed direct call to annotationService.updateState here, as telemetryAvailabilityState changes trigger updates.
        }
    }
    @Published var latestTelemetry: TelemetryData? = nil {
        didSet {
            // Removed direct call to checkTelemetryAvailability(latestTelemetry).
            // Availability state now updated exclusively by timer.
        }
    }
    @Published var deviceSettings: DeviceSettings = .default
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var telemetryData = PassthroughSubject<TelemetryData, Never>()
    @Published var lastTelemetryUpdateTime: Date? = nil
    @Published var currentSondeTrack: [TelemetryTransferData] = []
    @Published var currentSondeName: String? = nil

    func readSettings() {
        sendCommand(command: "o{?}o")
    }

    func sendCommand(command: String) {
        // Block sendCommand if characteristic not ready to avoid crashes or lost commands
        if !isReadyForCommands {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] sendCommand blocked: TX characteristic not ready. Wait until BLE connection and discovery complete. Check previous debug output for service and characteristic discovery issues.")
            return
        }
        guard let peripheral = connectedPeripheral else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] sendCommand Error: Not connected to a peripheral.")
            return
        }
        guard let characteristic = writeCharacteristic else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] sendCommand Error: Write characteristic not found.")
            return
        }
        guard let data = command.data(using: .utf8) else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] sendCommand Error: Could not convert command string to data.")
            return
        }
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Sending command: \(command) (Raw Data: \(data.hexEncodedString()))")
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    func simulateTelemetry(_ data: TelemetryData) {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Simulating telemetry: \(data)")
        self.latestTelemetry = data
        self.lastTelemetryUpdateTime = Date()
        // Availability state updated by timer
        self.telemetryData.send(data)
    }
    
    // If there are any places setting latestTelemetry explicitly to nil, call checkTelemetryAvailability(nil) there.
    // Here, no explicit nil assignment seen except possibly elsewhere, so none added.

    func disconnect() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] Disconnect: Attempting to disconnect from peripheral.")
        if let connectedPeripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(connectedPeripheral)
        }
        centralManager.stopScan()
        connectionStatus = .disconnected
    }

    // Helper to send settings command to device
    func sendSettingsCommand(frequency: Double, probeType: Int) {
        let formattedCommand = String(format: "o{f=%.2f/tipo=%d}o", frequency, probeType)
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] sendSettingsCommand: Sending command: \(formattedCommand)")
        sendCommand(command: formattedCommand)
    }
    
    // New helper method to trigger prediction after both telemetry and device settings are available
    private func triggerPredictionIfPossible() {
        guard let latestTelemetry = latestTelemetry else {
            return
        }
        // Read prediction parameters from persistenceService (UserDefaults)
        let predictionParams = persistenceService.readPredictionParameters()
        
        guard let userSettings = predictionParams else {
            // No user settings, can't predict
            return
        }
        // Trigger PredictionService fetchPrediction
        Task { @MainActor in
            self.predictionService?.fetchPrediction(telemetry: latestTelemetry, userSettings: userSettings)
        }
    }
}

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
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
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] CurrentLocationService: Requesting location permission.")
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] CurrentLocationService: Starting location updates.")
        locationManager.startUpdatingLocation()
    }
}

extension CurrentLocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        print("[DEBUG][CurrentLocationService] didUpdateLocations called with: \(locations)")
        guard let location = locations.last else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] CurrentLocationService: No locations received.")
            return
        }
        let heading = location.course
        self.locationData = LocationData(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, heading: heading)
        // Removed print statement for location updated
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] CurrentLocationService: Failed to get location: \(error.localizedDescription)")
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

    @Published var tracks: [String: [TelemetryTransferData]] = [:]
    private let tracksUserDefaultsKey = "balloonTracks"

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

    /// Saves a telemetry point for a given sonde name.
    /// If a new sonde name is encountered and other tracks exist, all old tracks are purged.
    /// - Parameters:
    ///   - sondeName: The name of the sonde.
    ///   - telemetryPoint: The telemetry data point to save.
    /// - Returns: `true` if a data purge occurred, `false` otherwise.
    func saveTrack(sondeName: String, telemetryPoint: TelemetryData) -> Bool {
        var didPurge = false
        let transferData = TelemetryTransferData(telemetryData: telemetryPoint)

        // Check for purge condition: new sondeName and existing tracks
        if tracks[sondeName] == nil && !tracks.isEmpty {
            tracks = [:] // Purge all old tracks
            didPurge = true
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: Purged old tracks for new sonde: \(sondeName)")
        }

        // Append the new point
        tracks[sondeName, default: []].append(transferData)

        // Re-save the entire tracks dictionary to UserDefaults
        if let encoded = try? JSONEncoder().encode(tracks) {
            UserDefaults.standard.set(encoded, forKey: tracksUserDefaultsKey)
        } else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: Failed to encode tracks for saving.")
        }
        return didPurge
    }

    /// Retrieves the track for a given sonde name.
    /// - Parameter sondeName: The name of the sonde.
    /// - Returns: An array of `TelemetryTransferData` for the specified sonde, or an empty array if not found.
    func retrieveTrack(sondeName: String) -> [TelemetryTransferData] {
        return tracks[sondeName] ?? []
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

        // Load tracks from UserDefaults on init
        if let savedTracksData = UserDefaults.standard.data(forKey: tracksUserDefaultsKey) {
            if let decodedTracks = try? JSONDecoder().decode([String: [TelemetryTransferData]].self, from: savedTracksData) {
                self.tracks = decodedTracks
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: Tracks loaded from UserDefaults. Total tracks: \(tracks.count)")
            } else {
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: Failed to decode tracks from UserDefaults.")
            }
        } else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PersistenceService: No tracks found in UserDefaults, initializing empty.")
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
                // Do not block or throw, just print error and return
                return
            }
            guard let route = response?.routes.first else {
                print("[RouteCalculationService][State: \(SharedAppState.shared.appState.rawValue)] No route found.")
                DispatchQueue.main.async {
                    self.routeData = nil
                }
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
            // Whenever predictionData is set and valid, trigger route calculation
            if let prediction = predictionData, let landingPoint = prediction.landingPoint {
                // Obtain user location via injected currentLocationService if available
                if let userLocation = currentLocationService?.locationData {
                    Task { @MainActor in
                        routeCalculationService?.calculateRoute(
                            from: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
                            to: landingPoint,
                            transportType: .car
                        )
                    }
                }
            }
        }
    }
    @Published var lastAPICallURL: String? = nil
    @Published var isLoading: Bool = false

    // Injected RouteCalculationService reference for triggering route calculation
    weak var routeCalculationService: RouteCalculationService?
    weak var currentLocationService: CurrentLocationService?

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
        if SharedAppState.shared.appState == .finalApproach {
            print("[Debug][PredictionService][State: finalApproach] Skipping API call in final approach mode.")
            return
        }
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
                if let decodingError = error as? DecodingError {
                    switch decodingError {
                    case .dataCorrupted(let context):
                        print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Data corrupted: \(context.debugDescription)")
                        if let underlyingError = context.underlyingError {
                            print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Underlying error: \(underlyingError.localizedDescription)")
                        }
                    case .keyNotFound(let key, let context):
                        print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Key '\(key)' not found: \(context.debugDescription)")
                    case .valueNotFound(let type, let context):
                        print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Value of type '\(type)' not found: \(context.debugDescription)")
                    case .typeMismatch(let type, let context):
                        print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Type mismatch for type '\(type)': \(context.debugDescription)")
                    @unknown default:
                        print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Unknown decoding error: \(decodingError.localizedDescription)")
                    }
                }
                // Attempt to print raw data if available (assuming 'data' is still in scope from the 'do' block)
                // This part is tricky because 'data' is not directly accessible here.
                // For a real-world scenario, you'd capture 'data' before the 'try' block.
                // For now, we'll just print a placeholder message.
                print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Return JSON: (Raw data not captured for logging in this scope)")
            }
        }
    }
}

// MARK: - AnnotationService
@MainActor
final class AnnotationService: ObservableObject {
    /// BLECommunicationService instance observed for telemetry availability changes.
    private let bleService: BLECommunicationService
    
    /// Store cancellables for Combine subscriptions.
    private var cancellables = Set<AnyCancellable>()
    
    @Published private(set) var appState: AppState = .startup {
        didSet {
            SharedAppState.shared.appState = appState
        }
    }
    @Published var annotations: [MapAnnotationItem] = []

    /// Initialize AnnotationService with injected BLECommunicationService instance.
    /// This allows subscribing to telemetry availability changes to update annotations accordingly.
    /// - Parameter bleService: BLECommunicationService instance to observe.
    init(bleService: BLECommunicationService) {
        self.bleService = bleService
        print("[DEBUG][AnnotationService][state: \(appState.rawValue)] AnnotationService init")
        
        // Subscribe to telemetryAvailabilityState changes to respond to telemetry availability transitions.
        bleService.$telemetryAvailabilityState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAvailable in
                self?.handleTelemetryAvailabilityChanged(isAvailable)
            }
            .store(in: &cancellables)
    }
    
    /// Called whenever telemetry availability changes.
    /// Updates annotations depending on whether telemetry is now available or lost.
    /// - Parameter isAvailable: Boolean indicating current telemetry availability.
    private func handleTelemetryAvailabilityChanged(_ isAvailable: Bool) {
        if isAvailable {
            // Telemetry became available: update annotations with latest data.
            let telemetry = bleService.latestTelemetry
            let userLocation = bleService.currentLocationService?.locationData
            let prediction = bleService.predictionService?.predictionData
            let route = bleService.predictionService?.routeCalculationService?.routeData
            let telemetryHistory = bleService.currentSondeTrack.map {
                TelemetryData(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude)
            }
            let lastUpdateTime = bleService.lastTelemetryUpdateTime
            
            updateAnnotations(
                telemetry: telemetry,
                userLocation: userLocation,
                prediction: prediction,
                lastTelemetryUpdateTime: lastUpdateTime
            )
        } else {
            // Telemetry lost: clear balloon-related annotations and keep user location annotation if present.
            var items: [MapAnnotationItem] = []
            if let userLoc = bleService.currentLocationService?.locationData {
                items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: userLoc.latitude, longitude: userLoc.longitude), kind: .user))
            }
            self.annotations = items
        }
    }

    func updateState(
        telemetry: TelemetryData?,
        userLocation: LocationData?,
        prediction: PredictionData?,
        route: RouteData?,
        telemetryHistory: [TelemetryData],
        lastTelemetryUpdateTime: Date?
    ) {
        if telemetry != nil {
            let telemetryStr = "lat=\(telemetry!.latitude), lon=\(telemetry!.longitude), alt=\(telemetry!.altitude)"
            _ = telemetryStr
            let _ = prediction != nil
            let _ = route != nil
            let _ = telemetryHistory.count
            print("[DEBUG][AnnotationService][state: \(appState.rawValue)] telemetry=(\(telemetryStr)), prediction=\(prediction != nil ? "true" : "false"), route=\(route != nil ? "true" : "false"), history=\(telemetryHistory.count)")
        } else {
            _ = prediction != nil
            _ = route != nil
            _ = telemetryHistory.count
            print("[DEBUG][AnnotationService][state: \(appState.rawValue)] telemetry=nil, prediction=\(prediction != nil ? "true" : "false"), route=\(route != nil ? "true" : "false"), history=\(telemetryHistory.count)")
        }

        // Then, run the state machine
        switch appState {
        case .startup:
            // Trigger to move to long range tracking only if all required data is present and route is valid
            if let _ = telemetry,
               let prediction = prediction, prediction.landingPoint != nil,
               let route = route, route.path != nil {
                appState = .longRangeTracking
            }
        case .longRangeTracking:
            // Trigger to move to final approach
            guard let userLoc = userLocation,
                  let tel = telemetry,
                  telemetryHistory.count >= 10 else {
                break
            }

            let last10Telemetry = telemetryHistory.suffix(10)
            let isBalloonStable = last10Telemetry.allSatisfy { $0.verticalSpeed < 1 && $0.horizontalSpeed < 5 }

            if isBalloonStable {
                 let userCLLocation = CLLocation(latitude: userLoc.latitude, longitude: userLoc.longitude)
                 let balloonCLLocation = CLLocation(latitude: tel.latitude, longitude: tel.longitude)
                 let distance = userCLLocation.distance(from: balloonCLLocation)
                 let isUserClose = distance < 1000 // 1 km

                if isUserClose {
                    appState = .finalApproach
                }
            }
        case .finalApproach:
            // No transition out of final approach defined yet
            break
        }
        
        // First, update annotations regardless of state
        updateAnnotations(telemetry: telemetry, userLocation: userLocation, prediction: prediction, lastTelemetryUpdateTime: lastTelemetryUpdateTime)
    }

    private func updateAnnotations(
        telemetry: TelemetryData?,
        userLocation: LocationData?,
        prediction: PredictionData?,
        lastTelemetryUpdateTime: Date?
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
                items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: tel.latitude, longitude: tel.longitude), kind: .balloon, isAscending: isAscending, lastUpdateTime: lastTelemetryUpdateTime, altitude: tel.altitude))
                
                // Add burst point (prediction) only if ascending
                if isAscending {
                    if let burst = prediction?.burstPoint {
                        items.append(MapAnnotationItem(coordinate: burst, kind: .burst))
                    }
                }
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

    private var cancellables = Set<AnyCancellable>()
    private var predictionTimer: Timer?

    init() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] ServiceManager init")
        self.persistenceService = PersistenceService()
        self.bleCommunicationService = BLECommunicationService(persistenceService: self.persistenceService)
        self.currentLocationService = CurrentLocationService()
        self.routeCalculationService = RouteCalculationService()
        self.predictionService = PredictionService()
        // Pass bleCommunicationService instance to AnnotationService for telemetry availability subscription
        self.annotationService = AnnotationService(bleService: self.bleCommunicationService)
        // Inject annotationService reference into BLECommunicationService
        self.bleCommunicationService.annotationService = self.annotationService
        // Inject predictionService and currentLocationService into BLECommunicationService for triggers
        self.bleCommunicationService.predictionService = self.predictionService
        self.bleCommunicationService.currentLocationService = self.currentLocationService

        // Inject RouteCalculationService and CurrentLocationService into PredictionService for route calculation trigger
        self.predictionService.routeCalculationService = self.routeCalculationService
        self.predictionService.currentLocationService = self.currentLocationService

        // Setup Combine subscriptions to propagateStateUpdates on relevant changes
        bleCommunicationService.$latestTelemetry
            .sink { [weak self] _ in self?.propagateStateUpdates() }
            .store(in: &cancellables)

        currentLocationService.$locationData
            .sink { [weak self] _ in self?.propagateStateUpdates() }
            .store(in: &cancellables)

        predictionService.$predictionData
            .sink { [weak self] _ in self?.propagateStateUpdates() }
            .store(in: &cancellables)

        routeCalculationService.$routeData
            .sink { [weak self] _ in self?.propagateStateUpdates() }
            .store(in: &cancellables)

        bleCommunicationService.$currentSondeTrack
            .sink { [weak self] _ in self?.propagateStateUpdates() }
            .store(in: &cancellables)
        
        setupTimers()
    }

    private func setupTimers() {
        predictionTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                print("[DEBUG][ServiceManager] 60s timer fired. Fetching prediction.")
                guard let telemetry = await self.bleCommunicationService.latestTelemetry,
                      let userSettings = await self.persistenceService.readPredictionParameters() else { return }
                
                if await self.annotationService.appState != .startup {
                    await self.predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
                }
            }
        }
    }

    func propagateStateUpdates() {
        let telemetry = bleCommunicationService.latestTelemetry
        let userLocation = currentLocationService.locationData
        let prediction = predictionService.predictionData
        let route = routeCalculationService.routeData
        let telemetryHistory = bleCommunicationService.currentSondeTrack.map {
            TelemetryData(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude)
        }
        annotationService.updateState(
            telemetry: telemetry,
            userLocation: userLocation,
            prediction: prediction,
            route: route,
            telemetryHistory: telemetryHistory,
            lastTelemetryUpdateTime: bleCommunicationService.lastTelemetryUpdateTime
        )
    }
}

