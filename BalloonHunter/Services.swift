// Services.swift
// Consolidated service layer for BalloonHunter
// Contains all service implementations in one organized file

import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import OSLog

// MARK: - BLE Communication Service

@MainActor
final class BLECommunicationService: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    var centralManager: CBCentralManager!
    private var persistenceService: PersistenceService
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var serviceHealth: ServiceHealth = .healthy

    private let UART_SERVICE_UUID = CBUUID(string: "53797269-614D-6972-6B6F-44616C6D6F6E")
    private let UART_RX_CHARACTERISTIC_UUID = CBUUID(string: "53797267-614D-6972-6B6F-44616C6D6F8E")
    private let UART_TX_CHARACTERISTIC_UUID = CBUUID(string: "53797268-614D-6972-6B6F-44616C6D6F7E")

    private var hasSentReadSettingsCommand = false

    // Buffer to accumulate incoming BLE data fragments until a full message is received
    private var incomingBLEBuffer: Data = Data()

    @Published var telemetryAvailabilityState: Bool = false
    @Published var latestTelemetry: TelemetryData? = nil
    @Published var deviceSettings: DeviceSettings = .default
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var telemetryData = PassthroughSubject<TelemetryData, Never>()
    @Published var lastTelemetryUpdateTime: Date? = nil
    @Published var isReadyForCommands = false
    let centralManagerPoweredOn = PassthroughSubject<Void, Never>()

    init(persistenceService: PersistenceService) {
        self.persistenceService = persistenceService
        super.init()
        appLog("BLE: Initializing CBCentralManager", category: .ble, level: .info)
        centralManager = CBCentralManager(delegate: self, queue: nil)

        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateTelemetryAvailabilityState()
            }
        }
        
        appLog("BLE: BLECommunicationService initialization complete", category: .ble, level: .info)
        publishHealthEvent(.healthy, message: "BLE service initialized")
    }

    private func updateTelemetryAvailabilityState() async {
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
                appLog("BLECommunicationService: Telemetry GAINED: lastTelemetryUpdateTime within 3 seconds.", category: .ble, level: .info)
            } else {
                appLog("BLECommunicationService: Telemetry LOST: lastTelemetryUpdateTime older than 3 seconds.", category: .ble, level: .info)
            }
        }
    }

    private func checkTelemetryAvailability(_ newTelemetry: TelemetryData?) {
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateString = bluetoothStateString(central.state)
        appLog("BLE: Bluetooth state changed to \(central.state.rawValue) (\(stateString))", category: .ble, level: .info)
        
        switch central.state {
        case .poweredOn:
            appLog("BLE: Bluetooth powered on, ready for scanning", category: .ble, level: .info)
            centralManagerPoweredOn.send(())
            publishHealthEvent(.healthy, message: "Bluetooth powered on")
        case .poweredOff:
            appLog("BLE: Bluetooth is powered off - please enable Bluetooth in Settings", category: .ble, level: .error)
            connectionStatus = .disconnected
            publishHealthEvent(.unhealthy, message: "Bluetooth powered off")
        case .resetting:
            appLog("BLE: Bluetooth is resetting - waiting for completion", category: .ble, level: .info)
            publishHealthEvent(.degraded, message: "Bluetooth resetting")
            break
        case .unauthorized:
            appLog("BLE: Bluetooth access unauthorized - check app permissions", category: .ble, level: .error)
            publishHealthEvent(.unhealthy, message: "Bluetooth unauthorized")
            break
        case .unknown:
            appLog("BLE: Bluetooth state unknown - initializing", category: .ble, level: .info)
            publishHealthEvent(.degraded, message: "Bluetooth state unknown")
            break
        case .unsupported:
            appLog("BLE: Bluetooth not supported on this device", category: .ble, level: .error)
            publishHealthEvent(.unhealthy, message: "Bluetooth unsupported")
            break
        @unknown default:
            appLog("BLE: Unknown Bluetooth state: \(central.state.rawValue)", category: .ble, level: .error)
            publishHealthEvent(.degraded, message: "Unknown Bluetooth state")
            break
        }
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            appLog("BLE: Cannot start scanning - Bluetooth not powered on (state: \(centralManager.state.rawValue))", category: .ble, level: .error)
            return
        }
        
        appLog("BLE: Starting scan for peripherals (state: \(centralManager.state.rawValue))", category: .ble, level: .info)
        centralManager.scanForPeripherals(withServices: [UART_SERVICE_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        publishHealthEvent(.healthy, message: "BLE scanning started")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let name = peripheral.name, name.contains("MySondy") {
            appLog("BLE: Found MySondy device: \(name)", category: .ble, level: .info)
            central.stopScan()
            connectedPeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            publishHealthEvent(.healthy, message: "MySondy device found")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        appLog("BLE: Successfully connected to \(peripheral.name ?? "Unknown")", category: .ble, level: .info)
        connectionStatus = .connected
        peripheral.discoverServices([UART_SERVICE_UUID])
        publishHealthEvent(.healthy, message: "BLE connected successfully")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let errorMessage = error?.localizedDescription ?? "Unknown error"
        appLog("BLE: Failed to connect to peripheral: \(errorMessage)", category: .ble, level: .error)
        connectionStatus = .disconnected
        publishHealthEvent(.unhealthy, message: "BLE connection failed: \(errorMessage)")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let errorMessage = error?.localizedDescription ?? "Disconnected normally"
        appLog("BLE: Disconnected from peripheral: \(errorMessage)", category: .ble, level: .info)
        connectionStatus = .disconnected
        isReadyForCommands = false
        publishHealthEvent(.degraded, message: "BLE disconnected")
        
        // Auto-reconnect if disconnected unexpectedly
        if error != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.startScanning()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            appLog("BLE: Error discovering services: \(error.localizedDescription)", category: .ble, level: .error)
            publishHealthEvent(.unhealthy, message: "Service discovery failed")
            return
        }

        for service in peripheral.services ?? [] {
            if service.uuid == UART_SERVICE_UUID {
                peripheral.discoverCharacteristics([UART_TX_CHARACTERISTIC_UUID, UART_RX_CHARACTERISTIC_UUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            appLog("BLE: Error discovering characteristics: \(error.localizedDescription)", category: .ble, level: .error)
            publishHealthEvent(.unhealthy, message: "Characteristic discovery failed")
            return
        }

        let characteristics = service.characteristics ?? []
        appLog("Discovered \(characteristics.count) characteristic(s) for service \(service.uuid).", category: .ble, level: .debug)

        for characteristic in characteristics {
            switch characteristic.uuid {
            case UART_TX_CHARACTERISTIC_UUID:
                appLog("Found UART TX Characteristic. Checking write properties...", category: .ble, level: .debug)
                if characteristic.properties.contains(.write) {
                    writeCharacteristic = characteristic
                    appLog("Assigned TX characteristic for writing (write).", category: .ble, level: .debug)
                } else if characteristic.properties.contains(.writeWithoutResponse) {
                    writeCharacteristic = characteristic
                    appLog("Assigned TX characteristic for writing (writeWithoutResponse).", category: .ble, level: .debug)
                } else {
                    appLog("TX characteristic does not support writing.", category: .ble, level: .error)
                }

            case UART_RX_CHARACTERISTIC_UUID:
                appLog("Found UART RX Characteristic. Checking notify property...", category: .ble, level: .debug)
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                    appLog("Set notify value to true for RX characteristic.", category: .ble, level: .debug)
                } else {
                    appLog("RX characteristic does not support notifications.", category: .ble, level: .error)
                }

            default:
                appLog("Unknown characteristic: \(characteristic.uuid)", category: .ble, level: .debug)
            }
        }

        // Check if we have both characteristics configured
        if writeCharacteristic != nil {
            isReadyForCommands = true
            appLog("BLE: Ready for commands", category: .ble, level: .info)
            publishHealthEvent(.healthy, message: "BLE ready for commands")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            appLog("BLE: Error updating value: \(error.localizedDescription)", category: .ble, level: .error)
            publishHealthEvent(.degraded, message: "BLE update error")
            return
        }

        guard let data = characteristic.value else {
            appLog("BLE: No data received from characteristic", category: .ble, level: .error)
            return
        }

        // Accumulate data in buffer
        incomingBLEBuffer.append(data)

        // Process complete messages (terminated by newline or specific delimiter)
        processIncomingBLEData()
    }

    private func processIncomingBLEData() {
        guard let dataString = String(data: incomingBLEBuffer, encoding: .utf8) else {
            appLog("BLE: Failed to convert data to string", category: .ble, level: .error)
            incomingBLEBuffer.removeAll()
            return
        }

        let lines = dataString.components(separatedBy: .newlines)
        
        // Process all complete lines (all but the last, which may be incomplete)
        for i in 0..<(lines.count - 1) {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                processCompleteBLEMessage(line)
            }
        }

        // Keep the last (potentially incomplete) line in the buffer
        if let lastLine = lines.last, !lastLine.contains("\n") {
            incomingBLEBuffer = lastLine.data(using: .utf8) ?? Data()
        } else {
            incomingBLEBuffer.removeAll()
        }
    }

    private func processCompleteBLEMessage(_ message: String) {
        appLog("BLE: Processing message: \(message)", category: .ble, level: .debug)
        
        let components = message.components(separatedBy: "/")
        guard !components.isEmpty else {
            appLog("BLE: Empty message received", category: .ble, level: .error)
            return
        }

        let messageType = components[0]
        
        switch messageType {
        case "1": // Telemetry data
            if let telemetry = parseTelemetryMessage(components) {
                DispatchQueue.main.async {
                    self.latestTelemetry = telemetry
                    self.lastTelemetryUpdateTime = Date()
                    self.telemetryData.send(telemetry)
                    
                    // Publish telemetry event to EventBus
                    EventBus.shared.publishTelemetryEvent(TelemetryEvent(telemetry: telemetry, timestamp: Date()))
                    
                    appLog("BLE: Telemetry - \(telemetry.sondeName) at \(Int(telemetry.altitude))m", category: .ble, level: .info)
                }
            }
            
        case "3": // Device settings
            if let settings = parseDeviceSettings(components) {
                DispatchQueue.main.async {
                    self.deviceSettings = settings
                    self.persistenceService.save(deviceSettings: settings)
                    appLog("BLE: Device settings received and saved", category: .ble, level: .info)
                }
            }
            
        default:
            appLog("BLE: Unknown message type: \(messageType)", category: .ble, level: .error)
        }
    }

    private func parseTelemetryMessage(_ components: [String]) -> TelemetryData? {
        guard components.count >= 20 else {
            appLog("BLE: Insufficient telemetry components: \(components.count)", category: .ble, level: .error)
            return nil
        }
        
        // Parse telemetry components according to protocol
        let sondeName = components[1]
        let latitude = Double(components[5]) ?? 0.0
        let longitude = Double(components[6]) ?? 0.0
        let altitude = Double(components[7]) ?? 0.0
        let verticalSpeed = Double(components[8]) ?? 0.0
        let horizontalSpeed = Double(components[9]) ?? 0.0
        let signalStrength = Double(components[14]) ?? 0.0
        let afcFrequency = Int(components[18]) ?? 0
        let buzmute = components[19] == "1"
        
        return TelemetryData(
            sondeName: sondeName,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            verticalSpeed: verticalSpeed,
            horizontalSpeed: horizontalSpeed,
            signalStrength: signalStrength,
            afcFrequency: afcFrequency,
            buzmute: buzmute,
            lastUpdateTime: Date().timeIntervalSince1970
        )
    }

    private func parseDeviceSettings(_ components: [String]) -> DeviceSettings? {
        // Parse device settings from BLE response
        // Implementation depends on the specific format returned by MySondyGo
        var settings = DeviceSettings.default
        
        // Parse each component and update settings
        for component in components.dropFirst() {
            if component.contains("=") {
                let parts = component.components(separatedBy: "=")
                if parts.count == 2 {
                    let key = parts[0]
                    let value = parts[1]
                    
                    switch key {
                    case "f": settings.frequency = Double(value) ?? settings.frequency
                    case "tipo": 
                        if let typeNum = Int(value) {
                            switch typeNum {
                            case 1: settings.sondeType = "RS41"
                            case 2: settings.sondeType = "M20"
                            case 3: settings.sondeType = "M10"
                            case 4: settings.sondeType = "PILOT"
                            case 5: settings.sondeType = "DFM"
                            default: break
                            }
                        }
                    case "myCall": settings.callSign = value
                    case "freqofs": settings.frequencyCorrection = Int(value) ?? settings.frequencyCorrection
                    default: break
                    }
                }
            }
        }
        
        return settings
    }

    func readSettings() {
        sendCommand(command: "o{?}o")
    }

    func sendCommand(command: String) {
        if !isReadyForCommands {
            return
        }
        guard let peripheral = connectedPeripheral else {
            return
        }
        guard let characteristic = writeCharacteristic else {
            return
        }

        let data = command.data(using: .utf8)!
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        appLog("BLE: Sent command: \(command)", category: .ble, level: .debug)
    }

    private func publishHealthEvent(_ health: ServiceHealth, message: String) {
        serviceHealth = health
        EventBus.shared.publishServiceHealthEvent(ServiceHealthEvent(
            service: "BLECommunicationService",
            health: health,
            message: message,
            timestamp: Date()
        ))
    }

    private func bluetoothStateString(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Current Location Service

@MainActor
final class CurrentLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    
    @Published var locationData: LocationData? = nil
    @Published var isLocationPermissionGranted: Bool = false
    
    private let locationManager = CLLocationManager()
    private var lastHeading: Double? = nil
    private var currentBalloonPosition: CLLocationCoordinate2D?
    private var currentProximityMode: ProximityMode = .far
    
    // GPS configuration based on proximity to balloon
    enum ProximityMode {
        case far    // >5km from balloon - 10m accuracy, 5m filter
        case near   // 1-5km from balloon - 5m accuracy, 2m filter  
        case close  // <1km from balloon - 3m accuracy, 1m filter
    }
    
    override init() {
        super.init()
        locationManager.delegate = self
        configureGPSForMode(.far) // Start with far-range settings
        setupBalloonTrackingSubscription()
        appLog("CurrentLocationService: GPS configured for FAR RANGE - 10m accuracy, 5m distance filter", category: .service, level: .info)
        appLog("CurrentLocationService: Initialized with dynamic proximity filtering", category: .service, level: .info)
    }
    
    private func setupBalloonTrackingSubscription() {
        // Subscribe to balloon position events to track balloon position
        EventBus.shared.balloonPositionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.updateBalloonPosition(event.telemetry)
            }
            .store(in: &Set<AnyCancellable>())
    }
    
    private func updateBalloonPosition(_ telemetry: TelemetryData) {
        let newBalloonPosition = CLLocationCoordinate2D(
            latitude: telemetry.latitude,
            longitude: telemetry.longitude
        )
        
        currentBalloonPosition = newBalloonPosition
        
        // Check if we need to switch GPS modes based on distance
        if let userLocation = locationData {
            evaluateProximityMode(userLocation: userLocation)
        }
    }
    
    private func evaluateProximityMode(userLocation: LocationData) {
        guard let balloonPosition = currentBalloonPosition else { return }
        
        let userCoordinate = CLLocationCoordinate2D(
            latitude: userLocation.latitude,
            longitude: userLocation.longitude
        )
        
        let distance = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
            .distance(from: CLLocation(latitude: balloonPosition.latitude, longitude: balloonPosition.longitude))
        
        let newMode: ProximityMode
        if distance < 1000 { // <1km
            newMode = .close
        } else if distance < 5000 { // 1-5km
            newMode = .near
        } else { // >5km
            newMode = .far
        }
        
        if newMode != currentProximityMode {
            currentProximityMode = newMode
            configureGPSForMode(newMode)
            
            let modeString = newMode == .close ? "CLOSE" : (newMode == .near ? "NEAR" : "FAR")
            appLog("CurrentLocationService: Switched to \(modeString) RANGE GPS (distance: \(Int(distance))m)", category: .service, level: .info)
        }
    }
    
    private func configureGPSForMode(_ mode: ProximityMode) {
        switch mode {
        case .far:
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 5.0
        case .near:
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = 2.0
        case .close:
            locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            locationManager.distanceFilter = 1.0
        }
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        locationManager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            isLocationPermissionGranted = true
            locationManager.startUpdatingLocation()
            locationManager.startUpdatingHeading()
            publishHealthEvent(.healthy, message: "Location permission granted")
        case .denied, .restricted:
            isLocationPermissionGranted = false
            publishHealthEvent(.unhealthy, message: "Location permission denied")
        case .notDetermined:
            publishHealthEvent(.degraded, message: "Location permission not determined")
        @unknown default:
            publishHealthEvent(.degraded, message: "Unknown location authorization status")
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }
        let heading = lastHeading ?? location.course
        DispatchQueue.main.async {
            let now = Date()
            
            // Check if this is the first location update
            let isFirstUpdate = self.locationData == nil
            
            // Calculate distance and time differences for filtering
            var distanceDiff: Double = 0
            var timeDiff: TimeInterval = 0
            
            if let previousLocation = self.locationData {
                let prevCLLocation = CLLocation(latitude: previousLocation.latitude, longitude: previousLocation.longitude)
                distanceDiff = location.distance(from: prevCLLocation)
                timeDiff = now.timeIntervalSince(Date(timeIntervalSince1970: previousLocation.timestamp))
            }
            
            // Create new location data
            let newLocationData = LocationData(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                heading: heading,
                accuracy: location.horizontalAccuracy,
                timestamp: now.timeIntervalSince1970
            )
            
            self.locationData = newLocationData
            
            // Publish location event
            EventBus.shared.publishUserLocationEvent(UserLocationEvent(
                locationData: newLocationData,
                timestamp: now
            ))
            
            if isFirstUpdate {
                appLog("Initial user location: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude)", category: .service, level: .info)
            } else {
                let modeString = self.currentProximityMode == .close ? "CLOSE" : (self.currentProximityMode == .near ? "NEAR" : "FAR")
                appLog("User location update [\(modeString)]: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude), dist=\(distanceDiff)m, timeDiff=\(timeDiff)s", category: .service, level: .debug)
            }
            
            // Re-evaluate proximity mode with new location
            self.evaluateProximityMode(userLocation: newLocationData)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        lastHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        appLog("CurrentLocationService: Location error: \(error.localizedDescription)", category: .service, level: .error)
        publishHealthEvent(.unhealthy, message: "Location error: \(error.localizedDescription)")
    }
    
    private func publishHealthEvent(_ health: ServiceHealth, message: String) {
        EventBus.shared.publishServiceHealthEvent(ServiceHealthEvent(
            service: "CurrentLocationService",
            health: health,
            message: message,
            timestamp: Date()
        ))
    }
}

// MARK: - Balloon Position Service

@MainActor
final class BalloonPositionService: ObservableObject {
    // Current position and telemetry data
    @Published var currentPosition: CLLocationCoordinate2D?
    @Published var currentTelemetry: TelemetryData?
    @Published var currentAltitude: Double?
    @Published var currentVerticalSpeed: Double?
    @Published var currentBalloonName: String?
    
    // Derived position data
    @Published var distanceToUser: Double?
    @Published var timeSinceLastUpdate: TimeInterval = 0
    @Published var hasReceivedTelemetry: Bool = false
    
    private let bleService: BLECommunicationService
    private var currentUserLocation: LocationData?
    private var lastTelemetryTime: Date?
    private var cancellables = Set<AnyCancellable>()
    
    init(bleService: BLECommunicationService) {
        self.bleService = bleService
        setupSubscriptions()
        appLog("BalloonPositionService: Initialized", category: .service, level: .info)
    }
    
    private func setupSubscriptions() {
        // Subscribe to telemetry updates from BLE service
        bleService.$latestTelemetry
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] telemetry in
                self?.handleTelemetryUpdate(telemetry)
            }
            .store(in: &cancellables)
        
        // Subscribe to user location updates for distance calculations
        EventBus.shared.userLocationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUserLocationUpdate(event.locationData)
            }
            .store(in: &cancellables)
        
        // Update time since last update periodically
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateTimeSinceLastUpdate()
            }
            .store(in: &cancellables)
    }
    
    private func handleTelemetryUpdate(_ telemetry: TelemetryData) {
        let now = Date()
        
        // Update current state
        currentTelemetry = telemetry
        currentPosition = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
        currentAltitude = telemetry.altitude
        currentVerticalSpeed = telemetry.verticalSpeed
        currentBalloonName = telemetry.sondeName
        hasReceivedTelemetry = true
        lastTelemetryTime = now
        
        // Update distance to user if location available
        updateDistanceToUser()
        
        // Publish position update event
        let positionEvent = BalloonPositionEvent(
            balloonId: telemetry.sondeName,
            position: currentPosition!,
            telemetry: telemetry
        )
        EventBus.shared.publishBalloonPosition(positionEvent)
        
        appLog("BalloonPositionService: Updated position for balloon \(telemetry.sondeName) at (\(telemetry.latitude), \(telemetry.longitude), \(telemetry.altitude)m)", category: .service, level: .debug)
    }
    
    private func handleUserLocationUpdate(_ location: LocationData) {
        currentUserLocation = location
        updateDistanceToUser()
    }
    
    private func updateDistanceToUser() {
        guard let balloonPosition = currentPosition,
              let userLocation = currentUserLocation else {
            distanceToUser = nil
            return
        }
        
        let balloonCLLocation = CLLocation(latitude: balloonPosition.latitude, longitude: balloonPosition.longitude)
        let userCLLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        distanceToUser = balloonCLLocation.distance(from: userCLLocation)
    }
    
    private func updateTimeSinceLastUpdate() {
        guard let lastUpdate = lastTelemetryTime else {
            timeSinceLastUpdate = 0
            return
        }
        timeSinceLastUpdate = Date().timeIntervalSince(lastUpdate)
    }
    
    // Convenience methods for policies
    func getBalloonLocation() -> CLLocationCoordinate2D? {
        return currentPosition
    }
    
    func getLatestTelemetry() -> TelemetryData? {
        return currentTelemetry
    }
    
    func getDistanceToUser() -> Double? {
        return distanceToUser
    }
    
    func isWithinRange(_ distance: Double) -> Bool {
        guard let currentDistance = distanceToUser else { return false }
        return currentDistance <= distance
    }
}

// MARK: - Balloon Track Service

@MainActor
final class BalloonTrackService: ObservableObject {
    @Published var currentBalloonTrack: [BalloonTrackPoint] = []
    @Published var currentBalloonName: String?
    @Published var currentEffectiveDescentRate: Double?
    @Published var trackUpdated = PassthroughSubject<Void, Never>()
    
    private let persistenceService: PersistenceService
    private let balloonPositionService: BalloonPositionService
    private var cancellables = Set<AnyCancellable>()
    
    // Track management
    private var telemetryPointCounter = 0
    private let saveInterval = 10 // Save every 10 telemetry points
    
    init(persistenceService: PersistenceService, balloonPositionService: BalloonPositionService) {
        self.persistenceService = persistenceService
        self.balloonPositionService = balloonPositionService
        appLog("BalloonTrackService: Initialized", category: .service, level: .info)
        setupSubscriptions()
        loadPersistedDataAtStartup()
    }
    
    /// Load any persisted balloon data at startup
    private func loadPersistedDataAtStartup() {
        // Try to load any existing track data from persistence
        // Note: We don't know the sonde name yet, so we can't load specific tracks
        // But we can prepare the service for when telemetry arrives
        appLog("BalloonTrackService: Ready to load persisted data on first telemetry", category: .service, level: .info)
    }
    
    private func setupSubscriptions() {
        // Subscribe to position service for telemetry updates (proper service layer architecture)
        EventBus.shared.balloonPositionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] positionEvent in
                self?.processTelemetryData(positionEvent.telemetry)
            }
            .store(in: &cancellables)
    }
    
    func processTelemetryData(_ telemetryData: TelemetryData) {
        if currentBalloonName == nil || telemetryData.sondeName != currentBalloonName {
            appLog("BalloonTrackService: New sonde detected - \(telemetryData.sondeName), switching from \(currentBalloonName ?? "none")", category: .service, level: .info)
            persistenceService.purgeAllTracks()
            let persistedTrack = persistenceService.loadTrackForCurrentSonde(sondeName: telemetryData.sondeName)
            if let track = persistedTrack {
                self.currentBalloonTrack = track
                appLog("BalloonTrackService: Loaded persisted track for \(telemetryData.sondeName) with \(self.currentBalloonTrack.count) points", category: .service, level: .info)
            } else {
                self.currentBalloonTrack = []
                appLog("BalloonTrackService: No persisted track found - starting fresh track for \(telemetryData.sondeName)", category: .service, level: .info)
            }
            telemetryPointCounter = 0
        }
        
        currentBalloonName = telemetryData.sondeName
        
        let trackPoint = BalloonTrackPoint(
            latitude: telemetryData.latitude,
            longitude: telemetryData.longitude,
            altitude: telemetryData.altitude,
            verticalSpeed: telemetryData.verticalSpeed,
            horizontalSpeed: telemetryData.horizontalSpeed,
            timestamp: telemetryData.lastUpdateTime ?? Date().timeIntervalSince1970
        )
        
        currentBalloonTrack.append(trackPoint)
        
        // Calculate effective descent rate from track history
        updateEffectiveDescentRate()
        
        // Publish track update
        trackUpdated.send()
        
        // Periodic persistence
        telemetryPointCounter += 1
        if telemetryPointCounter % saveInterval == 0 {
            saveCurrentTrack()
        }
    }
    
    private func updateEffectiveDescentRate() {
        guard currentBalloonTrack.count >= 5 else { return }
        
        let recentPoints = Array(currentBalloonTrack.suffix(5))
        let altitudes = recentPoints.map { $0.altitude }
        let timestamps = recentPoints.map { $0.timestamp }
        
        // Simple linear regression for descent rate
        let n = Double(altitudes.count)
        let sumX = timestamps.reduce(0, +)
        let sumY = altitudes.reduce(0, +)
        let sumXY = zip(timestamps, altitudes).map(*).reduce(0, +)
        let sumXX = timestamps.map { $0 * $0 }.reduce(0, +)
        
        let denominator = n * sumXX - sumX * sumX
        if denominator != 0 {
            let slope = (n * sumXY - sumX * sumY) / denominator
            currentEffectiveDescentRate = slope // m/s
        }
    }
    
    private func saveCurrentTrack() {
        guard let balloonName = currentBalloonName else { return }
        persistenceService.saveBalloonTrack(sondeName: balloonName, track: currentBalloonTrack)
    }
    
    // Public API
    func getAllTrackPoints() -> [BalloonTrackPoint] {
        return currentBalloonTrack
    }
    
    func getRecentTrackPoints(_ count: Int) -> [BalloonTrackPoint] {
        return Array(currentBalloonTrack.suffix(count))
    }
    
    func clearCurrentTrack() {
        currentBalloonTrack.removeAll()
        trackUpdated.send()
    }
}

// MARK: - Prediction Service

@MainActor
final class PredictionService: ObservableObject {
    private let session = URLSession.shared
    private var serviceHealth: ServiceHealth = .healthy
    
    init() {
        appLog("PredictionService: Initialized as pure service", category: .service, level: .info)
        publishHealthEvent(.healthy, message: "Prediction service initialized")
    }
    
    func fetchPrediction(telemetry: TelemetryData, userSettings: UserSettings, measuredDescentRate: Double, cacheKey: String) async throws -> PredictionData {
        appLog("PredictionService: Starting prediction fetch for \(telemetry.sondeName) at altitude \(telemetry.altitude)m", category: .service, level: .info)
        
        let url = buildPredictionURL(telemetry: telemetry, userSettings: userSettings, measuredDescentRate: measuredDescentRate)
        
        do {
            appLog("PredictionService: Attempting URLSession data task.", category: .service, level: .debug)
            let (data, response) = try await session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PredictionError.invalidResponse
            }
            
            appLog("PredictionService: HTTP Status Code: \(httpResponse.statusCode)", category: .service, level: .debug)
            
            guard httpResponse.statusCode == 200 else {
                publishHealthEvent(.degraded, message: "HTTP \(httpResponse.statusCode)")
                throw PredictionError.httpError(httpResponse.statusCode)
            }
            
            appLog("PredictionService: Data received, attempting JSON decode.", category: .service, level: .debug)
            
            let predictionData = try JSONDecoder().decode(PredictionData.self, from: data)
            
            appLog("PredictionService: JSON decode successful.", category: .service, level: .debug)
            
            let landingPoint = predictionData.landingPoint
            let burstPoint = predictionData.burstPoint
            
            appLog("PredictionService: Prediction completed successfully - Landing point: (\(landingPoint.latitude), \(landingPoint.longitude)), Burst point: (\(burstPoint.latitude), \(burstPoint.longitude))", category: .service, level: .info)
            
            publishHealthEvent(.healthy, message: "Prediction successful")
            return predictionData
            
        } catch {
            appLog("PredictionService: Prediction failed with error: \(error.localizedDescription)", category: .service, level: .error)
            publishHealthEvent(.unhealthy, message: "Prediction failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func buildPredictionURL(telemetry: TelemetryData, userSettings: UserSettings, measuredDescentRate: Double) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "predict.cusf.co.uk"
        components.path = "/api/v1"
        
        let queryItems = [
            URLQueryItem(name: "launch_latitude", value: String(telemetry.latitude)),
            URLQueryItem(name: "launch_longitude", value: String(telemetry.longitude)),
            URLQueryItem(name: "launch_altitude", value: String(telemetry.altitude)),
            URLQueryItem(name: "launch_datetime", value: ISO8601DateFormatter().string(from: Date())),
            URLQueryItem(name: "ascent_rate", value: String(userSettings.ascentRate)),
            URLQueryItem(name: "burst_altitude", value: String(userSettings.burstAltitude)),
            URLQueryItem(name: "descent_rate", value: String(abs(measuredDescentRate)))
        ]
        
        components.queryItems = queryItems
        return components.url!
    }
    
    private func publishHealthEvent(_ health: ServiceHealth, message: String) {
        serviceHealth = health
        EventBus.shared.publishServiceHealthEvent(ServiceHealthEvent(
            service: "PredictionService",
            health: health,
            message: message,
            timestamp: Date()
        ))
    }
}

// MARK: - Route Calculation Service

@MainActor
final class RouteCalculationService: ObservableObject {
    private let landingPointService: LandingPointService
    private let currentLocationService: CurrentLocationService
    
    init(landingPointService: LandingPointService, currentLocationService: CurrentLocationService) {
        self.landingPointService = landingPointService
        self.currentLocationService = currentLocationService
        appLog("RouteCalculationService init", category: .service, level: .debug)
    }
    
    func calculateRoute(from userLocation: LocationData, to destination: CLLocationCoordinate2D, transportMode: TransportationMode) async throws -> RouteData {
        let request = MKDirections.Request()
        
        // Source
        let sourcePlacemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude))
        request.source = MKMapItem(placemark: sourcePlacemark)
        
        // Destination
        let destinationPlacemark = MKPlacemark(coordinate: destination)
        request.destination = MKMapItem(placemark: destinationPlacemark)
        
        // Transport mode
        request.transportType = transportMode == .car ? .automobile : .walking
        
        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        
        guard let route = response.routes.first else {
            throw RouteError.noRouteFound
        }
        
        return RouteData(
            polyline: route.polyline,
            distance: route.distance,
            expectedTravelTime: route.expectedTravelTime,
            transportMode: transportMode
        )
    }
}

// MARK: - Landing Point Service

@MainActor  
final class LandingPointService: ObservableObject {
    @Published var validLandingPoint: CLLocationCoordinate2D? = nil
    
    private let balloonTrackService: BalloonTrackService
    private let predictionService: PredictionService
    private let persistenceService: PersistenceService
    private let predictionCache: PredictionCache
    private var cancellables = Set<AnyCancellable>()
    
    init(balloonTrackService: BalloonTrackService, predictionService: PredictionService, persistenceService: PersistenceService, predictionCache: PredictionCache) {
        self.balloonTrackService = balloonTrackService
        self.predictionService = predictionService
        self.persistenceService = persistenceService
        self.predictionCache = predictionCache
        
        setupSubscriptions()
        updateLandingPointPriorities()
    }
    
    private func setupSubscriptions() {
        // Subscribe to prediction updates
        EventBus.shared.mapStateUpdatePublisher
            .filter { $0.predictionData != nil }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                if let predictionData = update.predictionData {
                    self?.handleNewPrediction(predictionData)
                }
            }
            .store(in: &cancellables)
    }
    
    private func handleNewPrediction(_ predictionData: PredictionData) {
        let newLandingPoint = predictionData.landingPoint
        
        // Check if landing point changed significantly (>100m)
        if let currentLanding = validLandingPoint {
            let distance = CLLocation(latitude: currentLanding.latitude, longitude: currentLanding.longitude)
                .distance(from: CLLocation(latitude: newLandingPoint.latitude, longitude: newLandingPoint.longitude))
            
            if distance > 100 {
                appLog("LandingPointService: Prediction landing point changed significantly - updating", category: .service, level: .info)
                updateLandingPointFromPrediction(newLandingPoint)
            }
        } else {
            updateLandingPointFromPrediction(newLandingPoint)
        }
    }
    
    private func updateLandingPointFromPrediction(_ landingPoint: CLLocationCoordinate2D) {
        validLandingPoint = landingPoint
        
        // Persist the landing point
        if let sondeName = balloonTrackService.currentBalloonName {
            persistenceService.saveLandingPoint(sondeName: sondeName, coordinate: landingPoint)
            appLog("LandingPointService: Persisted landing point from prediction for sonde: \(sondeName)", category: .service, level: .debug)
        }
    }
    
    func updateLandingPointPriorities() {
        appLog("LandingPointService: Updating landing point priorities", category: .service, level: .debug)
        
        // Priority 1: Landed balloon position (not implemented - requires landing detection)
        
        // Priority 2: Latest prediction from cache or API
        if let sondeName = balloonTrackService.currentBalloonName,
           let cachedPrediction = getCachedPrediction(for: sondeName) {
            validLandingPoint = cachedPrediction.landingPoint
            appLog("LandingPointService: Priority 2 - Prediction available", category: .service, level: .debug)
            return
        }
        
        // Priority 3: Clipboard URL parsing
        if let clipboardLanding = parseClipboardForLandingPoint() {
            validLandingPoint = clipboardLanding
            appLog("LandingPointService: Priority 3 - Clipboard landing point", category: .service, level: .debug)
            return
        }
        
        appLog("LandingPointService: Priority 3 failed, proceeding to Priority 4", category: .service, level: .debug)
        
        // Priority 4: Persisted landing point from previous sessions
        checkPersistedLandingPoint()
    }
    
    private func checkPersistedLandingPoint() {
        appLog("LandingPointService: Checking Priority 4 - Persisted landing point", category: .service, level: .debug)
        
        if let sondeName = balloonTrackService.currentBalloonName {
            if let persistedLandingPoint = persistenceService.loadLandingPoint(sondeName: sondeName) {
                validLandingPoint = persistedLandingPoint
                appLog("LandingPointService: Using Priority 4 - Persisted landing point for \(sondeName): \(persistedLandingPoint)", category: .service, level: .info)
                return
            }
        } else {
            appLog("LandingPointService: No current balloon name available", category: .service, level: .debug)
        }
        
        appLog("LandingPointService: No valid landing point available - all priorities failed", category: .service, level: .info)
        validLandingPoint = nil
    }
    
    private func getCachedPrediction(for sondeName: String) -> PredictionData? {
        // This would need access to the cache key generation logic from PredictionPolicy
        // For now, return nil - proper implementation would check the cache
        return nil
    }
    
    private func parseClipboardForLandingPoint() -> CLLocationCoordinate2D? {
        guard let clipboardString = UIPasteboard.general.string else {
            appLog("LandingPointService: No telemetry available, checking Priority 3 - Clipboard", category: .service, level: .debug)
            return nil
        }
        
        appLog("LandingPointService: Attempting to parse clipboard URL: '\(clipboardString)'", category: .service, level: .debug)
        
        // Try to parse as URL with coordinates
        if let url = URL(string: clipboardString),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            
            var lat: Double? = nil
            var lon: Double? = nil
            
            for item in queryItems {
                switch item.name {
                case "lat", "latitude":
                    lat = Double(item.value ?? "")
                case "lon", "lng", "longitude":
                    lon = Double(item.value ?? "")
                default:
                    break
                }
            }
            
            if let latitude = lat, let longitude = lon {
                appLog("LandingPointService: ✅ Parsed coordinates from clipboard URL", category: .service, level: .info)
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
        }
        
        appLog("LandingPointService: Invalid URL format", category: .service, level: .debug)
        appLog("LandingPointService: ❌ Clipboard content could not be parsed as coordinates", category: .service, level: .debug)
        return nil
    }
}

// MARK: - Persistence Service

@MainActor
final class PersistenceService: ObservableObject {
    private let userDefaults = UserDefaults.standard
    
    // Internal storage for cached data
    @Published var userSettings: UserSettings
    @Published var deviceSettings: DeviceSettings?
    private var internalTracks: [String: [BalloonTrackPoint]] = [:]
    private var internalLandingPoints: [String: CLLocationCoordinate2D] = [:]
    
    init() {
        appLog("PersistenceService: Initializing...", category: .service, level: .info)
        
        // Load user settings
        self.userSettings = Self.loadUserSettings()
        
        // Load device settings
        self.deviceSettings = Self.loadDeviceSettings()
        
        // Load tracks
        self.internalTracks = Self.loadAllTracks()
        
        // Load landing points
        self.internalLandingPoints = Self.loadAllLandingPoints()
        
        appLog("PersistenceService: Tracks loaded from UserDefaults. Total tracks: \(internalTracks.count)", category: .service, level: .info)
    }
    
    // MARK: - User Settings
    
    func save(userSettings: UserSettings) {
        self.userSettings = userSettings
        
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(userSettings) {
            userDefaults.set(encoded, forKey: "UserSettings")
            appLog("PersistenceService: UserSettings saved to UserDefaults.", category: .service, level: .debug)
        }
    }
    
    func readPredictionParameters() -> UserSettings? {
        return userSettings
    }
    
    private static func loadUserSettings() -> UserSettings {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "UserSettings"),
           let userSettings = try? decoder.decode(UserSettings.self, from: data) {
            appLog("PersistenceService: UserSettings loaded from UserDefaults.", category: .service, level: .debug)
            return userSettings
        } else {
            let defaultSettings = UserSettings()
            appLog("PersistenceService: UserSettings not found, using defaults.", category: .service, level: .debug)
            return defaultSettings
        }
    }
    
    // MARK: - Device Settings
    
    func save(deviceSettings: DeviceSettings) {
        self.deviceSettings = deviceSettings
        
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(deviceSettings) {
            userDefaults.set(encoded, forKey: "DeviceSettings")
            appLog("PersistenceService: deviceSettings saved: \(deviceSettings)", category: .service, level: .debug)
        }
    }
    
    private static func loadDeviceSettings() -> DeviceSettings? {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "DeviceSettings"),
           let deviceSettings = try? decoder.decode(DeviceSettings.self, from: data) {
            return deviceSettings
        }
        return nil
    }
    
    // MARK: - Track Management
    
    func saveBalloonTrack(sondeName: String, track: [BalloonTrackPoint]) {
        internalTracks[sondeName] = track
        saveAllTracks()
        appLog("PersistenceService: Saved balloon track for sonde '\(sondeName)'.", category: .service, level: .debug)
    }
    
    func loadTrackForCurrentSonde(sondeName: String) -> [BalloonTrackPoint]? {
        return internalTracks[sondeName]
    }
    
    func purgeAllTracks() {
        internalTracks.removeAll()
        userDefaults.removeObject(forKey: "BalloonTracks")
        appLog("PersistenceService: All balloon tracks purged.", category: .service, level: .debug)
    }
    
    func saveOnAppClose(balloonTrackService: BalloonTrackService) {
        if let currentName = balloonTrackService.currentBalloonName {
            let track = balloonTrackService.getAllTrackPoints()
            saveBalloonTrack(sondeName: currentName, track: track)
            appLog("PersistenceService: Saved current balloon track for sonde '\(currentName)' on app close.", category: .service, level: .info)
        }
    }
    
    private func saveAllTracks() {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(internalTracks) {
            userDefaults.set(encoded, forKey: "BalloonTracks")
        }
    }
    
    private static func loadAllTracks() -> [String: [BalloonTrackPoint]] {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "BalloonTracks"),
           let tracks = try? decoder.decode([String: [BalloonTrackPoint]].self, from: data) {
            return tracks
        }
        return [:]
    }
    
    // MARK: - Landing Points
    
    func saveLandingPoint(sondeName: String, coordinate: CLLocationCoordinate2D) {
        internalLandingPoints[sondeName] = coordinate
        saveAllLandingPoints()
    }
    
    func loadLandingPoint(sondeName: String) -> CLLocationCoordinate2D? {
        return internalLandingPoints[sondeName]
    }
    
    private func saveAllLandingPoints() {
        let landingPointsData = internalLandingPoints.mapValues { coord in
            ["latitude": coord.latitude, "longitude": coord.longitude]
        }
        userDefaults.set(landingPointsData, forKey: "LandingPoints")
    }
    
    private static func loadAllLandingPoints() -> [String: CLLocationCoordinate2D] {
        if let data = UserDefaults.standard.object(forKey: "LandingPoints") as? [String: [String: Double]] {
            return data.compactMapValues { dict in
                guard let lat = dict["latitude"], let lon = dict["longitude"] else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return [:]
    }
}

// MARK: - Supporting Types and Extensions

// Event for balloon position updates
struct BalloonPositionEvent {
    let balloonId: String
    let position: CLLocationCoordinate2D
    let telemetry: TelemetryData
}

// Extension to EventBus for balloon position events
extension EventBus {
    private static var _balloonPositionPublisher: PassthroughSubject<BalloonPositionEvent, Never>?
    
    var balloonPositionPublisher: PassthroughSubject<BalloonPositionEvent, Never> {
        if let existing = Self._balloonPositionPublisher {
            return existing
        }
        let publisher = PassthroughSubject<BalloonPositionEvent, Never>()
        Self._balloonPositionPublisher = publisher
        return publisher
    }
    
    func publishBalloonPosition(_ event: BalloonPositionEvent) {
        balloonPositionPublisher.send(event)
    }
}


// Error types
enum PredictionError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case noData
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from prediction service"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .noData:
            return "No data received"
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