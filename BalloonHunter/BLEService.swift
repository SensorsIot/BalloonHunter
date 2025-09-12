// BLEService.swift
// Bluetooth Low Energy communication service for MySondyGo devices
// Extracted from Services.swift for better code organization

import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import OSLog

// MARK: - BLE Data Models

struct DeviceSettings: Codable {
    var frequency: Double = 434.0
    var bandwidth: Double = 125.0
    var spreadingFactor: Int = 7
    var codingRate: Int = 5
    var power: Int = 10
    var syncWord: Int = 0x12
    var preambleLength: Int = 8
    var crcEnabled: Bool = true
    var implicitHeader: Bool = false
    
    // Additional fields from Type 3 packets
    var probeType: String = ""
    var oledSDA: Int = 21
    var oledSCL: Int = 22
    var oledRST: Int = 16
    var ledPin: Int = 25
    var RS41Bandwidth: Int = 1
    var M20Bandwidth: Int = 7
    var M10Bandwidth: Int = 7
    var PILOTBandwidth: Int = 7
    var DFMBandwidth: Int = 6
    var frequencyCorrection: Int = 0
    var batPin: Int = 35
    var batMin: Int = 2950
    var batMax: Int = 4180
    var batType: Int = 1
    var lcdType: Int = 0
    var nameType: Int = 0
    var buzPin: Int = 0
    var softwareVersion: String = ""
    
    // SettingsView expected properties
    var bluetoothStatus: Int = 1
    var lcdStatus: Int = 1
    var serialSpeed: Int = 115200
    var serialPort: Int = 0
    var aprsName: Int = 0
    var callSign: String = ""
    
    static let `default` = DeviceSettings()
    
    mutating func parse(message: String) {
        let components = message.components(separatedBy: "/")
        guard components.count >= 22 else { return }
        
        // Type 3: Device Configuration (22 fields)
        if components[0] == "3" {
            // Handle probe type - could be integer (1-5) or string ("RS41", "M20", etc.)
            let probeTypeComponent = components[1]
            appLog("DeviceSettings: Parsing probeType from '\(probeTypeComponent)'", category: .ble, level: .debug)
            
            if let probeTypeInt = Int(probeTypeComponent) {
                // Device sent integer - convert to string
                probeType = convertProbeTypeIntToString(probeTypeInt)
                appLog("DeviceSettings: Converted integer \(probeTypeInt) to: '\(probeType)'", category: .ble, level: .debug)
            } else {
                // Device sent string directly - validate and use it
                let upperCaseType = probeTypeComponent.uppercased()
                if ["RS41", "M20", "M10", "PILOT", "DFM"].contains(upperCaseType) {
                    probeType = upperCaseType
                    appLog("DeviceSettings: Using string probeType: '\(probeType)'", category: .ble, level: .debug)
                } else {
                    probeType = ""
                    appLog("DeviceSettings: Invalid probeType string '\(probeTypeComponent)' - setting to empty", category: .ble, level: .debug)
                }
            }
            frequency = Double(components[2]) ?? 434.0
            oledSDA = Int(components[3]) ?? 21
            oledSCL = Int(components[4]) ?? 22
            oledRST = Int(components[5]) ?? 16
            ledPin = Int(components[6]) ?? 25
            RS41Bandwidth = Int(components[7]) ?? 1
            // Convert bandwidth integer to actual kHz frequency
            if let bw = BLECommunicationService.Bandwidth.from(int: RS41Bandwidth) {
                bandwidth = bw.frequency
            } else {
                bandwidth = 125.0 // Default fallback
            }
            M20Bandwidth = Int(components[8]) ?? 7
            M10Bandwidth = Int(components[9]) ?? 7
            PILOTBandwidth = Int(components[10]) ?? 7
            DFMBandwidth = Int(components[11]) ?? 6
            callSign = components[12]
            frequencyCorrection = Int(components[13]) ?? 0
            batPin = Int(components[14]) ?? 35
            batMin = Int(components[15]) ?? 2950
            batMax = Int(components[16]) ?? 4180
            batType = Int(components[17]) ?? 1
            lcdType = Int(components[18]) ?? 0
            nameType = Int(components[19]) ?? 0
            buzPin = Int(components[20]) ?? 0
            softwareVersion = components[21]
        }
    }
    
    // Helper function to convert probe type integer to string
    private func convertProbeTypeIntToString(_ probeTypeInt: Int) -> String {
        return BLECommunicationService.ProbeType.from(int: probeTypeInt)?.name ?? ""
    }
    
    // MARK: - Frequency Calculations (moved from SettingsView for proper separation of concerns)
    
    /// Converts frequency to array of digits (moved from SettingsView)
    func frequencyToDigits() -> [Int] {
        let freqInt = Int((frequency * 100).rounded())
        var digits = Array(repeating: 0, count: 5)
        var remainder = freqInt
        for i in (0..<5).reversed() {
            digits[i] = remainder % 10
            remainder /= 10
        }
        return digits
    }
    
    /// Updates frequency from array of digits (moved from SettingsView)
    mutating func updateFrequencyFromDigits(_ digits: [Int]) {
        var total = 0
        for digit in digits {
            total = total * 10 + digit
        }
        frequency = Double(total) / 100.0
    }
}

struct DeviceStatusData {
    let batteryVoltage: Double
    let temperature: Double
    let signalStrength: Int
    let timestamp: Date
}

struct NameOnlyData {
    let name: String
    let timestamp: Date
}

enum ServiceHealth {
    case healthy
    case degraded(String)
    case unhealthy(String)
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case scanning
    case failed(String)
}

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
    private var hasProcessedFirstPacket = false

    // Buffer to accumulate incoming BLE data fragments until a full message is received
    private var incomingBLEBuffer: Data = Data()
    private var lastBLEMessageTime: Date = Date.distantPast

    @Published var telemetryAvailabilityState: Bool = false
    @Published var latestTelemetry: TelemetryData? = nil
    @Published var deviceSettings: DeviceSettings = .default
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var lastMessageType: String? = nil
    @Published var telemetryData = PassthroughSubject<TelemetryData, Never>()
    @Published var lastTelemetryUpdateTime: Date? = nil
    @Published var isReadyForCommands = false
    let centralManagerPoweredOn = PassthroughSubject<Void, Never>()

    init(persistenceService: PersistenceService) {
        self.persistenceService = persistenceService
        super.init()
        
        // BLE service initialized with UART UUIDs
        
        appLog("BLE: Initializing CBCentralManager", category: .ble, level: .info)
        centralManager = CBCentralManager(delegate: self, queue: nil)

        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.updateTelemetryAvailabilityState()
            }
        }
        
        // Periodic diagnostic timer to help debug BLE issues
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.printBLEDiagnostics()
            }
        }
        
        appLog("BLE: BLECommunicationService initialization complete", category: .ble, level: .info)
        publishHealthEvent(.healthy, message: "BLE service initialized")
    }

    private func updateTelemetryAvailabilityState() async {
        let _ = telemetryAvailabilityState  // wasAvailable
        let isAvailable: Bool
        let reason: String
        
        if let lastUpdate = lastTelemetryUpdateTime {
            let interval = Date().timeIntervalSince(lastUpdate)
            isAvailable = interval <= 3.0
            reason = isAvailable ? "Valid telemetry received within last 3 seconds" : "No valid telemetry for more than 3 seconds"
        } else {
            isAvailable = false
            reason = "No telemetry ever received"
        }
        
        // Update state and publish event if changed
        if telemetryAvailabilityState != isAvailable {
            telemetryAvailabilityState = isAvailable
            
            // Publish telemetry availability event
            appLog("BLECommunicationService: Telemetry availability - \(isAvailable) (\(reason))", category: .service, level: .info)
            
            if isAvailable {
                appLog("BLECommunicationService: Telemetry GAINED: \(reason)", category: .ble, level: .info)
            } else {
                appLog("BLECommunicationService: Telemetry LOST: \(reason)", category: .ble, level: .info)
            }
        }
    }

    private func checkTelemetryAvailability(_ newTelemetry: TelemetryData?) {
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            centralManagerPoweredOn.send(())
            publishHealthEvent(.healthy, message: "Bluetooth powered on")
        case .poweredOff:
            appLog("BLE: Bluetooth is powered off - please enable Bluetooth in Settings", category: .ble, level: .error)
            connectionStatus = .disconnected
            publishHealthEvent(.unhealthy("Bluetooth powered off"), message: "Bluetooth powered off")
        case .resetting:
            appLog("BLE: Bluetooth is resetting - waiting for completion", category: .ble, level: .info)
            publishHealthEvent(.degraded("Bluetooth resetting"), message: "Bluetooth resetting")
            break
        case .unauthorized:
            appLog("BLE: Bluetooth access unauthorized - check app permissions", category: .ble, level: .error)
            publishHealthEvent(.unhealthy("Bluetooth unauthorized"), message: "Bluetooth unauthorized")
            break
        case .unknown:
            appLog("BLE: Bluetooth state unknown - initializing", category: .ble, level: .info)
            publishHealthEvent(.degraded("Bluetooth state unknown"), message: "Bluetooth state unknown")
            break
        case .unsupported:
            appLog("BLE: Bluetooth not supported on this device", category: .ble, level: .error)
            publishHealthEvent(.unhealthy("Bluetooth unsupported"), message: "Bluetooth unsupported")
            break
        @unknown default:
            appLog("BLE: Unknown Bluetooth state: \(central.state.rawValue)", category: .ble, level: .error)
            publishHealthEvent(.degraded("Unknown Bluetooth state"), message: "Unknown Bluetooth state")
            break
        }
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            appLog("BLE: Cannot start scanning - Bluetooth not powered on", category: .ble, level: .error)
            return
        }
        
        appLog("BLE: Starting scan for MySondyGo devices", category: .ble, level: .info)
        
        centralManager.scanForPeripherals(withServices: [UART_SERVICE_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        publishHealthEvent(.healthy, message: "BLE scanning started")
        
        // Secondary scan removed - production mode
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let peripheralName = peripheral.name ?? "Unknown"
        let _ = peripheral.identifier.uuidString
        
        // Basic device discovery logging
        
        // MySondyGo device detection with enhanced matching
        let isMySondyDevice = peripheral.name?.contains("MySondy") == true
        
        if isMySondyDevice {
            appLog("🎯 BLE: Found MySondyGo device: \(peripheralName)", category: .ble, level: .info)
            
            // Stop scanning and connect
            central.stopScan()
            connectedPeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            publishHealthEvent(.healthy, message: "MySondyGo device found")
            
        } else {
            appLog("🔍 BLE: Not a MySondy device (name='\(peripheralName)'), continuing scan", category: .ble, level: .debug)
            
            // Show service UUIDs if present for debugging
            if let services = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] {
                let serviceList = services.map { $0.uuidString }.joined(separator: ", ")
                appLog("🔍 BLE: Device services: [\(serviceList)]", category: .ble, level: .debug)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let deviceName = peripheral.name ?? "Unknown"
        appLog("🟢 BLE: SUCCESSFULLY CONNECTED to \(deviceName)", category: .ble, level: .info)
        // Connection established
        
        connectionStatus = .connected
        
        // Starting service discovery
        peripheral.discoverServices([UART_SERVICE_UUID])
        publishHealthEvent(.healthy, message: "BLE connected successfully")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let deviceName = peripheral.name ?? "Unknown"
        let errorMessage = error?.localizedDescription ?? "Unknown error"
        appLog("🔴 BLE: FAILED TO CONNECT to \(deviceName)", category: .ble, level: .error)
        appLog("🔴 BLE: Connection error: \(errorMessage)", category: .ble, level: .error)
        
        connectionStatus = .disconnected
        publishHealthEvent(.unhealthy("BLE connection failed: \(errorMessage)"), message: "BLE connection failed: \(errorMessage)")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let deviceName = peripheral.name ?? "Unknown"
        let errorMessage = error?.localizedDescription ?? "Disconnected normally"
        
        if error != nil {
            appLog("🔴 BLE: UNEXPECTED DISCONNECTION from \(deviceName)", category: .ble, level: .error)
            appLog("🔴 BLE: Disconnection error: \(errorMessage)", category: .ble, level: .error)
        } else {
            appLog("🟡 BLE: Clean disconnection from \(deviceName)", category: .ble, level: .info)
        }
        
        // Disconnected
        
        connectionStatus = .disconnected
        isReadyForCommands = false
        publishHealthEvent(.degraded("BLE disconnected"), message: "BLE disconnected")
        
        // Auto-reconnect if disconnected unexpectedly
        if error != nil {
            // Auto-reconnect scheduled
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.startScanning()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Service discovery started
        
        if let error = error {
            appLog("BLE: Error discovering services: \(error.localizedDescription)", category: .ble, level: .error)
            publishHealthEvent(.unhealthy("Service discovery failed"), message: "Service discovery failed")
            return
        }

        // Found \(peripheral.services?.count ?? 0) services
        
        for service in peripheral.services ?? [] {
            // Service: \(service.uuid)
            if service.uuid == UART_SERVICE_UUID {
                appLog("🟢 BLE: Found UART service, discovering characteristics", category: .ble, level: .info)
                peripheral.discoverCharacteristics([UART_TX_CHARACTERISTIC_UUID, UART_RX_CHARACTERISTIC_UUID], for: service)
            } else {
                // Non-UART service
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        appLog("🔍 BLE: didDiscoverCharacteristics called for service \(service.uuid)", category: .ble, level: .info)
        
        if let error = error {
            appLog("BLE: Error discovering characteristics: \(error.localizedDescription)", category: .ble, level: .error)
            publishHealthEvent(.unhealthy("Characteristic discovery failed"), message: "Characteristic discovery failed")
            return
        }

        let characteristics = service.characteristics ?? []
        // Found \(characteristics.count) characteristics

        for characteristic in characteristics {
            // Checking characteristic: \(characteristic.uuid)
            
            switch characteristic.uuid {
            case UART_TX_CHARACTERISTIC_UUID:
                // TX characteristic found
                if characteristic.properties.contains(.write) {
                    writeCharacteristic = characteristic
                    // TX supports write
                } else if characteristic.properties.contains(.writeWithoutResponse) {
                    writeCharacteristic = characteristic
                    // TX supports writeWithoutResponse
                } else {
                    appLog("🔴 BLE: TX characteristic does not support writing (properties: \(characteristic.properties.rawValue))", category: .ble, level: .error)
                }

            case UART_RX_CHARACTERISTIC_UUID:
                // RX characteristic found
                if characteristic.properties.contains(.notify) {
                    // Setting up notifications
                    peripheral.setNotifyValue(true, for: characteristic)
                    // Notifications enabled
                } else {
                    appLog("🔴 BLE: RX characteristic does not support notifications (properties: \(characteristic.properties.rawValue))", category: .ble, level: .error)
                }

            default:
                // Unknown characteristic
                break
            }
        }

        // Check if we have both characteristics configured
        if writeCharacteristic != nil {
            isReadyForCommands = true
            appLog("🟢 BLE: Ready for commands - TX characteristic configured", category: .ble, level: .info)
            publishHealthEvent(.healthy, message: "BLE ready for commands")
            
            // Don't automatically request settings - wait for first telemetry packet
            // Settings will be requested only when user opens settings panel
        } else {
            appLog("🔴 BLE: Not ready for commands - TX characteristic not found", category: .ble, level: .error)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        // Notification state updated
        
        if let error = error {
            appLog("🔴 BLE: Error updating notification state: \(error.localizedDescription)", category: .ble, level: .error)
            publishHealthEvent(.degraded("Notification setup failed"), message: "Notification setup failed")
            return
        }
        
        if characteristic.uuid == UART_RX_CHARACTERISTIC_UUID {
            if characteristic.isNotifying {
                // Notifications enabled successfully
            } else {
                appLog("🔴 BLE: Failed to enable notifications for RX characteristic", category: .ble, level: .error)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Data received
        
        if let error = error {
            appLog("BLE: Error updating value: \(error.localizedDescription)", category: .ble, level: .error)
            publishHealthEvent(.degraded("BLE update error"), message: "BLE update error")
            return
        }

        guard let data = characteristic.value else {
            appLog("🔴 BLE: No data in characteristic.value", category: .ble, level: .error)
            return
        }
        
        // Received \(data.count) bytes

        if let string = String(data: data, encoding: .utf8) {
            // Raw message will be replaced by parsed output in parseMessage()
            parseMessage(string)
        } else {
            appLog("🔴 BLE: Failed to convert data to UTF-8 string", category: .ble, level: .error)
        }
    }

    private func parseMessage(_ message: String) {
        // Processing message
        
        if !isReadyForCommands {
            isReadyForCommands = true
        }
        
        let components = message.components(separatedBy: "/")
        // Split into \(components.count) components
        
        guard components.count > 1 else {
            appLog("🔴 BLE PARSE: Not enough components (\(components.count)), skipping", category: .ble, level: .error)
            return
        }
        
        let messageType = components[0]
        // Message type: '\(messageType)'
        
        // Store the last message type for startup sequence logic
        DispatchQueue.main.async {
            self.lastMessageType = messageType
        }
        
        // Check if this is the first packet and publish telemetry availability event
        if !hasProcessedFirstPacket {
            hasProcessedFirstPacket = true
            let isTelemetryAvailable = messageType == "1"
            let reason = isTelemetryAvailable ? "Type 1 telemetry packet received" : "Non-telemetry packet received (Type \(messageType))"
            
            appLog("BLECommunicationService: Telemetry availability - \(isTelemetryAvailable) (\(reason))", category: .service, level: .info)
            
            // First packet processed
            
            // Per FSD: After receiving and decoding the first BLE package, issue settings command
            if !hasSentReadSettingsCommand {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.getParameters()
                    self?.hasSentReadSettingsCommand = true
                }
            }
        }
        
        switch messageType {
        case "0":
            // Device Basic Info and Status
            if let status = parseType0Message(components) {
                appLog("📊 BLE PARSED (Type 0): Device status - signal=\(status.signalStrength)dBm", category: .ble, level: .info)
            }
            
        case "1":
            // Probe Telemetry
            if let telemetry = parseType1Message(components) {
                if telemetry.latitude == 0.0 && telemetry.longitude == 0.0 {
                    return // Skip invalid coordinates
                }
                
                
                DispatchQueue.main.async {
                    self.latestTelemetry = telemetry
                    self.lastTelemetryUpdateTime = Date()
                    self.telemetryData.send(telemetry)
                    
                    // Log parsed telemetry on one line
                    appLog("📡 BLE PARSED: \(telemetry.sondeName) (\(telemetry.probeType)) lat=\(String(format: "%.4f", telemetry.latitude)) lon=\(String(format: "%.4f", telemetry.longitude)) alt=\(Int(telemetry.altitude))m vspd=\(String(format: "%.1f", telemetry.verticalSpeed))m/s rssi=\(telemetry.signalStrength)dBm", category: .ble, level: .info)
                    
                    // Telemetry is now available through @Published latestTelemetry property
                    // Services observe this directly instead of using EventBus
                    
                    // Device settings request is handled by the connection ready callback
                    // No need to request again here
                }
            }
            
        case "2":
            // Name Only
            if let nameData = parseType2Message(components) {
                appLog("🏷️ BLE PARSED (Type 2): Sonde name - \(nameData.name)", category: .ble, level: .info)
            }
            
        case "3":
            // Device Configuration
            if let settings = parseType3Message(components) {
                appLog("⚙️ BLE PARSED (Type 3): Device config - callSign=\(settings.callSign) freq=\(String(format: "%.1f", settings.frequency))MHz probeType=\(settings.probeType)", category: .ble, level: .info)
                DispatchQueue.main.async {
                    self.deviceSettings = settings
                    self.persistenceService.save(deviceSettings: settings)
                    
                    // Update current telemetry data with device configuration
                    if var currentTelemetry = self.latestTelemetry {
                        currentTelemetry.frequency = settings.frequency
                        currentTelemetry.probeType = settings.probeType
                        self.latestTelemetry = currentTelemetry
                        appLog("BLE: Updated telemetry with device config - freq=\(settings.frequency) probeType=\(settings.probeType)", category: .ble, level: .debug)
                    }
                }
            }
            
        default:
            appLog("BLE PARSED: Unknown packet type: \(messageType)", category: .ble, level: .debug)
        }
    }

    // Type 0: Device Basic Info and Status
    private func parseType0Message(_ components: [String]) -> DeviceStatusData? {
        guard components.count >= 8 else { return nil }
        
        return DeviceStatusData(
            batteryVoltage: Double(components[5]) ?? 0.0,
            temperature: 0.0, // Not provided in this message type
            signalStrength: Int(Double(components[3]) ?? 0.0),
            timestamp: Date()
        )
    }
    
    // Type 1: Probe Telemetry
    private func parseType1Message(_ components: [String]) -> TelemetryData? {
        guard components.count >= 20 else { return nil }
        
        let sondeName = components[3]
        let latitude = Double(components[4]) ?? 0.0
        let longitude = Double(components[5]) ?? 0.0
        let altitude = Double(components[6]) ?? 0.0
        let horizontalSpeed = Double(components[7]) ?? 0.0
        let verticalSpeed = Double(components[8]) ?? 0.0
        let rssi = Double(components[9]) ?? 0.0
        let buzmute = components[15] == "1"
        
        return TelemetryData(
            sondeName: sondeName,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            verticalSpeed: verticalSpeed,
            horizontalSpeed: horizontalSpeed,
            heading: 0.0, // Not provided in this message
            temperature: 0.0, // Not provided in this message  
            humidity: 0.0, // Not provided in this message
            pressure: 0.0, // Not provided in this message
            batteryVoltage: 0.0, // Not provided in this message type
            signalStrength: Int(rssi),
            timestamp: Date(),
            buzmute: buzmute
        )
    }
    
    // Type 2: Name Only
    private func parseType2Message(_ components: [String]) -> NameOnlyData? {
        guard components.count >= 10 else { return nil }
        
        return NameOnlyData(
            name: components[3], // sondeName
            timestamp: Date()
        )
    }

    // Type 3: Device Configuration
    private func parseType3Message(_ components: [String]) -> DeviceSettings? {
        guard components.count >= 22 else { 
            appLog("BLE: Type 3 message has insufficient components: \(components.count), expected 22", category: .ble, level: .error)
            return nil 
        }
        
        appLog("BLE: Parsing Type 3 message with \(components.count) components", category: .ble, level: .debug)
        appLog("BLE: Type 3 components[1] (probeType): '\(components[1])'", category: .ble, level: .debug)
        
        // Reconstruct the message string and use DeviceSettings.parse()
        let messageString = components.joined(separator: "/")
        var deviceSettings = DeviceSettings.default
        deviceSettings.parse(message: messageString)
        
        appLog("BLE: Parsed deviceSettings.probeType: '\(deviceSettings.probeType)'", category: .ble, level: .debug)
        
        return deviceSettings
    }

    // MARK: - MySondyGo Command Interface
    
    /// MySondyGo probe type constants
    enum ProbeType: Int, CaseIterable, Codable {
        case rs41 = 1
        case m20 = 2
        case m10 = 3
        case pilot = 4
        case dfm = 5
        
        var name: String {
            switch self {
            case .rs41: return "RS41"
            case .m20: return "M20"
            case .m10: return "M10"
            case .pilot: return "PILOT"
            case .dfm: return "DFM"
            }
        }
        
        var commandValue: Int {
            return self.rawValue
        }
        
        static func from(int value: Int) -> ProbeType? {
            return ProbeType(rawValue: value)
        }
        
        static func from(string value: String) -> ProbeType? {
            return ProbeType.allCases.first { $0.name == value.uppercased() }
        }
    }
    
    /// MySondyGo bandwidth values (see specification)
    enum Bandwidth: Int, CaseIterable, Codable {
        case bw2_6kHz = 0    // 2.6 kHz
        case bw3_1kHz = 1    // 3.1 kHz
        case bw3_9kHz = 2    // 3.9 kHz
        case bw5_2kHz = 3    // 5.2 kHz
        case bw6_3kHz = 4    // 6.3 kHz
        case bw7_8kHz = 5    // 7.8 kHz
        case bw10_4kHz = 6   // 10.4 kHz
        case bw12_5kHz = 7   // 12.5 kHz
        case bw15_6kHz = 8   // 15.6 kHz
        case bw20_8kHz = 9   // 20.8 kHz
        case bw25_0kHz = 10  // 25.0 kHz
        case bw31_3kHz = 11  // 31.3 kHz
        case bw41_7kHz = 12  // 41.7 kHz
        case bw50_0kHz = 13  // 50.0 kHz
        case bw62_5kHz = 14  // 62.5 kHz
        case bw83_3kHz = 15  // 83.3 kHz
        case bw100_0kHz = 16 // 100.0 kHz
        case bw125_0kHz = 17 // 125.0 kHz
        case bw166_7kHz = 18 // 166.7 kHz
        case bw200_0kHz = 19 // 200.0 kHz
        
        var frequency: Double {
            switch self {
            case .bw2_6kHz: return 2.6
            case .bw3_1kHz: return 3.1
            case .bw3_9kHz: return 3.9
            case .bw5_2kHz: return 5.2
            case .bw6_3kHz: return 6.3
            case .bw7_8kHz: return 7.8
            case .bw10_4kHz: return 10.4
            case .bw12_5kHz: return 12.5
            case .bw15_6kHz: return 15.6
            case .bw20_8kHz: return 20.8
            case .bw25_0kHz: return 25.0
            case .bw31_3kHz: return 31.3
            case .bw41_7kHz: return 41.7
            case .bw50_0kHz: return 50.0
            case .bw62_5kHz: return 62.5
            case .bw83_3kHz: return 83.3
            case .bw100_0kHz: return 100.0
            case .bw125_0kHz: return 125.0
            case .bw166_7kHz: return 166.7
            case .bw200_0kHz: return 200.0
            }
        }
        
        var displayName: String {
            return "\(frequency) kHz"
        }
        
        var commandValue: Int {
            return self.rawValue
        }
        
        static func from(int value: Int) -> Bandwidth? {
            return Bandwidth(rawValue: value)
        }
        
        static func from(frequency value: Double) -> Bandwidth? {
            return Bandwidth.allCases.first { abs($0.frequency - value) < 0.1 }
        }
    }
    
    /// Serial baud rate constants
    enum SerialBaudRate: Int, CaseIterable {
        case baud4800 = 0
        case baud9600 = 1
        case baud19200 = 2
        case baud38400 = 3
        case baud57600 = 4
        case baud115200 = 5
        
        var rate: Int {
            switch self {
            case .baud4800: return 4800
            case .baud9600: return 9600
            case .baud19200: return 19200
            case .baud38400: return 38400
            case .baud57600: return 57600
            case .baud115200: return 115200
            }
        }
    }
    
    /// Battery discharge type constants
    enum BatteryDischargeType: Int, CaseIterable {
        case linear = 0
        case sigmoidal = 1
        case asigmoidal = 2
    }

    // MARK: - MySondyGo Command Interface
    
    /// Request device status and configuration
    func getParameters() {
        sendCommand(command: "o{?}o")
    }
    
    /// Set frequency and probe type
    func sendProbeData(frequency: Double, probeType: Int) {
        let command = "o{f=\(frequency)/tipo=\(probeType)}o"
        sendCommand(command: command)
    }
    
    /// Set frequency and probe type (using ProbeType enum)
    func sendProbeData(frequency: Double, probeType: ProbeType) {
        sendProbeData(frequency: frequency, probeType: probeType.commandValue)
    }
    
    /// Control buzzer mute
    func setMute(_ muted: Bool) {
        let muteValue = muted ? 1 : 0
        let command = "o{mute=\(muteValue)}o"
        sendCommand(command: command)
    }
    
    /// Send custom settings command with key-value pairs
    func sendSettingsCommand(_ settings: [String: Any]) {
        let settingStrings = settings.map { key, value in
            "\(key)=\(value)"
        }
        let command = "o{\(settingStrings.joined(separator: "/"))}o"
        sendCommand(command: command)
    }
    
    /// Set LCD driver type (0=SSD1306_128X64, 1=SH1106_128X64) - requires reboot
    func setLCDDriver(_ type: Int) {
        sendSettingsCommand(["lcd": type])
    }
    
    /// Turn LCD on/off (0=Off, 1=On) - requires reboot
    func setLCDOn(_ enabled: Bool) {
        sendSettingsCommand(["lcdOn": enabled ? 1 : 0])
    }
    
    /// Set OLED pins - requires reboot
    func setOLEDPins(sda: Int, scl: Int, rst: Int) {
        sendSettingsCommand(["oled_sda": sda, "oled_scl": scl, "oled_rst": rst])
    }
    
    /// Set LED pin (0=off) - requires reboot
    func setLEDPin(_ pin: Int) {
        sendSettingsCommand(["led_pout": pin])
    }
    
    /// Set buzzer pin (0=no buzzer) - requires reboot
    func setBuzzerPin(_ pin: Int) {
        sendSettingsCommand(["buz_pin": pin])
    }
    
    /// Set call sign (max 8 chars, empty to hide)
    func setCallSign(_ callSign: String) {
        sendSettingsCommand(["myCall": callSign])
    }
    
    /// Turn Bluetooth on/off (0=off, 1=on) - requires reboot
    func setBluetooth(_ enabled: Bool) {
        sendSettingsCommand(["blu": enabled ? 1 : 0])
    }
    
    /// Set serial baud rate (0=4800, 1=9600, ..., 5=115200) - requires reboot
    func setSerialBaudRate(_ rate: Int) {
        sendSettingsCommand(["baud": rate])
    }
    
    /// Set serial port (0=USB, 1=pins 12/2) - requires reboot
    func setSerialPort(_ port: Int) {
        sendSettingsCommand(["com": port])
    }
    
    /// Set RX bandwidth for different probe types
    func setRXBandwidth(rs41: Int? = nil, m20: Int? = nil, m10: Int? = nil, pilot: Int? = nil, dfm: Int? = nil) {
        var settings: [String: Int] = [:]
        if let rs41 = rs41 { settings["rs41.rxbw"] = rs41 }
        if let m20 = m20 { settings["m20.rxbw"] = m20 }
        if let m10 = m10 { settings["m10.rxbw"] = m10 }
        if let pilot = pilot { settings["pilot.rxbw"] = pilot }
        if let dfm = dfm { settings["dfm.rxbw"] = dfm }
        
        if !settings.isEmpty {
            sendSettingsCommand(settings)
        }
    }
    
    /// Set APRS name type (0=Serial, 1=APRS NAME)
    func setAPRSNameType(_ type: Int) {
        sendSettingsCommand(["aprsName": type])
    }
    
    /// Set frequency correction
    func setFrequencyCorrection(_ correction: Int) {
        sendSettingsCommand(["freqofs": correction])
    }
    
    /// Set battery settings
    func setBatterySettings(pin: Int? = nil, minVoltage: Int? = nil, maxVoltage: Int? = nil, dischargeType: Int? = nil) {
        var settings: [String: Int] = [:]
        if let pin = pin { settings["battery"] = pin } // 0 = no battery
        if let minVoltage = minVoltage { settings["vBatMin"] = minVoltage } // mV
        if let maxVoltage = maxVoltage { settings["vBatMax"] = maxVoltage } // mV  
        if let dischargeType = dischargeType { settings["vBatType"] = dischargeType } // 0=Linear, 1=Sigmoidal, 2=Asigmoidal
        
        if !settings.isEmpty {
            sendSettingsCommand(settings)
        }
    }
    
    /// Convenience method for common device configuration using type-safe enums
    func configureDevice(frequency: Double, probeType: ProbeType, callSign: String, muted: Bool = false) {
        sendProbeData(frequency: frequency, probeType: probeType.rawValue)
        setCallSign(callSign)
        setMute(muted)
    }
    
    /// Set RX bandwidth using type-safe enums
    func setRXBandwidth(rs41: Bandwidth? = nil, m20: Bandwidth? = nil, m10: Bandwidth? = nil, pilot: Bandwidth? = nil, dfm: Bandwidth? = nil) {
        setRXBandwidth(
            rs41: rs41?.rawValue,
            m20: m20?.rawValue,
            m10: m10?.rawValue,
            pilot: pilot?.rawValue,
            dfm: dfm?.rawValue
        )
    }
    
    /// Set serial baud rate using type-safe enum
    func setSerialBaudRate(_ rate: SerialBaudRate) {
        setSerialBaudRate(rate.rawValue)
    }
    
    /// Set battery discharge type using type-safe enum
    func setBatteryDischargeType(_ type: BatteryDischargeType) {
        setBatterySettings(dischargeType: type.rawValue)
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
    
    // MARK: - Device Settings Management (moved from SettingsView for proper separation of concerns)
    
    /// Sends device settings to MySondyGo device, comparing with initial settings to only send changed values
    func sendDeviceSettings(current: DeviceSettings, initial: DeviceSettings) {
        appLog("BLE: Starting device settings update - comparing current vs initial", category: .ble, level: .info)
        
        // Pin configurations
        if current.oledSDA != initial.oledSDA {
            let command = "o{oled_sda=\(current.oledSDA)}o"
            sendCommand(command: command)
        }
        if current.oledSCL != initial.oledSCL {
            let command = "o{oled_scl=\(current.oledSCL)}o"
            sendCommand(command: command)
        }
        if current.oledRST != initial.oledRST {
            let command = "o{oled_rst=\(current.oledRST)}o"
            sendCommand(command: command)
        }
        if current.ledPin != initial.ledPin {
            let command = "o{led_pout=\(current.ledPin)}o"
            sendCommand(command: command)
        }
        if current.buzPin != initial.buzPin {
            let command = "o{buz_pin=\(current.buzPin)}o"
            sendCommand(command: command)
        }
        
        // Battery settings
        if current.batPin != initial.batPin {
            let command = "o{battery=\(current.batPin)}o"
            sendCommand(command: command)
        }
        if current.batMin != initial.batMin {
            let command = "o{vBatMin=\(current.batMin)}o"
            sendCommand(command: command)
        }
        if current.batMax != initial.batMax {
            let command = "o{vBatMax=\(current.batMax)}o"
            sendCommand(command: command)
        }
        if current.batType != initial.batType {
            let command = "o{vBatType=\(current.batType)}o"
            sendCommand(command: command)
        }
        
        // Display settings
        if current.lcdType != initial.lcdType {
            let command = "o{oled=\(current.lcdType)}o"
            sendCommand(command: command)
        }
        if current.nameType != initial.nameType {
            let command = "o{name=\(current.nameType)}o"
            sendCommand(command: command)
        }
        
        // Serial settings (with baud rate conversion)
        if current.bluetoothStatus != initial.bluetoothStatus {
            let command = "o{bt=\(current.bluetoothStatus)}o"
            sendCommand(command: command)
        }
        if current.lcdStatus != initial.lcdStatus {
            let command = "o{lcd=\(current.lcdStatus)}o"
            sendCommand(command: command)
        }
        if current.serialSpeed != initial.serialSpeed {
            let baudIndex = convertBaudRateToIndex(current.serialSpeed)
            let command = "o{serBaud=\(baudIndex)}o"
            sendCommand(command: command)
        }
        if current.serialPort != initial.serialPort {
            let command = "o{ser=\(current.serialPort)}o"
            sendCommand(command: command)
        }
        if current.aprsName != initial.aprsName {
            let command = "o{call=\(current.aprsName)}o"
            sendCommand(command: command)
        }
        
        appLog("BLE: Device settings update completed", category: .ble, level: .info)
    }
    
    /// Converts baud rate to device index (moved from SettingsView business logic)
    private func convertBaudRateToIndex(_ baudRate: Int) -> Int {
        switch baudRate {
        case 1200: return 0
        case 2400: return 1
        case 4800: return 2
        case 9600: return 3
        case 19200: return 4
        case 38400: return 5
        case 57600: return 6
        case 115200: return 7
        default: return 7 // Default to 115200
        }
    }

    private func publishHealthEvent(_ health: ServiceHealth, message: String) {
        serviceHealth = health
        // Service health events removed - health tracked internally only
        // Health status logging removed for log reduction
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
    
    /// Debug method to print current BLE state (production mode - essential info only)
    func printBLEDiagnostics() {
        appLog("BLE: State=\(bluetoothStateString(centralManager.state)) Status=\(connectionStatus) Ready=\(isReadyForCommands)", category: .ble, level: .info)
    }
    
    // Helper function to convert probe type integer to string
    private func convertProbeTypeIntToString(_ probeTypeInt: Int) -> String {
        return BLECommunicationService.ProbeType.from(int: probeTypeInt)?.name ?? ""
    }
}