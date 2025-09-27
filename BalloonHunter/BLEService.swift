/* [markdown]
# 1. BLE Communication Service

### Purpose
Manages Bluetooth communication with **MySondyGo** devices.

---

### Input Triggers
- Bluetooth state changes (powered on/off)  
- Device discovery events  
- Incoming BLE data packets  
- User commands (e.g., get parameters, set frequency)

---

### Data Consumed
- Raw BLE message strings (Types 0, 1, 2, 3 packets)  
- User command requests  
- Bluetooth peripheral data

---

### Data Published
- `@Published var telemetryState: BLETelemetryState` — Unified BLE telemetry state (.BLEnotconnected, .readyForCommands, .BLEtelemetryIsReady)
- `@Published var latestTelemetry: TelemetryData?` — Latest parsed telemetry
- `@Published var deviceSettings: DeviceSettings` — MySondyGo device configuration
- `@Published var deviceStatus: DeviceStatusData?` — Type 0 device status (battery %, voltage, signal strength)
- `@Published var connectionStatus: ConnectionStatus` — `.connected`, `.disconnected`, `.connecting`
- `@Published var lastMessageType: String?` — `"0"`, `"1"`, `"2"`, `"3"`
- `PassthroughSubject<TelemetryData, Never>()` — Real-time telemetry stream
- `@Published var lastTelemetryUpdateTime: Date?` — Last update timestamp
- `@Published var lastMessageTimestamp: Date?` — Last message receipt timestamp

---

### Example Data
```swift
TelemetryData(
    sondeName: "V4210129",
    probeType: "RS41",
    frequency: 404.500,
    latitude: 46.9043,
    longitude: 7.3100,
    altitude: 1151.0,       // meters
    verticalSpeed: 153.0,   // m/s
    horizontalSpeed: 25.3,  // km/h
    signalStrength: -90     // dBm
)
*/

import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import OSLog

// MARK: - BLE Data Models

struct DeviceSettings: Codable {
    var frequency: Double = 403.5
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
                // Device sent string directly - validate and use it (handle both full and short forms)
                let upperCaseType = probeTypeComponent.uppercased()
                if ["RS41", "M20", "M10", "PILOT", "DFM"].contains(upperCaseType) {
                    probeType = upperCaseType
                    appLog("DeviceSettings: Using string probeType: '\(probeType)'", category: .ble, level: .debug)
                } else if upperCaseType == "PIL" {
                    // Handle shortened PILOT form
                    probeType = "PILOT"
                    appLog("DeviceSettings: Converted shortened 'PIL' to 'PILOT'", category: .ble, level: .debug)
                } else {
                    probeType = ""
                    appLog("DeviceSettings: Invalid probeType string '\(probeTypeComponent)' - setting to empty", category: .ble, level: .debug)
                }
            }
            let rawFrequency = Double(components[2]) ?? 434.0
            frequency = (rawFrequency * 100).rounded() / 100.0
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
    let batteryPercentage: Int
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

    var isBLETelemetryStale: Bool = false
    private var previousTelemetryAvailable: Bool = false
    private var telemetryLogCount: Int = 0
    @Published var latestTelemetry: TelemetryData? = nil
    @Published var deviceSettings: DeviceSettings = .default
    @Published var deviceStatus: DeviceStatusData? = nil
    @Published var connectionStatus: ConnectionStatus = .disconnected
    var lastMessageType: String? = nil
    @Published var telemetryData = PassthroughSubject<TelemetryData, Never>()
    var lastTelemetryUpdateTime: Date? = nil
    // Unified telemetry state
    @Published var telemetryState: BLETelemetryState = .BLEnotconnected
    @Published var lastMessageTimestamp: Date? = nil
    let centralManagerPoweredOn = PassthroughSubject<Void, Never>()

    

    init(persistenceService: PersistenceService) {
        self.persistenceService = persistenceService
        super.init()
        
        // BLE service initialized with UART UUIDs
        
        appLog("BLE: Initializing CBCentralManager", category: .ble, level: .info)
        centralManager = CBCentralManager(delegate: self, queue: nil)

        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.updateBLEStaleState()
            }
        }
        
        // Periodic diagnostic timer to help debug BLE issues
        // Removed: BLE diagnostics timer - state logging moved to state machine
        
        // BLE service initialized (logged at AppServices level)
        publishHealthEvent(.healthy, message: "BLE service initialized")
    }

    private func updateBLEStaleState() async {
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

        // Update telemetry state based on staleness
        if !isAvailable && telemetryState == .BLEtelemetryIsReady {
            telemetryState = .readyForCommands
            appLog("BLECommunicationService: Telemetry state downgraded due to staleness: \(reason)", category: .ble, level: .info)
        }

        // Log telemetry availability changes only when status changes
        if previousTelemetryAvailable != isAvailable {
            appLog("BLECommunicationService: Telemetry \(isAvailable ? "GAINED" : "LOST"): \(reason)", category: .ble, level: .info)
            previousTelemetryAvailable = isAvailable
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
            telemetryState = .BLEnotconnected
            lastMessageTimestamp = Date()
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
        // telemetryState remains .BLEnotconnected until first packet received
        lastMessageTimestamp = Date()

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
        telemetryState = .BLEnotconnected
        lastMessageTimestamp = Date()
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
        telemetryState = .BLEnotconnected
        lastMessageTimestamp = Date()
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
            // Note: telemetryState will be updated when first valid BLE packet is received
            appLog("🟢 BLE: TX characteristic configured - waiting for first BLE packet", category: .ble, level: .info)
            publishHealthEvent(.healthy, message: "BLE characteristics configured")
            
            // Startup optimization: No automatic o{?}o command during startup
            // Device settings (frequency/probe type) are available in telemetry packets
            // Settings are only fetched on-demand when SettingsView is opened
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
        
        // Update telemetry state based on packet type and current state
        lastMessageTimestamp = Date()

        if telemetryState == .BLEnotconnected {
            telemetryState = .readyForCommands
            appLog("🟢 BLE: Ready for commands - first valid BLE packet received (Type \(messageType))", category: .ble, level: .info)
            publishHealthEvent(.healthy, message: "BLE ready for commands")
        }

        // Upgrade to telemetry ready if this is a Type 1 (telemetry) packet
        if messageType == "1" && telemetryState == .readyForCommands {
            telemetryState = .BLEtelemetryIsReady
            appLog("🟢 BLE: Telemetry ready - Type 1 packet received", category: .ble, level: .info)
        }
        
        // Check if this is the first packet and publish telemetry availability event
        if !hasProcessedFirstPacket {
            hasProcessedFirstPacket = true
            let isTelemetryAvailable = messageType == "1"
            let reason = isTelemetryAvailable ? "Type 1 telemetry packet received" : "Non-telemetry packet received (Type \(messageType))"
            
            // Log first packet telemetry status
            appLog("BLECommunicationService: First packet - \(reason)", category: .service, level: .info)
            
            // First packet processed
            
            // Startup optimization: Skip device settings command during startup
            // Settings are fetched on-demand by SettingsView when needed
            // Frequency and probe type are available in telemetry packets
        }
        
        switch messageType {
        case "0":
            // Device Basic Info and Status - FSD: 0/probeType/frequency/RSSI/batPercentage/batVoltage/buzmute/softwareVersion/o
            if let (status, telemetry) = parseType0Message(components) {
                deviceStatus = status

                // Update deviceSettings with probe type and frequency from Type 0 packet per FSD
                deviceSettings.probeType = telemetry.probeType
                deviceSettings.frequency = telemetry.frequency

                // Type 0 packets are device status only - do NOT send as telemetry data
                // Position data is invalid (0,0) and would override APRS telemetry
                latestTelemetry = telemetry  // Update for UI display only

                // Show all available packet data for Type 0 messages
                let packetInfo = components.enumerated().map { (index, value) in
                    return "[\(index)]=\(value)"
                }.joined(separator: " ")
                appLog("📊 BLE PARSED (Type 0): Device status - battery=\(String(format: "%.2f", status.batteryVoltage))V (\(status.batteryPercentage)%) signal=\(status.signalStrength)dBm | Raw: \(packetInfo)", category: .ble, level: .info)
            } else {
                // Show raw packet even if parsing failed
                let packetInfo = components.enumerated().map { (index, value) in
                    return "[\(index)]=\(value)"
                }.joined(separator: " ")
                appLog("🔴 BLE PARSED (Type 0): Failed to parse - Raw: \(packetInfo)", category: .ble, level: .error)
            }
            
        case "1":
            // Probe Telemetry
            if components.count >= 20 {
                // Throttle telemetry logging to every 5th packet to reduce verbosity
                telemetryLogCount += 1
                if telemetryLogCount % 5 == 1 {
                    let keyInfo = [
                        components[1], // probeType
                        "\(components[3])", // sondeName
                        "lat=\(components[4])",
                        "lon=\(components[5])",
                        "alt=\(components[6])m",
                        "v=\(components[8])m/s",
                        "h=\(components[7])m/s",
                        "RSSI=\(displayRssi(from: components[9]))dBm",
                        "bat=\(components[10])%"
                    ].joined(separator: " ")
                    appLog("📡 BLE (\(telemetryLogCount), every 5th): \(keyInfo)", category: .ble, level: .info)
                }
                // Plausibility checks
                var warns: [String] = []
                if let lat = Double(components[4]), !(lat >= -90 && lat <= 90) { warns.append("latitude out of range") }
                if let lon = Double(components[5]), !(lon >= -180 && lon <= 180) { warns.append("longitude out of range") }
                if let alt = Double(components[6]), !(alt >= -500 && alt <= 60000) { warns.append("altitude implausible") }
                if let hs = Double(components[7]), !(hs >= 0 && hs <= 150) { warns.append("horizontalSpeed implausible (m/s)") }
                if let vs = Double(components[8]), !(abs(vs) <= 100) { warns.append("verticalSpeed implausible (m/s)") }
                // RSSI normalization handled in parser; no positivity warning needed
                if let batp = Int(components[10]), !(0...100).contains(batp) { warns.append("batPercentage out of range") }
                if let batmv = Int(components[14]), !(2500...5000).contains(batmv) { warns.append("batVoltage mV implausible") }
                if !warns.isEmpty { appLog("⚠️ BLE MSG (Type 1) plausibility: " + warns.joined(separator: ", "), category: .ble, level: .info) }
            } else {
                appLog("🔴 BLE MSG (Type 1): Invalid field count=\(components.count)", category: .ble, level: .error)
            }
            if let telemetry = parseType1Message(components) {
                if telemetry.latitude == 0.0 && telemetry.longitude == 0.0 {
                    return // Skip invalid coordinates
                }
                
                
                DispatchQueue.main.async {
                    self.latestTelemetry = telemetry
                    self.lastTelemetryUpdateTime = Date()
                    self.telemetryData.send(telemetry)
                    // Suppress verbose per-packet parsed telemetry log
                    // Telemetry is now available through @Published latestTelemetry property
                    // Services observe this directly instead of using EventBus
                    
                    // Device settings request is handled by the connection ready callback
                    // No need to request again here
                }
            }
            
        case "2":
            // Name Only
            if components.count >= 10 {
                // Consolidated Type 2 message with key info
                let keyInfo = [
                    components[1], // probeType
                    "\(components[3])", // sondeName
                    "RSSI=\(displayRssi(from: components[4]))dBm",
                    "bat=\(components[5])%"
                ].joined(separator: " ")
                appLog("🏷️ BLE: \(keyInfo)", category: .ble, level: .info)
                // Plausibility checks (limited fields)
                var warns: [String] = []
                if let rssi = adjustedRssiValue(from: components[4]), rssi > -10 { warns.append("RSSI unusually high (>-10 dBm)") }
                if let batp = Int(components[5]), !(0...100).contains(batp) { warns.append("batPercentage out of range") }
                if let batmv = Int(components[7]), !(2500...5000).contains(batmv) { warns.append("batVoltage mV implausible") }
                if !warns.isEmpty { appLog("⚠️ BLE MSG (Type 2) plausibility: " + warns.joined(separator: ", "), category: .ble, level: .info) }
            } else {
                appLog("🔴 BLE MSG (Type 2): Invalid field count=\(components.count)", category: .ble, level: .error)
            }
            if let telemetry = parseType2Message(components) {
                // Update deviceSettings with probe type and frequency from Type 2 packet per FSD
                deviceSettings.probeType = telemetry.probeType
                deviceSettings.frequency = telemetry.frequency

                // Type 2 packets are partial telemetry without GPS position - do NOT send as telemetry data
                // Position data is invalid (0,0) and would override APRS telemetry
                latestTelemetry = telemetry  // Update for UI display only

                appLog("📊 BLE PARSED (Type 2): Device status without position - \(telemetry.sondeName)", category: .ble, level: .info)
            }
            
        case "3":
            // Device Configuration
            if components.count >= 22 {
                // Consolidated Type 3 message with key config info
                let keyInfo = [
                    components[1], // probeType
                    "freq=\(components[2])MHz",
                    "callSign=\(components[12])",
                    "sw=\(components[21])"
                ].joined(separator: " ")
                appLog("⚙️ BLE: \(keyInfo)", category: .ble, level: .info)
                // Plausibility checks for pins and fields
                var warns: [String] = []
                let intIn = { (i: Int) -> Int? in Int(components[i]) }
                if let sda = intIn(3), sda < 0 || sda > 39 { warns.append("oledSDA out of ESP32 range") }
                if let scl = intIn(4), scl < 0 || scl > 39 { warns.append("oledSCL out of ESP32 range") }
                if let rst = intIn(5), rst < 0 || rst > 39 { warns.append("oledRST out of ESP32 range") }
                if let led = intIn(6), led < 0 || led > 39 { warns.append("ledPin out of ESP32 range") }
                if let batPin = intIn(14), batPin < 0 || batPin > 39 { warns.append("batPin out of ESP32 range") }
                if let batMin = intIn(15), !(2000...4500).contains(batMin) { warns.append("batMin implausible") }
                if let batMax = intIn(16), !(3000...5000).contains(batMax) { warns.append("batMax implausible") }
                if !warns.isEmpty { appLog("⚠️ BLE MSG (Type 3) plausibility: " + warns.joined(separator: ", "), category: .ble, level: .info) }
            } else {
                appLog("🔴 BLE MSG (Type 3): Invalid field count=\(components.count)", category: .ble, level: .error)
            }
            if let settings = parseType3Message(components) {
                appLog("⚙️ BLE PARSED (Type 3): Device config - callSign=\(settings.callSign) freq=\(String(format: "%.2f", settings.frequency))MHz probeType=\(settings.probeType)", category: .ble, level: .info)
                DispatchQueue.main.async {
                    let previousSettings = self.deviceSettings
                    self.deviceSettings = settings
                    if abs(previousSettings.frequency - settings.frequency) > 0.005 || previousSettings.probeType != settings.probeType {
                        appLog("BLE: Device settings updated -> freq=\(String(format: "%.2f", settings.frequency))MHz (prev=\(String(format: "%.2f", previousSettings.frequency))) type=\(settings.probeType)", category: .ble, level: .info)
                    }
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

    private func adjustedRssiValue(from rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed) else { return nil }
        return value > 0 ? -value : value
    }

    private func displayRssi(from rawValue: String) -> String {
        if let adjusted = adjustedRssiValue(from: rawValue) {
            return String(adjusted)
        }
        return rawValue
    }

    // Type 0: Device Basic Info and Status
    private func parseType0Message(_ components: [String]) -> (DeviceStatusData, TelemetryData)? {
        guard let messageType = components.first, messageType == "0" else {
            appLog("BLE: Type 0 parse mismatch - expected leading '0', found '\(components.first ?? "nil")'", category: .ble, level: .error)
            return nil
        }
        guard components.count >= 8 else { return nil }

        // FSD: 0/probeType/frequency/RSSI/batPercentage/batVoltage/buzmute/softwareVersion/o
        let probeType = components[1]
        let frequency = Double(components[2]) ?? 0.0
        let rssiValue = adjustedRssiValue(from: components[3]) ?? (Double(components[3]) ?? 0.0)
        let batteryPercentage = Int(components[4]) ?? 0
        let batteryVoltage = Double(components[5]) ?? 0.0
        let buzmute = components[6] == "1"
        let softwareVersion = components[7]

        let deviceStatus = DeviceStatusData(
            batteryVoltage: batteryVoltage,
            batteryPercentage: batteryPercentage,
            temperature: 0.0, // Not provided in this message type
            signalStrength: Int(rssiValue),
            timestamp: Date()
        )

        // Create TelemetryData from Type 0 packet
        var telemetry = TelemetryData()
        telemetry.probeType = probeType
        telemetry.frequency = frequency
        telemetry.signalStrength = Int(rssiValue)
        telemetry.batteryPercentage = batteryPercentage
        telemetry.batteryVoltage = batteryVoltage
        telemetry.buzmute = buzmute
        telemetry.softwareVersion = softwareVersion
        telemetry.timestamp = Date()
        // Position fields remain at default 0.0 for Type 0

        return (deviceStatus, telemetry)
    }
    
    // Type 1: Probe Telemetry
    private func parseType1Message(_ components: [String]) -> TelemetryData? {
        guard let messageType = components.first, messageType == "1" else {
            appLog("BLE: Type 1 parse mismatch - expected leading '1', found '\(components.first ?? "nil")'", category: .ble, level: .error)
            return nil
        }
        guard components.count >= 20 else { return nil }
        
        let probeTypeRaw = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawFrequency = Double(components[2]) ?? 0.0
        let frequency = (rawFrequency * 100).rounded() / 100.0
        let sondeName = components[3]
        let latitude = Double(components[4]) ?? 0.0
        let longitude = Double(components[5]) ?? 0.0
        let altitude = Double(components[6]) ?? 0.0
        let horizontalSpeed = Double(components[7]) ?? 0.0
        let verticalSpeed = Double(components[8]) ?? 0.0
        let rssi = adjustedRssiValue(from: components[9]) ?? (Double(components[9]) ?? 0.0)
        let batteryPercentage = Int(components[10]) ?? 0
        let batteryVoltage = Double(components[14]) ?? 0.0
        let buzmute = components[15] == "1"

        // Validate essential fields (frequency, probe type, coordinates)
        let isValidCoordinate = latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 && !(latitude == 0 && longitude == 0)
        guard frequency > 0,
              !probeTypeRaw.isEmpty,
              isValidCoordinate else {
            appLog("BLE: Discarding telemetry with invalid essentials (freq=\(frequency), probe='\(probeTypeRaw)', lat=\(latitude), lon=\(longitude))", category: .ble, level: .info)
            return nil
        }

        var telemetry = TelemetryData()
        telemetry.sondeName = sondeName
        telemetry.probeType = probeTypeRaw
        telemetry.frequency = frequency
        telemetry.latitude = latitude
        telemetry.longitude = longitude
        telemetry.altitude = altitude
        telemetry.horizontalSpeed = horizontalSpeed
        telemetry.verticalSpeed = verticalSpeed
        telemetry.signalStrength = Int(rssi)
        telemetry.batteryPercentage = batteryPercentage
        telemetry.afcFrequency = Int(components[11]) ?? 0
        telemetry.burstKillerEnabled = components[12] == "1"
        telemetry.burstKillerTime = Int(components[13]) ?? 0
        telemetry.batteryVoltage = batteryVoltage
        telemetry.buzmute = buzmute
        telemetry.softwareVersion = components[19]
        telemetry.timestamp = Date()
        return telemetry
    }
    
    // Type 2: Partial Telemetry
    private func parseType2Message(_ components: [String]) -> TelemetryData? {
        guard let messageType = components.first, messageType == "2" else {
            appLog("BLE: Type 2 parse mismatch - expected leading '2', found '\(components.first ?? "nil")'", category: .ble, level: .error)
            return nil
        }
        guard components.count >= 10 else { return nil }

        // FSD: 2/probeType/frequency/sondeName/RSSI/batPercentage/afcFrequency/batVoltage/buzmute/softwareVersion/o
        let probeType = components[1]
        let frequency = Double(components[2]) ?? 0.0
        let sondeName = components[3]
        let rssiValue = adjustedRssiValue(from: components[4]) ?? (Double(components[4]) ?? 0.0)
        let batteryPercentage = Int(components[5]) ?? 0
        let afcFrequency = Int(components[6]) ?? 0
        let batteryVoltage = Double(components[7]) ?? 0.0
        let buzmute = components[8] == "1"
        let softwareVersion = components[9]

        // Create TelemetryData from Type 2 packet
        var telemetry = TelemetryData()
        telemetry.probeType = probeType
        telemetry.frequency = frequency
        telemetry.sondeName = sondeName
        telemetry.signalStrength = Int(rssiValue)
        telemetry.batteryPercentage = batteryPercentage
        telemetry.afcFrequency = afcFrequency
        telemetry.batteryVoltage = batteryVoltage
        telemetry.buzmute = buzmute
        telemetry.softwareVersion = softwareVersion
        telemetry.timestamp = Date()
        // Position fields remain at default 0.0 for Type 2 per FSD note

        return telemetry
    }

    // Type 3: Device Configuration
    private func parseType3Message(_ components: [String]) -> DeviceSettings? {
        guard let messageType = components.first, messageType == "3" else {
            appLog("BLE: Type 3 parse mismatch - expected leading '3', found '\(components.first ?? "nil")'", category: .ble, level: .error)
            return nil
        }
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
    
    /// Propagate a frequency change to the device and local caches.
    func setFrequency(_ frequency: Double, probeType: ProbeType) {
        let roundedFrequency = (frequency * 100).rounded() / 100.0
        let formattedFrequency = String(format: "%.2f", roundedFrequency)
        appLog("BLE: Applying frequency change (freq=\(formattedFrequency) type=\(probeType.name))", category: .ble, level: .info)

        let command = "o{f=\(formattedFrequency)/tipo=\(probeType.commandValue)}o"
        sendCommand(command: command)

        DispatchQueue.main.async {
            var updatedSettings = self.deviceSettings
            if abs(updatedSettings.frequency - roundedFrequency) > 0.005 || updatedSettings.probeType != probeType.name {
                updatedSettings.frequency = roundedFrequency
                updatedSettings.probeType = probeType.name
                self.deviceSettings = updatedSettings
                appLog("BLE: Updated cached device settings after frequency change (freq=\(formattedFrequency) type=\(probeType.name))", category: .ble, level: .debug)
                self.persistenceService.save(deviceSettings: updatedSettings)
            }

            if var telemetry = self.latestTelemetry {
                telemetry.frequency = roundedFrequency
                telemetry.probeType = probeType.name
                self.latestTelemetry = telemetry
            }
        }
    }

    // MARK: - Centralized Frequency Management Service

    /// Update frequency with validation and automatic persistence
    /// This is the primary method for frequency changes throughout the app
    func updateFrequency(to frequency: Double, probeType: String? = nil, source: String = "User") {
        // Input validation
        guard isValidFrequency(frequency) else {
            appLog("BLE: Invalid frequency \(frequency) MHz rejected", category: .ble, level: .error)
            return
        }

        // Determine probe type
        let targetProbeType: ProbeType
        if let probeTypeString = probeType {
            targetProbeType = ProbeType.from(string: probeTypeString) ?? ProbeType.from(string: deviceSettings.probeType) ?? .rs41
        } else {
            targetProbeType = ProbeType.from(string: deviceSettings.probeType) ?? .rs41
        }

        appLog("BLE: Frequency update request from \(source) - \(String(format: "%.2f", frequency)) MHz (\(targetProbeType.name))", category: .ble, level: .info)

        // Use existing setFrequency method
        setFrequency(frequency, probeType: targetProbeType)
    }

    /// Update frequency from digit array (for UI input)
    func updateFrequencyFromDigits(_ digits: [Int], probeType: String? = nil, source: String = "SettingsUI") {
        guard digits.count >= 6 else {
            appLog("BLE: Invalid frequency digits array (count=\(digits.count))", category: .ble, level: .error)
            return
        }

        let frequency = calculateFrequencyFromDigits(digits)
        updateFrequency(to: frequency, probeType: probeType, source: source)
    }


    /// Sync frequency from external source (APRS)
    func syncFrequencyFromExternal(_ frequency: Double, probeType: String, source: String) {
        updateFrequency(to: frequency, probeType: probeType, source: source)
    }

    // MARK: - Frequency Sync Proposal Management

    private var rejectedProposals: [String: Date] = [:] // Key: "frequency-probeType", Value: rejection timestamp

    /// Propose frequency change with user confirmation (returns true if proposal should be shown)
    func proposeFrequencyChange(from currentFreq: Double, currentProbe: String, to targetFreq: Double, targetProbe: String) -> Bool {
        // First check if frequencies/probe types are actually different
        let freqMismatch = abs(targetFreq - currentFreq) > 0.01 // 0.01 MHz tolerance
        let probeTypeMismatch = targetProbe != currentProbe

        guard freqMismatch || probeTypeMismatch else {
            appLog("BLE: Frequency sync not needed - frequencies and probe types already match (\(String(format: "%.2f", currentFreq)) MHz, \(currentProbe))", category: .ble, level: .debug)
            return false
        }

        // Check if this proposal was recently rejected (5-minute cooldown)
        let proposalKey = "\(String(format: "%.2f", targetFreq))-\(targetProbe)"
        let now = Date()
        let cooldownPeriod: TimeInterval = 300 // 5 minutes

        if let rejectionTime = rejectedProposals[proposalKey],
           now.timeIntervalSince(rejectionTime) < cooldownPeriod {
            let remainingCooldown = Int(cooldownPeriod - now.timeIntervalSince(rejectionTime))
            appLog("BLE: Frequency sync proposal \(proposalKey) still in cooldown (\(remainingCooldown)s remaining)", category: .ble, level: .debug)
            return false
        }

        appLog("BLE: Frequency sync proposal created - \(String(format: "%.2f", currentFreq)) MHz (\(currentProbe)) → \(String(format: "%.2f", targetFreq)) MHz (\(targetProbe))", category: .ble, level: .info)
        return true
    }

    /// Accept frequency sync proposal and apply change
    func acceptFrequencySync(frequency: Double, probeType: String, source: String = "UserAccepted") {
        appLog("BLE: User accepted frequency sync - applying \(String(format: "%.2f", frequency)) MHz (\(probeType))", category: .ble, level: .info)
        updateFrequency(to: frequency, probeType: probeType, source: source)
    }

    /// Reject frequency sync proposal and record cooldown
    func rejectFrequencySync(frequency: Double, probeType: String) {
        let proposalKey = "\(String(format: "%.2f", frequency))-\(probeType)"
        rejectedProposals[proposalKey] = Date()

        appLog("BLE: User rejected frequency sync proposal - keeping current settings (\(String(format: "%.2f", deviceSettings.frequency)) MHz, \(deviceSettings.probeType)). Cooldown: 5 minutes", category: .ble, level: .info)
    }

    // MARK: - Frequency Validation and Utilities

    /// Validate frequency is within MySondyGo supported range (400-406 MHz)
    private func isValidFrequency(_ frequency: Double) -> Bool {
        return frequency >= 400.0 && frequency <= 406.0 && frequency.isFinite
    }

    /// Calculate frequency from UI digit array
    private func calculateFrequencyFromDigits(_ digits: [Int]) -> Double {
        guard digits.count >= 6 else { return 0.0 }
        return Double(digits[0] * 100 + digits[1] * 10 + digits[2]) +
               Double(digits[3]) * 0.1 +
               Double(digits[4]) * 0.01 +
               Double(digits[5]) * 0.001
    }

    /// Get current frequency for UI display
    func getCurrentFrequency() -> Double {
        return deviceSettings.frequency
    }

    /// Get current probe type for UI display
    func getCurrentProbeType() -> String {
        return deviceSettings.probeType
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
    
    /// Apply arbitrary key/value settings to the device.
    func setSettings(_ settings: [String: Any]) {
        sendSettingsCommand(settings)
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
        setFrequency(frequency, probeType: probeType)
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
        if !telemetryState.canReceiveCommands {
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
        appLog("📤 BLE COMMAND: \(command)", category: .ble, level: .info)
    }
    
    // MARK: - Device Settings Management (moved from SettingsView for proper separation of concerns)
    
    /// Compute the list of commands needed to apply settings differences (testable, no BLE I/O)
    func computeDeviceSettingsCommands(current: DeviceSettings, initial: DeviceSettings) -> [String] {
        var commands: [String] = []
        // Pin configurations
        if current.oledSDA != initial.oledSDA { commands.append("o{oled_sda=\(current.oledSDA)}o") }
        if current.oledSCL != initial.oledSCL { commands.append("o{oled_scl=\(current.oledSCL)}o") }
        if current.oledRST != initial.oledRST { commands.append("o{oled_rst=\(current.oledRST)}o") }
        if current.ledPin != initial.ledPin { commands.append("o{led_pout=\(current.ledPin)}o") }
        if current.buzPin != initial.buzPin { commands.append("o{buz_pin=\(current.buzPin)}o") }

        // Battery settings
        if current.batPin != initial.batPin { commands.append("o{battery=\(current.batPin)}o") }
        if current.batMin != initial.batMin { commands.append("o{vBatMin=\(current.batMin)}o") }
        if current.batMax != initial.batMax { commands.append("o{vBatMax=\(current.batMax)}o") }
        if current.batType != initial.batType { commands.append("o{vBatType=\(current.batType)}o") }

        // Display settings
        if current.lcdType != initial.lcdType { commands.append("o{oled=\(current.lcdType)}o") }
        if current.nameType != initial.nameType { commands.append("o{name=\(current.nameType)}o") }

        // Serial and misc settings
        if current.bluetoothStatus != initial.bluetoothStatus { commands.append("o{bt=\(current.bluetoothStatus)}o") }
        if current.lcdStatus != initial.lcdStatus { commands.append("o{lcd=\(current.lcdStatus)}o") }
        if current.serialSpeed != initial.serialSpeed {
            let baudIndex = convertBaudRateToIndex(current.serialSpeed)
            commands.append("o{serBaud=\(baudIndex)}o")
        }
        if current.serialPort != initial.serialPort { commands.append("o{ser=\(current.serialPort)}o") }
        if current.aprsName != initial.aprsName { commands.append("o{call=\(current.aprsName)}o") }

        return commands
    }

    

    /// Sends device settings to the device by computing differences and emitting commands
    func sendDeviceSettings(current: DeviceSettings, initial: DeviceSettings) {
        appLog("BLE: Starting device settings update - comparing current vs initial", category: .ble, level: .info)
        let commands = computeDeviceSettingsCommands(current: current, initial: initial)
        for cmd in commands { sendCommand(command: cmd) }
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
    
    // Removed: printBLEDiagnostics - state information now logged in state machine transitions
    
    // Helper function to convert probe type integer to string
    private func convertProbeTypeIntToString(_ probeTypeInt: Int) -> String {
        return BLECommunicationService.ProbeType.from(int: probeTypeInt)?.name ?? ""
    }
}
