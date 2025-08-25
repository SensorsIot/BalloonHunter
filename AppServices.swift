import Foundation
import CoreLocation
import Combine
import CoreBluetooth
import MapKit

// MARK: - Persistence Service

class PersistenceService {
    private let deviceSettingsKey = "deviceSettings"
    private let userSettingsKey = "userSettings"

    func saveDeviceSettings(_ settings: DeviceSettings) {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: deviceSettingsKey)
        }
    }

    func loadDeviceSettings() -> DeviceSettings? {
        if let data = UserDefaults.standard.data(forKey: deviceSettingsKey) {
            return try? JSONDecoder().decode(DeviceSettings.self, from: data)
        }
        return nil
    }

    func saveUserSettings(_ settings: UserSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.burstAltitude, forKey: "burstAltitude")
        defaults.set(settings.ascentRate, forKey: "ascentRate")
        defaults.set(settings.descentRate, forKey: "descentRate")
    }

    func loadUserSettings() -> UserSettings {
        let settings = UserSettings()
        let defaults = UserDefaults.standard
        settings.burstAltitude = defaults.double(forKey: "burstAltitude")
        settings.ascentRate = defaults.double(forKey: "ascentRate")
        settings.descentRate = defaults.double(forKey: "descentRate")
        return settings
    }

    func saveBalloonTrack(sondeName: String, track: [TelemetryTransferData]) {
        let fileManager = FileManager.default
        guard let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileURL = documentDirectory.appendingPathComponent("\(sondeName)_track.jsonl")

        do {
            let data = try track.map { try JSONEncoder().encode($0) }.map { String(data: $0, encoding: .utf8)! }.joined(separator: "\n")
            try data.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Error saving balloon track: \(error)")
        }
    }

    func loadBalloonTrack(sondeName: String) -> [TelemetryTransferData] {
        let fileManager = FileManager.default
        guard let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let fileURL = documentDirectory.appendingPathComponent("\(sondeName)_track.jsonl")

        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = data.components(separatedBy: .newlines)
            return lines.compactMap { line in
                guard let jsonData = line.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(TelemetryTransferData.self, from: jsonData)
            }
        } catch {
            print("Error loading balloon track: \(error)")
            return []
        }
    }
    
    func deleteAllBalloonTracks() {
        let fileManager = FileManager.default
        guard let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentDirectory, includingPropertiesForKeys: nil)
            for fileURL in fileURLs {
                if fileURL.pathExtension == "jsonl" {
                    try fileManager.removeItem(at: fileURL)
                }
            }
        } catch {
            print("Error deleting balloon tracks: \(error)")
        }
    }
}

// MARK: - Current Location Service

class CurrentLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    @Published var locationData: LocationData?

    override init() {
        super.init()
        self.locationManager.delegate = self
        self.locationManager.requestWhenInUseAuthorization()
        self.locationManager.startUpdatingLocation()
        self.locationManager.startUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let newLocationData = LocationData(latitude: location.coordinate.latitude,
                                           longitude: location.coordinate.longitude,
                                           heading: self.locationData?.heading ?? 0)
        self.locationData = newLocationData
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let newLocationData = LocationData(latitude: self.locationData?.latitude ?? 0,
                                           longitude: self.locationData?.longitude ?? 0,
                                           heading: newHeading.trueHeading)
        self.locationData = newLocationData
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed with error: \(error.localizedDescription)")
    }
}

// MARK: - BLE Communication Service

class BLECommunicationService: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var telemetryData = PassthroughSubject<TelemetryData, Never>()
    @Published var deviceSettings = PassthroughSubject<DeviceSettings, Never>()
    @Published var latestTelemetry: TelemetryData? = nil

    private let uartServiceUUID = CBUUID(string: "53797269-614D-6972-6B6F-44616C6D6F6E")
    private let uartRxCharacteristicUUID = CBUUID(string: "53797269-614D-6972-6B6F-44616C6D6F62")
    private let uartTxCharacteristicUUID = CBUUID(string: "53797269-614D-6972-6B6F-44616C6D6F61")

    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    
    private var receiveBuffer: String = ""
    private var hasNotifiedReady = false
    private var shouldReconnect = true
    private let persistenceService = PersistenceService()
    
    private var balloonTrack: [TelemetryTransferData] = []
    @Published var currentBalloonTrack: [TelemetryTransferData] = []
    private var lastSondeName: String? = nil
    
    @Published public var balloonDescends: Bool = false
    
    weak var predictionService: PredictionService?

    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            hasNotifiedReady = false
            shouldReconnect = true
            startScan()
        }
    }

    func startScan() {
        print("[Debug][BLEService] Scanning for MySondyGo peripherals...")
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.peripheral == nil {
                self?.centralManager.stopScan()
                print("[Debug][BLEService] No MySondyGo peripheral found after 10 seconds.")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Removed debug line printing all discovered peripherals and advertisement data
        if let peripheralName = peripheral.name, peripheralName.contains("MySondyGo") {
            if self.peripheral == nil {
                print("[Debug][BLEService] Discovered peripheral: \(peripheralName)")
                self.peripheral = peripheral
                centralManager.stopScan()
                centralManager.connect(peripheral, options: nil)
                connectionStatus = .connecting
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[Debug][BLEService] Failed to connect to peripheral: \(peripheral.name ?? "N/A") Error: \(String(describing: error))")
        if self.peripheral == peripheral {
            self.peripheral = nil
        }
        connectionStatus = .disconnected
        if shouldReconnect {
            startScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[Debug][BLEService] Connected to peripheral: \(peripheral.name ?? "N/A")")
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        self.peripheral?.discoverServices([uartServiceUUID])
        // Request settings immediately after connection
        sendCommand(command: "?")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[Debug][BLEService] Disconnected from peripheral: \(peripheral.name ?? "N/A")")
        if self.peripheral == peripheral {
            self.peripheral = nil
        }
        connectionStatus = .disconnected
        if shouldReconnect {
            startScan()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[Debug][BLEService] Failed to discover services: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == uartServiceUUID {
                peripheral.discoverCharacteristics([uartRxCharacteristicUUID, uartTxCharacteristicUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("[Debug][BLEService] Failed to discover characteristics: \(error.localizedDescription)")
            return
        }
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == uartRxCharacteristicUUID {
                rxCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == uartTxCharacteristicUUID {
                txCharacteristic = characteristic
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else { return }
        
        if let data = characteristic.value {
            if String(data: data, encoding: .utf8) != nil {
                // print("[Debug][BLEService] Raw received string: \(string)") // Removed per instructions
            } else {
                print("[Debug][BLEService] Raw received data (not UTF8 decodable): \(data.base64EncodedString())")
            }
        }
        
        guard let data = characteristic.value, let newChunk = String(data: data, encoding: .utf8) else { return }
        receiveBuffer.append(newChunk)
        // Extract all full packets from buffer
        while let range = receiveBuffer.range(of: "o.*?o", options: .regularExpression) {
            let packet = String(receiveBuffer[range])
            receiveBuffer.removeSubrange(range)
            parsePacket(packet)
        }
    }
    
    private func parsePacket(_ packet: String) {
        // print("[Debug][BLEService] Parsing packet: \(packet)") // Removed per instructions
        let messageContent = packet.dropFirst().dropLast() // remove o and o
        let messageContentStr = String(messageContent)
        let components = messageContentStr.components(separatedBy: "/")
        guard !components.isEmpty else { return }
        switch components[0] {
        case "0", "2":
            var telemetry = TelemetryData()
            telemetry.parse(message: String(messageContent))
            telemetry.lastUpdateTime = Date().timeIntervalSince1970

            // Publish telemetry after parsing so all subscribers and UI update immediately.
            self.latestTelemetry = telemetry
            telemetryData.send(telemetry)

            
            if !hasNotifiedReady {
                hasNotifiedReady = true
                connectionStatus = .connected
                // Load user settings and trigger prediction after first telemetry
                let userSettings = persistenceService.loadUserSettings()
                predictionService?.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
            }
        case "1":
            var telemetry = TelemetryData()
            telemetry.parse(message: String(messageContent))
            telemetry.lastUpdateTime = Date().timeIntervalSince1970

            // Publish telemetry after parsing so all subscribers and UI update immediately.
            self.latestTelemetry = telemetry
            telemetryData.send(telemetry)

            
            if !hasNotifiedReady {
                hasNotifiedReady = true
                connectionStatus = .connected
                // Load user settings and trigger prediction after first telemetry
                let userSettings = persistenceService.loadUserSettings()
                predictionService?.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
            }
            // Balloon track logic:
            let currentSondeName = telemetry.sondeName
            if lastSondeName != currentSondeName {
                lastSondeName = currentSondeName
                balloonTrack = []
                persistenceService.deleteAllBalloonTracks()
            }
            // Only append valid coordinates
            if telemetry.latitude != 0 && telemetry.longitude != 0 {
                let point = TelemetryTransferData(latitude: telemetry.latitude, longitude: telemetry.longitude, altitude: telemetry.altitude)
                balloonTrack.append(point)
                persistenceService.saveBalloonTrack(sondeName: currentSondeName, track: balloonTrack)
                self.currentBalloonTrack = balloonTrack
            }
            
            // FSD compliance: trigger prediction automatically
            if telemetry.verticalSpeed < 0 {
                balloonDescends = true
            }
            let userSettings = persistenceService.loadUserSettings()
            let burstAltitudeForPrediction = balloonDescends ? (telemetry.altitude + 10.0) : userSettings.burstAltitude
            predictionService?.fetchPrediction(telemetry: telemetry, userSettings: {
                let settings = UserSettings()
                settings.ascentRate = userSettings.ascentRate
                settings.descentRate = userSettings.descentRate
                settings.burstAltitude = burstAltitudeForPrediction
                return settings
            }())
            
        case "3":
            var settings = DeviceSettings()
            settings.parse(message: String(messageContent))
            deviceSettings.send(settings)
            persistenceService.saveDeviceSettings(settings)
            print("[Debug][BLEService] Parsed device settings: \(settings)")
        default:
            print("[Debug][BLEService] Unknown packet type: \(components[0])")
            break
        }
    }

    func sendCommand(command: String) {
        guard let peripheral = peripheral, let txCharacteristic = txCharacteristic else { return }
        let commandString = "o{\(command)}o"
        if let data = commandString.data(using: .utf8) {
            peripheral.writeValue(data, for: txCharacteristic, type: .withResponse)
        }
    }
}

// MARK: - Prediction Service

class PredictionService: NSObject, ObservableObject, XMLParserDelegate {
    @Published var predictionData: PredictionData?

    private var path: [CLLocationCoordinate2D] = []
    private var burstPoint: CLLocationCoordinate2D? = nil
    private var landingPoint: CLLocationCoordinate2D? = nil
    private var landingTime: Date? = nil
    private var currentElementName: String = ""
    private var currentPlacemarkName: String = ""
    private var currentPlacemarkDescription: String = ""
    private var elementStack: [String] = []
    
    // New property for throttling
    private var lastPredictionFetchTime: Date?

    @Published var predictionStatus: PredictionStatus = .noValidPrediction // New property
    private var parsingError: Error? // New property to hold parsing errors

    func fetchPrediction(telemetry: TelemetryData, userSettings: UserSettings) {
        // Throttling logic
        if let lastFetchTime = lastPredictionFetchTime {
            let timeSinceLastFetch = Date().timeIntervalSince(lastFetchTime)
            if timeSinceLastFetch < 30 {
                print("[Debug][PredictionService] Prediction fetch throttled. Last fetch was \(String(format: "%.1f", timeSinceLastFetch)) seconds ago.")
                return
            }
        }
        
        // Update last fetch time
        lastPredictionFetchTime = Date()
        // Set status to fetching
        predictionStatus = .fetching

        print("[Debug][PredictionService] Fetching prediction...")
        path = [] // Reset path for new prediction
        burstPoint = nil // Reset burst point
        landingPoint = nil // Reset landing point
        landingTime = nil // Reset landing time
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let launchDatetime = dateFormatter.string(from: Date())
        let urlString = "http://predict.cusf.co.uk/api/v1/?launch_latitude=\(telemetry.latitude)&launch_longitude=\(telemetry.longitude)&launch_datetime=\(launchDatetime)&ascent_rate=\(userSettings.ascentRate)&burst_altitude=\(userSettings.burstAltitude)&descent_rate=\(userSettings.descentRate)&launch_altitude=\(telemetry.altitude)"
        print("[Debug][PredictionService] API Call: \(urlString)")

        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("[Debug][PredictionService] Network error: " + error.localizedDescription)
                DispatchQueue.main.async {
                    self.predictionStatus = .error(error.localizedDescription)
                }
                return
            }

            guard let data = data else {
                print("[Debug][PredictionService] No data received.")
                DispatchQueue.main.async {
                    self.predictionStatus = .error("No data received from API.")
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let errorString = String(data: data, encoding: .utf8) ?? "Unknown server error"
                print("[Debug][PredictionService] HTTP Error \(httpResponse.statusCode): \(errorString)")
                DispatchQueue.main.async {
                    self.predictionStatus = .error("HTTP Error \(httpResponse.statusCode): \(errorString.prefix(100))...")
                }
                return
            }

            if let kmlString = String(data: data, encoding: .utf8) {
                print("[Debug][PredictionService] Full KML/Response String: \n\(kmlString)")
            }

            Task { @MainActor in
                self.parsingError = nil // Reset parsing error
                let parser = XMLParser(data: data)
                parser.delegate = self
                if !parser.parse() {
                    // If parse() returns false, it means a fatal error occurred during parsing
                    let errorDescription = self.parsingError?.localizedDescription ?? "Unknown XML parsing error"
                    print("[Debug][PredictionService] XML parsing failed: \(errorDescription)")
                    DispatchQueue.main.async {
                        self.predictionStatus = .error("XML parsing failed: \(errorDescription)")
                    }
                }
            }
        }.resume()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElementName = elementName
        elementStack.append(elementName)
        if elementName == "Placemark" {
            currentPlacemarkName = ""
            currentPlacemarkDescription = ""
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementStack.last == elementName {
            elementStack.removeLast()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let data = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !data.isEmpty {
            if currentElementName == "name" {
                currentPlacemarkName = data
            } else if currentElementName == "description" {
                currentPlacemarkDescription = data
            } else if currentElementName == "coordinates" {
                let parentElement = elementStack.dropLast().last // Get the parent element
                let coordinates = data.components(separatedBy: ",")
                if coordinates.count == 3 {
                    if let lon = Double(coordinates[0]), let lat = Double(coordinates[1]) {
                        if parentElement == "Point" {
                            if currentPlacemarkName == "Balloon Burst" {
                                burstPoint = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                                print("[Debug][PredictionService] Parsed Burst Point: lat=\(lat), lon=\(lon)")
                            } else if currentPlacemarkName == "Balloon Landing" {
                                landingPoint = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                                print("[Debug][PredictionService] Parsed Landing Point: lat=\(lat), lon=\(lon)")
                            }
                        } else if parentElement == "LineString" {
                            path.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                        }
                    }
                }
            }
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parsingError = parseError
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        DispatchQueue.main.async {
            if let landingPoint = self.landingPoint {
                print("[Debug][PredictionService] Prediction parsing finished. Valid prediction received.")
                let newPredictionData = PredictionData(path: self.path, burstPoint: self.burstPoint, landingPoint: landingPoint, landingTime: self.landingTime)
                self.predictionData = newPredictionData
                self.predictionStatus = .success
            } else {
                print("[Debug][PredictionService] Prediction parsing finished, but no valid landing point found.")
                // If there was a parsing error, predictionStatus is already set to .error
                // Otherwise, it means the KML was valid but didn't contain a landing point
                if case .fetching = self.predictionStatus { // Only update if not already an error
                    self.predictionStatus = .noValidPrediction
                }
            }
        }
    }
}

// MARK: - Route Calculation Service

class RouteCalculationService: ObservableObject {
    @Published var routeData: RouteData?

    func calculateRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, transportType: TransportationMode) {
        print("[Debug][RouteCalculationService] Calculating route...")
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = (transportType == .car) ? .automobile : .walking

        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            guard let route = response?.routes.first, error == nil else { return }
            let path = route.polyline.coordinates
            let routeData = RouteData(path: path, distance: route.distance, expectedTravelTime: route.expectedTravelTime)
            DispatchQueue.main.async {
                self.routeData = routeData
            }
        }
    }
}

// MARK: - Annotation Service

class AnnotationService: ObservableObject {
    @Published var annotations: [MapAnnotationItem] = []
    @Published var isFinalApproach = PassthroughSubject<Bool, Never>()
    private var recentTelemetry: [CLLocationCoordinate2D] = []
    private var lowVerticalSpeedCount: Int = 0

    func updateAnnotations(telemetry: TelemetryData?, userLocation: LocationData?, prediction: PredictionData?) {
        var newAnnotations: [MapAnnotationItem] = []

        if let userLocation = userLocation {
            newAnnotations.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude), kind: .user))
        }

        if let telemetry = telemetry {
            let coordinate = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
            let status: MapAnnotationItem.AnnotationStatus = (Date().timeIntervalSince1970 - (telemetry.lastUpdateTime ?? 0)) < 3 ? .fresh : .stale
            newAnnotations.append(MapAnnotationItem(coordinate: coordinate, kind: .balloon, status: status))
            
            if telemetry.verticalSpeed < 1.0 {
                lowVerticalSpeedCount += 1
                print("[Debug][AnnotationService] Low vertical speed count: \(lowVerticalSpeedCount)")
                if lowVerticalSpeedCount >= 10 {
                    recentTelemetry.append(coordinate)
                    if recentTelemetry.count > 100 {
                        recentTelemetry.removeFirst()
                    }
                }
            } else {
                lowVerticalSpeedCount = 0
                recentTelemetry = [] // Reset if vertical speed is high again
            }
        }

        if let prediction = prediction {
            if let burstPoint = prediction.burstPoint {
                newAnnotations.append(MapAnnotationItem(coordinate: burstPoint, kind: .burst))
                print("[Debug][AnnotationService] Adding Burst Annotation: \(burstPoint)")
            }
            if let landingPoint = prediction.landingPoint {
                newAnnotations.append(MapAnnotationItem(coordinate: landingPoint, kind: .landing))
                print("[Debug][AnnotationService] Adding Landing Annotation: \(landingPoint)")
            }
        }
        
        if !recentTelemetry.isEmpty {
            newAnnotations.append(MapAnnotationItem(coordinate: calculateAverageCoordinate(), kind: .landed))
            
            if let userLocation = userLocation {
                let userCoordinate = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
                let landedCoordinate = calculateAverageCoordinate()
                let distance = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude).distance(from: CLLocation(latitude: landedCoordinate.latitude, longitude: landedCoordinate.longitude))
                
                if distance < 1000 {
                    isFinalApproach.send(true)
                }
            }
        }

        self.annotations = newAnnotations
    }
    
    private func calculateAverageCoordinate() -> CLLocationCoordinate2D {
        var avgLat: Double = 0
        var avgLon: Double = 0
        
        for coord in recentTelemetry {
            avgLat += coord.latitude
            avgLon += coord.longitude
        }
        
        avgLat /= Double(recentTelemetry.count)
        avgLon /= Double(recentTelemetry.count)
        
        return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
    }
}

private enum AssociatedKeys {
    static var lastUpdateTime = "lastUpdateTime"
}
