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
    private var hasProcessedFirstPacket = false

    // Buffer to accumulate incoming BLE data fragments until a full message is received
    private var incomingBLEBuffer: Data = Data()
    private var lastBLEMessageTime: Date = Date.distantPast

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
            EventBus.shared.publishTelemetryAvailability(TelemetryAvailabilityEvent(
                isAvailable: isAvailable,
                reason: reason
            ))
            
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
            appLog("BLE: Found MySondyGo device: \(name)", category: .ble, level: .info)
            central.stopScan()
            connectedPeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            publishHealthEvent(.healthy, message: "MySondyGo device found")
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
            
            // Initialize device by reading settings - this often triggers telemetry transmission
            if !hasSentReadSettingsCommand {
                appLog("BLE: Scheduling device settings read command", category: .ble, level: .debug)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { return }
                    if !self.hasSentReadSettingsCommand {
                        appLog("BLE: Sending device settings read command", category: .ble, level: .debug)
                        self.getParameters()
                        self.hasSentReadSettingsCommand = true
                    } else {
                        appLog("BLE: Device settings command already sent, skipping", category: .ble, level: .debug)
                    }
                }
            } else {
                appLog("BLE: Device settings command already scheduled/sent", category: .ble, level: .debug)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            appLog("BLE: Error updating value: \(error.localizedDescription)", category: .ble, level: .error)
            publishHealthEvent(.degraded, message: "BLE update error")
            return
        }

        guard let data = characteristic.value else {
            return
        }

        if let string = String(data: data, encoding: .utf8) {
            appLog("BLE RAW: '\(string)'", category: .ble, level: .debug)
            parseMessage(string)
        }
    }

    private func parseMessage(_ message: String) {
        if !isReadyForCommands {
            isReadyForCommands = true
        }
        
        let components = message.components(separatedBy: "/")
        guard components.count > 1 else {
            return
        }
        
        let messageType = components[0]
        
        // Check if this is the first packet and publish telemetry availability event
        if !hasProcessedFirstPacket {
            hasProcessedFirstPacket = true
            let isTelemetryAvailable = messageType == "1"
            let reason = isTelemetryAvailable ? "Type 1 telemetry packet received" : "Non-telemetry packet received (Type \(messageType))"
            
            EventBus.shared.publishTelemetryAvailability(TelemetryAvailabilityEvent(
                isAvailable: isTelemetryAvailable,
                reason: reason
            ))
            
            appLog("BLE: First packet processed - telemetry available: \(isTelemetryAvailable) (\(reason))", category: .ble, level: .info)
        }
        
        switch messageType {
        case "0":
            // Device Basic Info and Status
            if let deviceStatus = parseType0Message(components) {
                appLog("BLE PARSED: Type=0 probe=\(deviceStatus.probeType) freq=\(deviceStatus.frequency) rssi=\(Int(deviceStatus.rssi)) bat=\(deviceStatus.batPercentage)% batV=\(deviceStatus.batVoltage) mute=\(deviceStatus.buzmute) sw=\(deviceStatus.softwareVersion)", category: .ble, level: .debug)
            }
            
        case "1":
            // Probe Telemetry
            if let telemetry = parseType1Message(components) {
                if telemetry.latitude == 0.0 && telemetry.longitude == 0.0 {
                    return // Skip invalid coordinates
                }
                
                appLog("BLE PARSED: Type=1 probe=\(telemetry.probeType) freq=\(telemetry.frequency) sonde=\(telemetry.sondeName) lat=\(telemetry.latitude) lon=\(telemetry.longitude) alt=\(Int(telemetry.altitude))m hspd=\(telemetry.horizontalSpeed) vspd=\(telemetry.verticalSpeed) rssi=\(Int(telemetry.signalStrength)) bat=\(telemetry.batteryPercentage)% afc=\(telemetry.afcFrequency) burst=\(telemetry.burstKillerEnabled) burstTime=\(telemetry.burstKillerTime) batV=\(telemetry.batVoltage) mute=\(telemetry.buzmute) sw=\(telemetry.firmwareVersion)", category: .ble, level: .debug)
                
                DispatchQueue.main.async {
                    self.latestTelemetry = telemetry
                    self.lastTelemetryUpdateTime = Date()
                    self.telemetryData.send(telemetry)
                    
                    // Publish telemetry event to EventBus
                    let telemetryEvent = TelemetryEvent(telemetryData: telemetry)
                    DispatchQueue.main.async {
                        EventBus.shared.publishTelemetry(telemetryEvent)
                    }
                    
                    // Device settings request is handled by the connection ready callback
                    // No need to request again here
                }
            }
            
        case "2":
            // Name Only
            if let nameOnly = parseType2Message(components) {
                appLog("BLE PARSED: Type=2 probe=\(nameOnly.probeType) freq=\(nameOnly.frequency) sonde=\(nameOnly.sondeName) rssi=\(Int(nameOnly.rssi)) bat=\(nameOnly.batPercentage)% afc=\(nameOnly.afcFrequency) batV=\(nameOnly.batVoltage) mute=\(nameOnly.buzmute) sw=\(nameOnly.softwareVersion)", category: .ble, level: .debug)
            }
            
        case "3":
            // Device Configuration
            if let settings = parseType3Message(components) {
                appLog("BLE PARSED: Type=3 probe=\(settings.sondeType) freq=\(settings.frequency) callSign=\(settings.callSign) oledSDA=\(settings.oledSDA) oledSCL=\(settings.oledSCL) oledRST=\(settings.oledRST) ledPin=\(settings.ledPin) RS41BW=\(settings.RS41Bandwidth) M20BW=\(settings.M20Bandwidth) M10BW=\(settings.M10Bandwidth) PILOTBW=\(settings.PILOTBandwidth) DFMBW=\(settings.DFMBandwidth) freqCorr=\(settings.frequencyCorrection) batPin=\(settings.batPin) batMin=\(settings.batMin) batMax=\(settings.batMax) batType=\(settings.batType) lcdType=\(settings.lcdType) nameType=\(settings.nameType) buzPin=\(settings.buzPin) sw=\(settings.softwareVersion)", category: .ble, level: .debug)
                DispatchQueue.main.async {
                    self.deviceSettings = settings
                    self.persistenceService.save(deviceSettings: settings)
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
            probeType: components[1],
            frequency: Double(components[2]) ?? 0.0,
            rssi: Double(components[3]) ?? 0.0,
            batPercentage: Int(components[4]) ?? 0,
            batVoltage: Int(components[5]) ?? 0,
            buzmute: components[6] == "1",
            softwareVersion: components[7]
        )
    }
    
    // Type 1: Probe Telemetry
    private func parseType1Message(_ components: [String]) -> TelemetryData? {
        guard components.count >= 20 else { return nil }
        
        let probeType = components[1]
        let frequency = Double(components[2]) ?? 0.0
        let sondeName = components[3]
        let latitude = Double(components[4]) ?? 0.0
        let longitude = Double(components[5]) ?? 0.0
        let altitude = Double(components[6]) ?? 0.0
        let horizontalSpeed = Double(components[7]) ?? 0.0
        let verticalSpeed = Double(components[8]) ?? 0.0
        let rssi = Double(components[9]) ?? 0.0
        let batPercentage = Int(components[10]) ?? 0
        let afcFrequency = Int(components[11]) ?? 0
        let burstKillerEnabled = components[12] == "1"
        let burstKillerTime = Int(components[13]) ?? 0
        let batVoltage = Int(components[14]) ?? 0
        let buzmute = components[15] == "1"
        let _ = Int(components[16]) ?? 0  // reserved1
        let _ = Int(components[17]) ?? 0  // reserved2
        let _ = Int(components[18]) ?? 0  // reserved3
        let softwareVersion = components[19]
        
        var telemetryData = TelemetryData()
        telemetryData.probeType = probeType
        telemetryData.frequency = frequency
        telemetryData.sondeName = sondeName
        telemetryData.latitude = latitude
        telemetryData.longitude = longitude
        telemetryData.altitude = altitude
        telemetryData.horizontalSpeed = horizontalSpeed
        telemetryData.verticalSpeed = verticalSpeed
        telemetryData.signalStrength = rssi
        telemetryData.batteryPercentage = batPercentage
        telemetryData.afcFrequency = afcFrequency
        telemetryData.burstKillerEnabled = burstKillerEnabled
        telemetryData.burstKillerTime = burstKillerTime
        telemetryData.batVoltage = batVoltage
        telemetryData.buzmute = buzmute
        telemetryData.firmwareVersion = softwareVersion
        telemetryData.lastUpdateTime = Date().timeIntervalSince1970
        
        return telemetryData
    }
    
    // Type 2: Name Only
    private func parseType2Message(_ components: [String]) -> NameOnlyData? {
        guard components.count >= 10 else { return nil }
        
        return NameOnlyData(
            probeType: components[1],
            frequency: Double(components[2]) ?? 0.0,
            sondeName: components[3],
            rssi: Double(components[4]) ?? 0.0,
            batPercentage: Int(components[5]) ?? 0,
            afcFrequency: Int(components[6]) ?? 0,
            batVoltage: Int(components[7]) ?? 0,
            buzmute: components[8] == "1",
            softwareVersion: components[9]
        )
    }

    // Type 3: Device Configuration
    private func parseType3Message(_ components: [String]) -> DeviceSettings? {
        guard components.count >= 22 else { return nil }
        
        let probeType = components[1]
        let frequency = Double(components[2]) ?? 0.0
        let oledSDA = Int(components[3]) ?? 0
        let oledSCL = Int(components[4]) ?? 0
        let oledRST = Int(components[5]) ?? 0
        let ledPin = Int(components[6]) ?? 0
        let RS41Bandwidth = Int(components[7]) ?? 0
        let M20Bandwidth = Int(components[8]) ?? 0
        let M10Bandwidth = Int(components[9]) ?? 0
        let PILOTBandwidth = Int(components[10]) ?? 0
        let DFMBandwidth = Int(components[11]) ?? 0
        let callSign = components[12]
        let frequencyCorrection = Int(components[13]) ?? 0
        let batPin = Int(components[14]) ?? 0
        let batMin = Int(components[15]) ?? 0
        let batMax = Int(components[16]) ?? 0
        let batType = Int(components[17]) ?? 0
        let lcdType = Int(components[18]) ?? 0
        let nameType = Int(components[19]) ?? 0
        let buzPin = Int(components[20]) ?? 0
        let softwareVersion = components[21]
        
        return DeviceSettings(
            sondeType: probeType,
            frequency: frequency,
            oledSDA: oledSDA,
            oledSCL: oledSCL,
            oledRST: oledRST,
            ledPin: ledPin,
            RS41Bandwidth: RS41Bandwidth,
            M20Bandwidth: M20Bandwidth,
            M10Bandwidth: M10Bandwidth,
            PILOTBandwidth: PILOTBandwidth,
            DFMBandwidth: DFMBandwidth,
            callSign: callSign,
            frequencyCorrection: frequencyCorrection,
            batPin: batPin,
            batMin: batMin,
            batMax: batMax,
            batType: batType,
            lcdType: lcdType,
            nameType: nameType,
            buzPin: buzPin,
            softwareVersion: softwareVersion
        )
    }

    // MARK: - MySondyGo Command Interface
    
    /// MySondyGo probe type constants
    enum ProbeType: Int, CaseIterable {
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
    }
    
    /// MySondyGo bandwidth values (see specification)
    enum Bandwidth: Int, CaseIterable {
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

    private func publishHealthEvent(_ health: ServiceHealth, message: String) {
        serviceHealth = health
        EventBus.shared.publishServiceHealth(ServiceHealthEvent(
            serviceName: "BLECommunicationService",
            health: health,
            message: message
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
    private var lastLocationTime: Date? = nil
    private var lastLocationUpdate: Date? = nil
    private var currentBalloonPosition: CLLocationCoordinate2D?
    private var currentProximityMode: ProximityMode = .far
    private var cancellables = Set<AnyCancellable>()
    
    // GPS configuration based on proximity to balloon per specification
    enum ProximityMode {
        case close  // <100m from balloon - Highest GPS precision, no movement threshold, 1Hz max
        case far    // >100m from balloon - Reasonable precision, 5m movement threshold
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
        // Subscribe to telemetry events to track balloon position
        EventBus.shared.telemetryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.updateBalloonPosition(event.telemetryData)
            }
            .store(in: &cancellables)
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
        if distance < 100 { // <100m - CLOSE MODE per specification
            newMode = .close
        } else { // >100m - FAR MODE per specification
            newMode = .far
        }
        
        if newMode != currentProximityMode {
            currentProximityMode = newMode
            configureGPSForMode(newMode)
            
            let modeString = newMode == .close ? "CLOSE" : "FAR"
            appLog("CurrentLocationService: Switched to \(modeString) RANGE GPS (distance: \(Int(distance))m)", category: .service, level: .info)
        }
    }
    
    private func configureGPSForMode(_ mode: ProximityMode) {
        switch mode {
        case .close:
            // CLOSE MODE (<100m): kCLLocationAccuracyBest, no movement threshold, max 1 update/sec
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = kCLDistanceFilterNone // No movement threshold
            appLog("CurrentLocationService: CLOSE MODE - Best accuracy, no distance filter, 1Hz max", category: .service, level: .info)
            
        case .far:
            // FAR MODE (>100m): kCLLocationAccuracyNearestTenMeters, 5m movement threshold
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 5.0 // Only update on 5+ meter movement
            appLog("CurrentLocationService: FAR MODE - 10m accuracy, 5m distance filter", category: .service, level: .info)
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
            
            // Time-based filtering for CLOSE mode (max 1 update per second)
            if self.currentProximityMode == .close {
                if let lastUpdate = self.lastLocationUpdate {
                    let timeSinceLastUpdate = now.timeIntervalSince(lastUpdate)
                    if timeSinceLastUpdate < 1.0 && !isFirstUpdate {
                        // Skip this update - too soon for CLOSE mode
                        return
                    }
                }
            }
            
            // Calculate distance and time differences for filtering
            var distanceDiff: Double = 0
            var timeDiff: TimeInterval = 0
            
            if let previousLocation = self.locationData {
                let prevCLLocation = CLLocation(latitude: previousLocation.latitude, longitude: previousLocation.longitude)
                distanceDiff = location.distance(from: prevCLLocation)
                if let lastTime = self.lastLocationTime {
                    timeDiff = now.timeIntervalSince(lastTime)
                }
            }
            
            // Create new location data
            let newLocationData = LocationData(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                heading: heading
            )
            
            self.locationData = newLocationData
            self.lastLocationTime = now
            self.lastLocationUpdate = now
            
            // Publish location event
            EventBus.shared.publishUserLocation(UserLocationEvent(
                locationData: newLocationData
            ))
            
            if isFirstUpdate {
                appLog("Initial user location: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude)", category: .service, level: .info)
            } else {
                let modeString = self.currentProximityMode == .close ? "CLOSE" : "FAR"
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
        EventBus.shared.publishServiceHealth(ServiceHealthEvent(
            serviceName: "CurrentLocationService",
            health: health,
            message: message
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
        // Subscribe directly to BLE service telemetry stream (most reliable)
        bleService.telemetryData
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
    
    // Landing detection
    @Published var isBalloonFlying: Bool = false
    @Published var isBalloonLanded: Bool = false
    @Published var landingPosition: CLLocationCoordinate2D?
    
    private let persistenceService: PersistenceService
    let balloonPositionService: BalloonPositionService  // Internal access for LandingPointService
    private var cancellables = Set<AnyCancellable>()
    
    // Track management
    private var telemetryPointCounter = 0
    private let saveInterval = 100 // Save every 100 telemetry points
    
    // Landing detection - smoothing buffers
    private var verticalSpeedBuffer: [Double] = []
    private var horizontalSpeedBuffer: [Double] = []
    private var landingPositionBuffer: [CLLocationCoordinate2D] = []
    private let verticalSpeedBufferSize = 20
    private let horizontalSpeedBufferSize = 20
    private let landingPositionBufferSize = 100
    
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
        
        let trackPoint = BalloonTrackPoint(telemetryData: telemetryData)
        
        currentBalloonTrack.append(trackPoint)
        
        // Calculate effective descent rate from track history
        updateEffectiveDescentRate()
        
        // Update landing detection
        updateLandingDetection(telemetryData)
        
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
        let timestamps = recentPoints.map { $0.timestamp.timeIntervalSince1970 }
        
        // Simple linear regression for descent rate
        let n = Double(altitudes.count)
        let sumX = timestamps.reduce(0, +)
        let sumY = altitudes.reduce(0, +)
        let sumXY = zip(timestamps, altitudes).map { $0 * $1 }.reduce(0, +)
        let sumXX = timestamps.map { $0 * $0 }.reduce(0, +)
        
        let denominator = n * sumXX - sumX * sumX
        if denominator != 0 {
            let slope = (n * sumXY - sumX * sumY) / denominator
            currentEffectiveDescentRate = slope // m/s
        }
    }
    
    private func updateLandingDetection(_ telemetryData: TelemetryData) {
        // Update speed buffers for smoothing
        verticalSpeedBuffer.append(telemetryData.verticalSpeed)
        if verticalSpeedBuffer.count > verticalSpeedBufferSize {
            verticalSpeedBuffer.removeFirst()
        }
        
        horizontalSpeedBuffer.append(telemetryData.horizontalSpeed)
        if horizontalSpeedBuffer.count > horizontalSpeedBufferSize {
            horizontalSpeedBuffer.removeFirst()
        }
        
        // Update position buffer for landing position smoothing
        let currentPosition = CLLocationCoordinate2D(latitude: telemetryData.latitude, longitude: telemetryData.longitude)
        landingPositionBuffer.append(currentPosition)
        if landingPositionBuffer.count > landingPositionBufferSize {
            landingPositionBuffer.removeFirst()
        }
        
        // Check if we have telemetry signal (within last 3 seconds)
        let hasRecentTelemetry = Date().timeIntervalSince(telemetryData.lastUpdateTime.map { Date(timeIntervalSince1970: $0) } ?? Date.distantPast) < 3.0
        
        // Calculate smoothed speeds
        let smoothedVerticalSpeed = verticalSpeedBuffer.count >= 20 ? verticalSpeedBuffer.reduce(0, +) / Double(verticalSpeedBuffer.count) : telemetryData.verticalSpeed
        let smoothedHorizontalSpeedKmh = horizontalSpeedBuffer.count >= 20 ? (horizontalSpeedBuffer.reduce(0, +) / Double(horizontalSpeedBuffer.count)) * 3.6 : telemetryData.horizontalSpeed * 3.6 // Convert m/s to km/h
        
        // Landing detection criteria from specification:
        // - Telemetry signal available during last 3 seconds
        // - Smoothed (20) vertical speed < 2 m/s
        // - Smoothed (20) horizontal speed < 2 km/h
        let isLandedNow = hasRecentTelemetry && 
                         abs(smoothedVerticalSpeed) < 2.0 && 
                         smoothedHorizontalSpeedKmh < 2.0
        
        // Update balloon flying/landed state
        let wasPreviouslyFlying = isBalloonFlying
        isBalloonFlying = hasRecentTelemetry && !isLandedNow
        
        if !isBalloonLanded && isLandedNow {
            // Balloon just landed
            isBalloonLanded = true
            
            // Use smoothed (100) position for landing point
            if landingPositionBuffer.count >= 50 { // Use at least 50 points for reasonable smoothing
                let avgLat = landingPositionBuffer.map { $0.latitude }.reduce(0, +) / Double(landingPositionBuffer.count)
                let avgLon = landingPositionBuffer.map { $0.longitude }.reduce(0, +) / Double(landingPositionBuffer.count)
                landingPosition = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            } else {
                landingPosition = currentPosition
            }
            
            appLog("BalloonTrackService: Balloon LANDED detected - vSpeed: \(smoothedVerticalSpeed)m/s, hSpeed: \(smoothedHorizontalSpeedKmh)km/h at \(landingPosition!)", category: .service, level: .info)
            
            // Publish landing event
            EventBus.shared.publishBalloonLanding(BalloonLandingEvent(
                landingPosition: landingPosition!,
                landingTime: Date(),
                sondeName: telemetryData.sondeName
            ))
        } else if wasPreviouslyFlying && isBalloonFlying {
            appLog("BalloonTrackService: Balloon FLYING - vSpeed: \(smoothedVerticalSpeed)m/s, hSpeed: \(smoothedHorizontalSpeedKmh)km/h", category: .service, level: .debug)
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
    
    // Auto-adjustment tracking
    private var descentRateBuffer: [Double] = []
    private let descentRateBufferSize = 20
    @Published var balloonDescends: Bool = false
    @Published var adjustedDescentRate: Double = 5.0 // Default 5 m/s
    
    init() {
        appLog("PredictionService: Initialized with auto-adjustments", category: .service, level: .info)
        publishHealthEvent(.healthy, message: "Prediction service initialized")
    }
    
    func fetchPrediction(telemetry: TelemetryData, userSettings: UserSettings, measuredDescentRate: Double, cacheKey: String) async throws -> PredictionData {
        appLog("PredictionService: Starting prediction fetch for \(telemetry.sondeName) at altitude \(telemetry.altitude)m", category: .service, level: .info)
        
        // Update auto-adjustments based on telemetry
        updateAutoAdjustments(telemetry: telemetry)
        
        // Use adjusted descent rate for API call
        let finalDescentRate = balloonDescends ? adjustedDescentRate : abs(measuredDescentRate)
        
        // Adjust burst altitude if balloon is descending
        let adjustedBurstAltitude = balloonDescends ? (telemetry.altitude + 10) : userSettings.burstAltitude
        
        let url = buildPredictionURL(telemetry: telemetry, userSettings: userSettings, descentRate: finalDescentRate, burstAltitude: adjustedBurstAltitude)
        
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
            
            let landingPointDesc = landingPoint.map { "(\($0.latitude), \($0.longitude))" } ?? "nil"
            let burstPointDesc = burstPoint.map { "(\($0.latitude), \($0.longitude))" } ?? "nil"
            appLog("PredictionService: Prediction completed successfully - Landing point: \(landingPointDesc), Burst point: \(burstPointDesc)", category: .service, level: .info)
            
            publishHealthEvent(.healthy, message: "Prediction successful")
            return predictionData
            
        } catch {
            appLog("PredictionService: Prediction failed with error: \(error.localizedDescription)", category: .service, level: .error)
            publishHealthEvent(.unhealthy, message: "Prediction failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func updateAutoAdjustments(telemetry: TelemetryData) {
        // Detect balloon descent (negative vertical speed)
        let wasDescending = balloonDescends
        balloonDescends = telemetry.verticalSpeed < 0
        
        if !wasDescending && balloonDescends {
            appLog("PredictionService: Balloon descent detected - switching to descent mode", category: .service, level: .info)
        }
        
        // Update descent rate buffer for smoothing (only if balloon is descending and below 10000m)
        if balloonDescends && telemetry.altitude < 10000 {
            descentRateBuffer.append(abs(telemetry.verticalSpeed))
            if descentRateBuffer.count > descentRateBufferSize {
                descentRateBuffer.removeFirst()
            }
            
            // Calculate smoothed descent rate (20 values)
            if descentRateBuffer.count >= 20 {
                adjustedDescentRate = descentRateBuffer.reduce(0, +) / Double(descentRateBuffer.count)
                appLog("PredictionService: Adjusted descent rate: \(String(format: "%.1f", adjustedDescentRate)) m/s (smoothed over \(descentRateBuffer.count) values)", category: .service, level: .debug)
            }
        }
    }
    
    private func buildPredictionURL(telemetry: TelemetryData, userSettings: UserSettings, descentRate: Double, burstAltitude: Double) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "predict.cusf.co.uk"
        components.path = "/api/v1"
        
        let queryItems = [
            URLQueryItem(name: "launch_latitude", value: String(telemetry.latitude)),
            URLQueryItem(name: "launch_longitude", value: String(telemetry.longitude)),
            URLQueryItem(name: "launch_altitude", value: String(telemetry.altitude)),
            URLQueryItem(name: "launch_datetime", value: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))), // +1 minute per spec
            URLQueryItem(name: "ascent_rate", value: String(userSettings.ascentRate)),
            URLQueryItem(name: "burst_altitude", value: String(burstAltitude)), // Use adjusted burst altitude
            URLQueryItem(name: "descent_rate", value: String(abs(descentRate))) // Use adjusted descent rate
        ]
        
        components.queryItems = queryItems
        return components.url!
    }
    
    private func publishHealthEvent(_ health: ServiceHealth, message: String) {
        serviceHealth = health
        EventBus.shared.publishServiceHealth(ServiceHealthEvent(
            serviceName: "PredictionService",
            health: health,
            message: message
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
        
        // Transport mode per FSD: Use .cycling for bike, .automobile for car
        request.transportType = transportMode == .car ? .automobile : .cycling
        
        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        
        guard let route = response.routes.first else {
            throw RouteError.noRouteFound
        }
        
        // Apply 30% time reduction for bicycle mode per FSD requirement
        let adjustedTravelTime = transportMode == .bike ? route.expectedTravelTime * 0.7 : route.expectedTravelTime
        
        return RouteData(
            path: route.polyline.coordinates,
            distance: route.distance,
            expectedTravelTime: adjustedTravelTime
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
        // Don't call updateLandingPointPriorities() during init - let events trigger it naturally
        appLog("LandingPointService: Initialized, waiting for events to determine landing point priorities", category: .service, level: .info)
    }
    
    private func setupSubscriptions() {
        // Subscribe to balloon landing events (Priority 1)
        EventBus.shared.balloonLandingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (landingEvent: BalloonLandingEvent) in
                self?.handleBalloonLanding(landingEvent)
            }
            .store(in: &cancellables)
            
        // Subscribe to prediction updates (Priority 2)
        EventBus.shared.mapStateUpdatePublisher
            .filter { $0.predictionData != nil }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                if let predictionData = update.predictionData {
                    self?.handleNewPrediction(predictionData)
                }
            }
            .store(in: &cancellables)
            
        // Subscribe to telemetry availability events for startup decision only
        EventBus.shared.telemetryAvailabilityPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] availabilityEvent in
                appLog("LandingPointService: Startup telemetry availability - \(availabilityEvent.isAvailable) (\(availabilityEvent.reason))", category: .service, level: .info)
                // Simple startup rule: if no telemetry available, clipboard is OK
                if !availabilityEvent.isAvailable {
                    self?.updateLandingPointPriorities()
                }
                // If telemetry IS available, wait for actual telemetry events to trigger updates
            }
            .store(in: &cancellables)
            
        // Subscribe to telemetry events to trigger priority evaluation when balloon state changes (after availability is determined)
        EventBus.shared.telemetryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // When telemetry becomes available, re-evaluate landing point priorities
                self?.updateLandingPointPriorities()
            }
            .store(in: &cancellables)
    }
    
    private func handleBalloonLanding(_ landingEvent: BalloonLandingEvent) {
        appLog("LandingPointService: Priority 1 - Balloon landing detected at \(landingEvent.landingPosition)", category: .service, level: .info)
        
        // Priority 1: Use actual landing position from Track Management Service
        validLandingPoint = landingEvent.landingPosition
        
        // Persist the confirmed landing point
        persistenceService.saveLandingPoint(sondeName: landingEvent.sondeName, coordinate: landingEvent.landingPosition)
        appLog("LandingPointService: Priority 1 - Persisted confirmed landing point for \(landingEvent.sondeName)", category: .service, level: .info)
    }
    
    private func handleNewPrediction(_ predictionData: PredictionData) {
        guard let newLandingPoint = predictionData.landingPoint else {
            appLog("LandingPointService: Prediction data has no landing point", category: .service, level: .debug)
            return
        }
        
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
        // STARTUP SIMPLE RULE: Check if we have ANY telemetry at all
        let hasTelemetry = balloonTrackService.balloonPositionService.hasReceivedTelemetry
        
        // Priority 1: Landed balloon position from Track Management Service
        if balloonTrackService.isBalloonLanded, let landingPos = balloonTrackService.landingPosition {
            validLandingPoint = landingPos
            appLog("LandingPointService: Priority 1 - Balloon landed at \(landingPos)", category: .service, level: .info)
            
        } else if hasTelemetry {
            // Priority 2: We have telemetry - don't use clipboard, wait for prediction or landing detection
            appLog("LandingPointService: Priority 2 - Telemetry available, waiting for prediction or landing detection", category: .service, level: .debug)
            // Don't set validLandingPoint - wait for prediction service
            
        } else if let clipboardLanding = parseClipboardForLandingPoint() {
            // Priority 3: No telemetry - clipboard is OK
            validLandingPoint = clipboardLanding
            appLog("LandingPointService: Priority 3 - No telemetry available, using clipboard", category: .service, level: .info)
            
        } else {
            // Priority 4: Persisted landing point from previous sessions
            appLog("LandingPointService: No clipboard data available, checking Priority 4 - Persisted data", category: .service, level: .debug)
            checkPersistedLandingPoint()
        }
    }
    
    func setLandingPointFromClipboard() -> Bool {
        appLog("LandingPointService: Attempting to set landing point from clipboard", category: .service, level: .info)
        if let clipboardLanding = parseClipboardForLandingPoint() {
            validLandingPoint = clipboardLanding
            
            // Persist the landing point
            if let sondeName = balloonTrackService.currentBalloonName {
                persistenceService.saveLandingPoint(sondeName: sondeName, coordinate: clipboardLanding)
                appLog("LandingPointService: Successfully set and persisted landing point from clipboard", category: .service, level: .info)
            }
            return true
        }
        return false
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
            appLog("LandingPointService: No clipboard content available", category: .service, level: .debug)
            return nil
        }
        
        // First validate that clipboard content looks like a URL
        let trimmedString = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedString.hasPrefix("http://") || trimmedString.hasPrefix("https://") else {
            appLog("LandingPointService: Clipboard content is not a URL (no http/https prefix)", category: .service, level: .debug)
            return nil
        }
        
        // Check if it's an OpenStreetMap URL (expected format per FSD)
        guard trimmedString.contains("openstreetmap.org") else {
            appLog("LandingPointService: URL is not an OpenStreetMap URL as expected per FSD", category: .service, level: .debug)
            return nil
        }
        
        appLog("LandingPointService: Attempting to parse clipboard URL: '\(trimmedString)'", category: .service, level: .debug)
        
        // Try to parse as URL with coordinates
        if let url = URL(string: trimmedString),
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
                case "route":
                    // Parse OpenStreetMap route format: "47.4738%2C7.75929%3B47.4987%2C7.667"
                    // Second coordinate (after %3B which is ";") is the landing point
                    if let routeValue = item.value {
                        let decodedRoute = routeValue.removingPercentEncoding ?? routeValue
                        let coordinates = decodedRoute.components(separatedBy: ";")
                        if coordinates.count >= 2 {
                            let landingCoordParts = coordinates[1].components(separatedBy: ",")
                            if landingCoordParts.count == 2 {
                                lat = Double(landingCoordParts[0])
                                lon = Double(landingCoordParts[1])
                                appLog("LandingPointService: Parsed OpenStreetMap route format: \(landingCoordParts[0]), \(landingCoordParts[1])", category: .service, level: .debug)
                            }
                        }
                    }
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

// BalloonPositionEvent is now defined in EventSystem.swift


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