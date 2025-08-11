//
//  BLEManager.swift
//  BalloonHunter
//
//  Created by Assistant on 2025-08-10.
//

import Foundation
import CoreBluetooth
import Combine

private let bleDebug = true

public protocol BLEManagerDelegate: AnyObject {
    func bleManager(_ manager: BLEManager, didUpdateTelemetry telemetry: TelemetryPacket)
    func bleManager(_ manager: BLEManager, didUpdateDeviceSettings settings: BLEDeviceSettingsModel)
    func bleManager(_ manager: BLEManager, didChangeState state: BLEManager.ConnectionState)
}

public final class BLEManager: NSObject, ObservableObject {
    // MARK: - BLE Constants
    
    public static let uartServiceUUID = CBUUID(string: "53797269-614D-6972-6B6F-44616C6D6F6E")
    public static let uartRXCharacteristicUUID = CBUUID(string: "53797269-614D-6972-6B6F-44616C6D6F62") // Peripheral -> Central (Notify)
    public static let uartTXCharacteristicUUID = CBUUID(string: "53797269-614D-6972-6B6F-44616C6D6F61") // Central -> Peripheral (Write)
    
    // Device name to scan for (substring match)
    private let targetDeviceName = "MySondyGo"
    
    // MARK: - Public Types
    
    public enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case connecting
        case connected
        case ready
        case failed(Error)
        
        public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.scanning, .scanning),
                 (.connecting, .connecting),
                 (.connected, .connected),
                 (.ready, .ready):
                return true
            case let (.failed(lhsError), .failed(rhsError)):
                // Compare errors by their localized descriptions
                return (lhsError as NSError).localizedDescription == (rhsError as NSError).localizedDescription
            default:
                return false
            }
        }
    }
    
    // MARK: - Published Properties
    
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var telemetry: TelemetryPacket?
    @Published public private(set) var deviceSettings: BLEDeviceSettingsModel?
    
    // MARK: - Private Properties
    
    private var centralManager: CBCentralManager!
    private var uartPeripheral: CBPeripheral?
    private var uartRXCharacteristic: CBCharacteristic? // Notify from peripheral
    private var uartTXCharacteristic: CBCharacteristic? // Write to peripheral
    
    private var isScanning = false
    private var reconnectTimer: Timer?
    
    /// Buffer for incoming UART ASCII data fragments
    private var incomingStringBuffer = ""
    
    private let packetDispatchQueue = DispatchQueue(label: "com.balloonhunter.ble.packetDispatchQueue")
    
    private var cancellables = Set<AnyCancellable>()
    
    // Delegate for integrating with MainViewModel and PersistenceService
    public weak var delegate: BLEManagerDelegate?
    
    // Flag to track if device is ready after first telemetry
    private var hasReportedReady = false
    
    // MARK: - Initialization
    
    public override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    deinit {
        disconnect()
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }
    
    // MARK: - Public API
    
    /// Start scanning and connect to target device
    public func connect() {
        Task { @MainActor in
            if bleDebug { print("[BLE] connect() called") }
            switch connectionState {
            case .scanning, .connecting, .connected, .ready:
                if bleDebug { print("[BLE] Already scanning/connecting/connected/ready. connect() ignored.") }
                return
            default:
                break
            }
            guard centralManager.state == .poweredOn else {
                if bleDebug { print("[BLE] Bluetooth not powered on, failing connect") }
                connectionState = .failed(BLEError.bluetoothPoweredOff)
                return
            }
            startScanning()
        }
    }
    
    /// Disconnect from current device and stop scanning
    public func disconnect() {
        if bleDebug { print("[BLE] disconnect() called") }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        
        if let peripheral = uartPeripheral {
            if bleDebug { print("[BLE] Cancelling peripheral connection") }
            centralManager.cancelPeripheralConnection(peripheral)
        }
        uartPeripheral = nil
        uartRXCharacteristic = nil
        uartTXCharacteristic = nil
        
        connectionState = .disconnected
        incomingStringBuffer.removeAll()
        hasReportedReady = false
    }
    
    /// Send data to peripheral UART TX characteristic
    /// - Parameter data: Data to send
    public func send(data: Data) {
        guard let peripheral = uartPeripheral,
              let txChar = uartTXCharacteristic else { return }
        
        // Write with response for UART TX characteristic (Central -> Peripheral)
        peripheral.writeValue(data, for: txChar, type: .withResponse)
    }
    
    /// Get latest telemetry data if available
    public func getLatestTelemetry() -> TelemetryPacket? {
        telemetry
    }
    
    /// Get latest device settings if available
    public func getLatestDeviceSettings() -> BLEDeviceSettingsModel? {
        deviceSettings
    }
    
    // MARK: - Private Methods
    
    private func startScanning() {
        guard !isScanning else { return }
        if bleDebug { print("[BLE] startScanning() called") }
        
        connectionState = .scanning
        isScanning = true
        
        centralManager.scanForPeripherals(withServices: [Self.uartServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    
    private func stopScanning() {
        guard isScanning else { return }
        if bleDebug { print("[BLE] stopScanning() called") }
        centralManager.stopScan()
        isScanning = false
    }
    
    private func scheduleReconnect(delay: TimeInterval = 5.0) {
        if bleDebug { print("[BLE] scheduleReconnect() called, scheduling reconnect in \(delay) seconds") }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            if bleDebug { print("[BLE] reconnectTimer fired, attempting to reconnect") }
            self?.connect()
        }
    }
    
    /// Called on receiving new data from UART RX characteristic (peripheral -> central)
    private func handleIncomingData(_ data: Data) {
        packetDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let stringFragment = String(data: data, encoding: .utf8) {
                // if bleDebug { print("[BLE] Received ASCII fragment: '\(stringFragment)'") }
                self.incomingStringBuffer += stringFragment
                self.processIncomingLines()
            } else {
                if bleDebug { print("[BLE] Received data but failed UTF-8 decode: \(data as NSData)") }
            }
        }
    }
    
    /// Process the incomingStringBuffer to extract complete messages delimited by "/o"
    private func processIncomingLines() {
        while true {
            guard let delimiterRange = incomingStringBuffer.range(of: "/o") else {
                // No complete message yet
                return
            }
            
            let completeMessage = String(incomingStringBuffer[..<delimiterRange.lowerBound])
            incomingStringBuffer = String(incomingStringBuffer[delimiterRange.upperBound...])
            
            // if bleDebug { print("[BLE] Processing complete ASCII message: '\(completeMessage)'") }
            parsePacket(rawLine: completeMessage)
        }
    }
    
    /// Parse a full raw ASCII message line, dispatching by type to specific parsers
    private func parsePacket(rawLine: String) {
        let fields = rawLine.components(separatedBy: "/")
        guard !fields.isEmpty else {
            if bleDebug { print("[BLE] parsePacket() called with empty line") }
            return
        }
        
        let packetType = fields[0]
        
        switch packetType {
        case "0":
            guard let packet = parseType0(fields) else {
                if bleDebug { print("[BLE] Failed to parse type 0 packet: \(fields)") }
                return
            }
            if bleDebug {
                print("[BLE][Parse] Parsed type 0 packet: \(packet)")
            }
            // No action currently for type 0
            
        case "1":
            guard let packet = parseType1(fields) else {
                if bleDebug { print("[BLE] Failed to parse type 1 (telemetry) packet: \(fields)") }
                return
            }
            if bleDebug {
                print("[BLE][Parse] Parsed telemetry: \(packet)")
            }
            let telemetry = TelemetryPacket(
                altitude: packet.altitude,
                temperature: packet.temperature,
                batteryVoltage: packet.batteryVoltage,
                ascentRate: packet.ascentRate,
                altitudeRaw: packet.altitudeRaw
            )
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.telemetry = telemetry
                self.delegate?.bleManager(self, didUpdateTelemetry: telemetry)
                
                if !self.hasReportedReady && (self.connectionState == .connected || self.connectionState == .ready) {
                    self.hasReportedReady = true
                    self.connectionState = .ready
                    self.delegate?.bleManager(self, didChangeState: .ready)
                }
            }
            
        case "2":
            guard let packet = parseType2(fields) else {
                if bleDebug { print("[BLE] Failed to parse type 2 packet: \(fields)") }
                return
            }
            if bleDebug {
                print("[BLE][Parse] Parsed type 2 packet: \(packet)")
            }
            // No action currently for type 2
            
        case "3":
            guard let packet = parseType3(fields) else {
                if bleDebug { print("[BLE] Failed to parse type 3 (device settings) packet: \(fields)") }
                return
            }
            if bleDebug {
                print("[BLE][Parse] Parsed device settings packet: \(packet)")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.deviceSettings = packet
                self.delegate?.bleManager(self, didUpdateDeviceSettings: packet)
            }
            
        default:
            if bleDebug {
                print("[BLE] Unknown ASCII packet type '\(packetType)', full line: \(fields)")
            }
        }
    }
    
    // MARK: - Packet Types
    
    /// Type 0 Packet: Device basic info and status
    /// Fields:
    /// 0: "0" (packet type)
    /// 1: probeType (String)
    /// 2: frequency (Double)
    /// 3: RSSI (Double)
    /// 4: batPercentage (Int)
    /// 5: batVoltage (Int)
    /// 6: buzmute (Bool; 1=true, 0=false)
    /// 7: softwareVersion (String)
    public struct Type0Packet: CustomStringConvertible {
        public let probeType: String
        public let frequency: Double
        public let rssi: Double
        public let batPercentage: Int
        public let batVoltage: Int
        public let buzmute: Bool
        public let softwareVersion: String
        
        public var description: String {
            "Type0Packet(probeType: \(probeType), frequency: \(frequency), rssi: \(rssi), batPercentage: \(batPercentage), batVoltage: \(batVoltage), buzmute: \(buzmute), softwareVersion: \(softwareVersion))"
        }
    }
    
    private func parseType0(_ fields: [String]) -> Type0Packet? {
        guard fields.count >= 8 else {
            if bleDebug { print("[BLE][Parse] Type0 packet insufficient fields, got \(fields.count), need at least 8") }
            return nil
        }
        
        func doubleAt(_ idx: Int) -> Double? {
            guard idx < fields.count else { return nil }
            if let val = Double(fields[idx]) {
                return val
            }
            if bleDebug { print("[BLE][Parse] Failed to parse Double at index \(idx) from '\(fields[idx])'") }
            return nil
        }
        func intAt(_ idx: Int) -> Int? {
            guard idx < fields.count else { return nil }
            if let val = Int(fields[idx]) {
                return val
            }
            if bleDebug { print("[BLE][Parse] Failed to parse Int at index \(idx) from '\(fields[idx])'") }
            return nil
        }
        func boolAt(_ idx: Int) -> Bool {
            guard idx < fields.count else { return false }
            if let val = Int(fields[idx]) {
                return val == 1
            }
            if bleDebug { print("[BLE][Parse] Failed to parse Bool at index \(idx) from '\(fields[idx])'") }
            return false
        }
        func stringAt(_ idx: Int) -> String {
            guard idx < fields.count else { return "" }
            return fields[idx]
        }
        
        let probeType = stringAt(1)
        
        guard let frequency = doubleAt(2) else { return nil }
        guard let rssi = doubleAt(3) else { return nil }
        guard let batPercentage = intAt(4) else { return nil }
        guard let batVoltage = intAt(5) else { return nil }
        let buzmute = boolAt(6)
        let softwareVersion = stringAt(7)
        
        return Type0Packet(
            probeType: probeType,
            frequency: frequency,
            rssi: rssi,
            batPercentage: batPercentage,
            batVoltage: batVoltage,
            buzmute: buzmute,
            softwareVersion: softwareVersion
        )
    }
    
    /// Type 1 Packet: Telemetry data packet
    /// Fields:
    /// 0: "1" (packet type)
    /// 1: ascentRate (Float)
    /// 2: groundSpeed (Double)
    /// 3: altitudeRaw (UInt32)
    /// 4: altitudeFiltered (Double)
    /// 5: latitude (Double)
    /// 6: altitude (Double)
    /// 7: temperature (Double)
    /// 8: humidity (Double)
    /// 9: pressure (Double)
    /// 10: windSpeed (Double)
    /// 11: windDirection (Double)
    /// 12: gpsSats (Int)
    /// 13: fixType (Int)
    /// 14: batteryVoltage (Double)
    /// 15: buzMute (Bool, from Int)
    /// 16: burstKillerEnabled (Bool, from Int)
    /// 17: unknownSetting18 (Int)
    /// 18: unknownSetting19 (Int)
    /// 19: unknownSetting20 (Int)
    public struct Type1Packet: CustomStringConvertible {
        public let ascentRate: Float
        public let groundSpeed: Double
        public let altitudeRaw: UInt32
        public let altitudeFiltered: Double
        public let latitude: Double
        public let altitude: Double
        public let temperature: Double
        public let humidity: Double
        public let pressure: Double
        public let windSpeed: Double
        public let windDirection: Double
        public let gpsSats: Int
        public let fixType: Int
        public let batteryVoltage: Double
        public let buzMute: Bool
        public let burstKillerEnabled: Bool
        public let unknownSetting18: Int
        public let unknownSetting19: Int
        public let unknownSetting20: Int
        
        public var description: String {
            """
            Type1Packet(
                ascentRate: \(ascentRate),
                groundSpeed: \(groundSpeed),
                altitudeRaw: \(altitudeRaw),
                altitudeFiltered: \(altitudeFiltered),
                latitude: \(latitude),
                altitude: \(altitude),
                temperature: \(temperature),
                humidity: \(humidity),
                pressure: \(pressure),
                windSpeed: \(windSpeed),
                windDirection: \(windDirection),
                gpsSats: \(gpsSats),
                fixType: \(fixType),
                batteryVoltage: \(batteryVoltage),
                buzMute: \(buzMute),
                burstKillerEnabled: \(burstKillerEnabled),
                unknownSetting18: \(unknownSetting18),
                unknownSetting19: \(unknownSetting19),
                unknownSetting20: \(unknownSetting20)
            )
            """
        }
    }
    
    private func parseType1(_ fields: [String]) -> Type1Packet? {
        guard fields.count >= 20 else {
            if bleDebug { print("[BLE][Parse] Type1 packet insufficient fields, got \(fields.count), need at least 20") }
            return nil
        }
        func intAt(_ idx: Int) -> Int? {
            guard idx < fields.count else { return nil }
            if let val = Int(fields[idx]) { return val }
            if bleDebug { print("[BLE][Parse] Failed to parse Int at index \(idx) from '\(fields[idx])'") }
            return nil
        }
        func uint32At(_ idx: Int) -> UInt32? {
            guard idx < fields.count else { return nil }
            if let val = UInt32(fields[idx]) { return val }
            if bleDebug { print("[BLE][Parse] Failed to parse UInt32 at index \(idx) from '\(fields[idx])'") }
            return nil
        }
        func doubleAt(_ idx: Int) -> Double? {
            guard idx < fields.count else { return nil }
            if let val = Double(fields[idx]) { return val }
            if bleDebug { print("[BLE][Parse] Failed to parse Double at index \(idx) from '\(fields[idx])'") }
            return nil
        }
        func floatAt(_ idx: Int) -> Float? {
            guard idx < fields.count else { return nil }
            if let val = Float(fields[idx]) { return val }
            if bleDebug { print("[BLE][Parse] Failed to parse Float at index \(idx) from '\(fields[idx])'") }
            return nil
        }
        func boolAt(_ idx: Int) -> Bool {
            guard idx < fields.count else { return false }
            if let val = Int(fields[idx]) { return val == 1 }
            if bleDebug { print("[BLE][Parse] Failed to parse Bool at index \(idx) from '\(fields[idx])'") }
            return false
        }
        
        guard let ascentRate = floatAt(1),
              let groundSpeed = doubleAt(2),
              let altitudeRaw = uint32At(3),
              let altitudeFiltered = doubleAt(4),
              let latitude = doubleAt(5),
              let altitude = doubleAt(6),
              let temperature = doubleAt(7),
              let humidity = doubleAt(8),
              let pressure = doubleAt(9),
              let windSpeed = doubleAt(10),
              let windDirection = doubleAt(11),
              let gpsSats = intAt(12),
              let fixType = intAt(13),
              let batteryVoltage = doubleAt(14)
        else {
            return nil
        }
        
        let buzMute = boolAt(15)
        let burstKillerEnabled = boolAt(16)
        let unknownSetting18 = intAt(17) ?? 0
        let unknownSetting19 = intAt(18) ?? 0
        let unknownSetting20 = intAt(19) ?? 0
        
        return Type1Packet(
            ascentRate: ascentRate,
            groundSpeed: groundSpeed,
            altitudeRaw: altitudeRaw,
            altitudeFiltered: altitudeFiltered,
            latitude: latitude,
            altitude: altitude,
            temperature: temperature,
            humidity: humidity,
            pressure: pressure,
            windSpeed: windSpeed,
            windDirection: windDirection,
            gpsSats: gpsSats,
            fixType: fixType,
            batteryVoltage: batteryVoltage,
            buzMute: buzMute,
            burstKillerEnabled: burstKillerEnabled,
            unknownSetting18: unknownSetting18,
            unknownSetting19: unknownSetting19,
            unknownSetting20: unknownSetting20
        )
    }
    
    /// Type 2 Packet: Signal and status info packet
    /// Fields:
    /// 0: "2" (packet type)
    /// 1: sondeName (String)
    /// 2: RSSI (Double)
    /// 3: batVoltage (Int)
    /// 4: burstKillerEnabled (Bool, Int=1/0)
    /// 5: buzmute (Bool, Int=1/0)
    /// 6: 4_5GHz (Bool, Int=1/0)
    /// 7: rssiMax (Double)
    /// 8: rssiMin (Double)
    /// 9: rssiAvg (Double)
    public struct Type2Packet: CustomStringConvertible {
        public let sondeName: String
        public let rssi: Double
        public let batVoltage: Int
        public let burstKillerEnabled: Bool
        public let buzmute: Bool
        public let fourPointFiveGHz: Bool
        public let rssiMax: Double
        public let rssiMin: Double
        public let rssiAvg: Double
        
        public var description: String {
            "Type2Packet(sondeName: \(sondeName), rssi: \(rssi), batVoltage: \(batVoltage), burstKillerEnabled: \(burstKillerEnabled), buzmute: \(buzmute), 4_5GHz: \(fourPointFiveGHz), rssiMax: \(rssiMax), rssiMin: \(rssiMin), rssiAvg: \(rssiAvg))"
        }
    }
    
    private func parseType2(_ fields: [String]) -> Type2Packet? {
        guard fields.count >= 10 else {
            if bleDebug { print("[BLE][Parse] Type2 packet insufficient fields, got \(fields.count), need at least 10") }
            return nil
        }
        
        func doubleAt(_ idx: Int) -> Double? {
            guard idx < fields.count else { return nil }
            if let val = Double(fields[idx]) { return val }
            if bleDebug { print("[BLE][Parse] Failed to parse Double at index \(idx) from '\(fields[idx])'") }
            return nil
        }
        func intAt(_ idx: Int) -> Int? {
            guard idx < fields.count else { return nil }
            if let val = Int(fields[idx]) { return val }
            if bleDebug { print("[BLE][Parse] Failed to parse Int at index \(idx) from '\(fields[idx])'") }
            return nil
        }
        func boolAt(_ idx: Int) -> Bool {
            guard idx < fields.count else { return false }
            if let val = Int(fields[idx]) { return val == 1 }
            if bleDebug { print("[BLE][Parse] Failed to parse Bool at index \(idx) from '\(fields[idx])'") }
            return false
        }
        func stringAt(_ idx: Int) -> String {
            guard idx < fields.count else { return "" }
            return fields[idx]
        }
        
        let sondeName = stringAt(1)
        guard let rssi = doubleAt(2),
              let batVoltage = intAt(3)
        else {
            return nil
        }
        let burstKillerEnabled = boolAt(4)
        let buzmute = boolAt(5)
        let fourPointFiveGHz = boolAt(6)
        
        guard let rssiMax = doubleAt(7),
              let rssiMin = doubleAt(8),
              let rssiAvg = doubleAt(9)
        else {
            return nil
        }
        
        return Type2Packet(
            sondeName: sondeName,
            rssi: rssi,
            batVoltage: batVoltage,
            burstKillerEnabled: burstKillerEnabled,
            buzmute: buzmute,
            fourPointFiveGHz: fourPointFiveGHz,
            rssiMax: rssiMax,
            rssiMin: rssiMin,
            rssiAvg: rssiAvg
        )
    }
    
    /// Type 3 Packet: Device settings packet
    ///
    /// Field order and types:
    /// 0: packet type "3"
    /// 1: probeType (String)
    /// 2: frequency (Double)
    /// 3: oledSDA (UInt8)
    /// 4: oledSCL (UInt8)
    /// 5: oledRST (UInt8)
    /// 6: ledPin (UInt8)
    /// 7: RS41Bandwidth (UInt8)
    /// 8: M20Bandwidth (UInt8)
    /// 9: M10Bandwidth (UInt8)
    /// 10: PILOTBandwidth (UInt8)
    /// 11: DFMBandwidth (UInt8)
    /// 12: callSign (String)
    /// 13: frequencyCorrection (Int)
    /// 14: batPin (UInt16)
    /// 15: batMin (UInt16)
    /// 16: batMax (UInt16)
    /// 17: batType (UInt16)
    /// 18: lcdType (UInt8)
    /// 19: nameType (UInt8)
    /// 20: buzPin (UInt8)
    /// 21: softwareVersion (String)
    private func parseType3(_ fields: [String]) -> BLEDeviceSettingsModel? {
        guard fields.count >= 22 else {
            if bleDebug { print("[BLE][Parse] Device settings packet with insufficient fields (need at least 22): \(fields.count)") }
            return nil
        }
        
        // Helper to parse UInt8 from Int with range check and debug
        func uint8At(_ idx: Int) -> UInt8 {
            guard idx < fields.count else {
                if bleDebug { print("[BLE][Parse] Missing field for UInt8 at index \(idx)") }
                return 0
            }
            if let val = Int(fields[idx]), val >= 0 && val <= 255 {
                return UInt8(val)
            } else {
                if bleDebug { print("[BLE][Parse] Failed to parse UInt8 at index \(idx) from '\(fields[idx])'") }
                return 0
            }
        }
        // Helper to parse UInt16 from Int with range check and debug
        func uint16At(_ idx: Int) -> UInt16 {
            guard idx < fields.count else {
                if bleDebug { print("[BLE][Parse] Missing field for UInt16 at index \(idx)") }
                return 0
            }
            if let val = Int(fields[idx]), val >= 0 && val <= UInt16.max {
                return UInt16(val)
            } else {
                if bleDebug { print("[BLE][Parse] Failed to parse UInt16 at index \(idx) from '\(fields[idx])'") }
                return 0
            }
        }
        // Helper to parse Int with debug
        func intAt(_ idx: Int) -> Int {
            guard idx < fields.count else {
                if bleDebug { print("[BLE][Parse] Missing field for Int at index \(idx)") }
                return 0
            }
            if let val = Int(fields[idx]) {
                return val
            } else {
                if bleDebug { print("[BLE][Parse] Failed to parse Int at index \(idx) from '\(fields[idx])'") }
                return 0
            }
        }
        // Helper to parse Double with debug
        func doubleAt(_ idx: Int) -> Double {
            guard idx < fields.count else {
                if bleDebug { print("[BLE][Parse] Missing field for Double at index \(idx)") }
                return 0.0
            }
            if let val = Double(fields[idx]) {
                return val
            } else {
                if bleDebug { print("[BLE][Parse] Failed to parse Double at index \(idx) from '\(fields[idx])'") }
                return 0.0
            }
        }
        // Helper to parse String safely
        func stringAt(_ idx: Int) -> String {
            guard idx < fields.count else {
                if bleDebug { print("[BLE][Parse] Missing string at index \(idx)") }
                return ""
            }
            return fields[idx]
        }
        
        let probeType = stringAt(1)
        let frequency = doubleAt(2)
        let oledSDA = uint8At(3)
        let oledSCL = uint8At(4)
        let oledRST = uint8At(5)
        let ledPin = uint8At(6)
        let RS41Bandwidth = uint8At(7)
        let M20Bandwidth = uint8At(8)
        let M10Bandwidth = uint8At(9)
        let PILOTBandwidth = uint8At(10)
        let DFMBandwidth = uint8At(11)
        let callSign = stringAt(12)
        let frequencyCorrection = intAt(13)
        let batPin = uint16At(14)
        let batMin = uint16At(15)
        let batMax = uint16At(16)
        let batType = uint16At(17)
        let lcdType = uint8At(18)
        let nameType = uint8At(19)
        let buzPin = uint8At(20)
        let softwareVersion = stringAt(21)
        
        return BLEDeviceSettingsModel(
            probeType: probeType,
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
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if bleDebug { print("[BLE] centralManagerDidUpdateState: poweredOn") }
            // Start scan automatically if not already connecting/connected/scanning/ready
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if case .disconnected = self.connectionState {
                    self.connect()
                }
            }
            break
        case .poweredOff:
            if bleDebug { print("[BLE] centralManagerDidUpdateState: poweredOff") }
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .failed(BLEError.bluetoothPoweredOff)
            }
        case .unauthorized:
            if bleDebug { print("[BLE] centralManagerDidUpdateState: unauthorized") }
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .failed(BLEError.bluetoothUnauthorized)
            }
        case .unsupported:
            if bleDebug { print("[BLE] centralManagerDidUpdateState: unsupported") }
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .failed(BLEError.bluetoothUnsupported)
            }
        default:
            if bleDebug { print("[BLE] centralManagerDidUpdateState: other state \(central.state.rawValue)") }
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .disconnected
            }
        }
    }
    
    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String : Any],
                               rssi RSSI: NSNumber) {
        if bleDebug {
            let name = peripheral.name ?? "Unknown"
            print("[BLE] Discovered peripheral '\(name)' with RSSI \(RSSI)")
        }
        
        guard uartPeripheral == nil else {
            // Already connected to a device, ignore others
            if bleDebug { print("[BLE] Already connected, ignoring discovered peripheral") }
            return
        }
        
        if let name = peripheral.name, name.contains(targetDeviceName) ||
            (advertisementData[CBAdvertisementDataLocalNameKey] as? String)?.contains(targetDeviceName) == true {
            if bleDebug { print("[BLE] Target device found: '\(peripheral.name ?? "Unnamed")', connecting...") }
            stopScanning()
            uartPeripheral = peripheral
            uartPeripheral?.delegate = self
            connectionState = .connecting
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == uartPeripheral else { return }
        if bleDebug { print("[BLE] Connected to peripheral '\(peripheral.name ?? "Unnamed")'") }
        connectionState = .connected
        hasReportedReady = false
        peripheral.discoverServices([Self.uartServiceUUID])
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == uartPeripheral else { return }
        if bleDebug { print("[BLE] Failed to connect to peripheral '\(peripheral.name ?? "Unnamed")': \(error?.localizedDescription ?? "unknown error")") }
        connectionState = .failed(error ?? BLEError.failedToConnect)
        uartPeripheral = nil
        scheduleReconnect()
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == uartPeripheral else { return }
        if bleDebug {
            let errDescription = error?.localizedDescription ?? "nil"
            print("[BLE] Disconnected from peripheral '\(peripheral.name ?? "Unnamed")'. Error: \(errDescription)")
        }
        connectionState = .disconnected
        uartPeripheral = nil
        uartRXCharacteristic = nil
        uartTXCharacteristic = nil
        incomingStringBuffer.removeAll()
        hasReportedReady = false
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            if bleDebug { print("[BLE] Error discovering services: \(error.localizedDescription)") }
            connectionState = .failed(error)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        guard let services = peripheral.services else {
            if bleDebug { print("[BLE] No services found on peripheral") }
            connectionState = .failed(BLEError.noServicesFound)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        if bleDebug { print("[BLE] Discovered services on peripheral: \(services.map { $0.uuid.uuidString })") }
        
        for service in services where service.uuid == Self.uartServiceUUID {
            if bleDebug { print("[BLE] Discovering characteristics for UART service") }
            peripheral.discoverCharacteristics([Self.uartRXCharacteristicUUID, Self.uartTXCharacteristicUUID], for: service)
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error = error {
            if bleDebug { print("[BLE] Error discovering characteristics: \(error.localizedDescription)") }
            connectionState = .failed(error)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        guard let characteristics = service.characteristics else {
            if bleDebug { print("[BLE] No characteristics found on service") }
            connectionState = .failed(BLEError.noCharacteristicsFound)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        if bleDebug { print("[BLE] Discovered characteristics: \(characteristics.map { $0.uuid.uuidString })") }
        
        for char in characteristics {
            if char.uuid == Self.uartRXCharacteristicUUID {
                if bleDebug { print("[BLE] Found UART RX characteristic, enabling notifications") }
                uartRXCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            } else if char.uuid == Self.uartTXCharacteristicUUID {
                if bleDebug { print("[BLE] Found UART TX characteristic") }
                uartTXCharacteristic = char
            }
        }
        
        if uartRXCharacteristic != nil && uartTXCharacteristic != nil {
            if bleDebug { print("[BLE] UART characteristics found, connection ready") }
            connectionState = .ready
        } else {
            if bleDebug { print("[BLE] Required UART characteristics not found, disconnecting") }
            connectionState = .failed(BLEError.requiredCharacteristicsNotFound)
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            if bleDebug { print("[BLE] Error updating notification state: \(error.localizedDescription)") }
            connectionState = .failed(error)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        if bleDebug { print("[BLE] Notification state updated for characteristic \(characteristic.uuid.uuidString)") }
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        // Removed debug print: if bleDebug { print("[BLE] didUpdateValueFor called for characteristic \(characteristic.uuid.uuidString)") }
        
        if let error = error {
            if bleDebug { print("[BLE] Error receiving data: \(error.localizedDescription)") }
            // Log error but do not disconnect immediately
            return
        }
        
        guard let data = characteristic.value else { return }
        
        // Removed debug print: if bleDebug { print("[BLE] Raw incoming data: " + data.map { String(format: "%02X", $0) }.joined(separator: " ")) }
        
        if characteristic.uuid == Self.uartRXCharacteristicUUID {
            handleIncomingData(data)
        }
    }
}

// MARK: - Supporting Models

/// Telemetry data structure containing key sensor readings
public struct TelemetryPacket: Equatable {
    public let altitude: Double
    public let temperature: Double
    public let batteryVoltage: Double
    public let ascentRate: Float
    public let altitudeRaw: UInt32
    
    public init(altitude: Double, temperature: Double, batteryVoltage: Double, ascentRate: Float, altitudeRaw: UInt32) {
        self.altitude = altitude
        self.temperature = temperature
        self.batteryVoltage = batteryVoltage
        self.ascentRate = ascentRate
        self.altitudeRaw = altitudeRaw
    }
}

/// Basic device settings structure (simplified)
public struct BLEDeviceSettings: Equatable {
    public let deviceMode: UInt8
    public let sampleRateHz: Double
    
    public init(deviceMode: UInt8, sampleRateHz: Double) {
        self.deviceMode = deviceMode
        self.sampleRateHz = sampleRateHz
    }
}

/// DeviceSettingsModel matching full specification of type 3 message.
///
/// Fields:
/// - probeType: String identifying the probe type
/// - frequency: Double frequency value (MHz)
/// - oledSDA: UInt8 OLED SDA pin
/// - oledSCL: UInt8 OLED SCL pin
/// - oledRST: UInt8 OLED Reset pin
/// - ledPin: UInt8 LED pin
/// - RS41Bandwidth: UInt8 RS41 bandwidth setting
/// - M20Bandwidth: UInt8 M20 bandwidth setting
/// - M10Bandwidth: UInt8 M10 bandwidth setting
/// - PILOTBandwidth: UInt8 PILOT bandwidth setting
/// - DFMBandwidth: UInt8 DFM bandwidth setting
/// - callSign: String call sign of device
/// - frequencyCorrection: Int frequency correction value
/// - batPin: UInt16 battery pin
/// - batMin: UInt16 battery minimum voltage
/// - batMax: UInt16 battery maximum voltage
/// - batType: UInt16 battery type
/// - lcdType: UInt8 LCD type
/// - nameType: UInt8 name type
/// - buzPin: UInt8 buzzer pin
/// - softwareVersion: String version of software on device
public struct BLEDeviceSettingsModel: Equatable {
    public let probeType: String
    public let frequency: Double
    public let oledSDA: UInt8
    public let oledSCL: UInt8
    public let oledRST: UInt8
    public let ledPin: UInt8
    public let RS41Bandwidth: UInt8
    public let M20Bandwidth: UInt8
    public let M10Bandwidth: UInt8
    public let PILOTBandwidth: UInt8
    public let DFMBandwidth: UInt8
    public let callSign: String
    public let frequencyCorrection: Int
    public let batPin: UInt16
    public let batMin: UInt16
    public let batMax: UInt16
    public let batType: UInt16
    public let lcdType: UInt8
    public let nameType: UInt8
    public let buzPin: UInt8
    public let softwareVersion: String
    
    public init(
        probeType: String,
        frequency: Double,
        oledSDA: UInt8,
        oledSCL: UInt8,
        oledRST: UInt8,
        ledPin: UInt8,
        RS41Bandwidth: UInt8,
        M20Bandwidth: UInt8,
        M10Bandwidth: UInt8,
        PILOTBandwidth: UInt8,
        DFMBandwidth: UInt8,
        callSign: String,
        frequencyCorrection: Int,
        batPin: UInt16,
        batMin: UInt16,
        batMax: UInt16,
        batType: UInt16,
        lcdType: UInt8,
        nameType: UInt8,
        buzPin: UInt8,
        softwareVersion: String
    ) {
        self.probeType = probeType
        self.frequency = frequency
        self.oledSDA = oledSDA
        self.oledSCL = oledSCL
        self.oledRST = oledRST
        self.ledPin = ledPin
        self.RS41Bandwidth = RS41Bandwidth
        self.M20Bandwidth = M20Bandwidth
        self.M10Bandwidth = M10Bandwidth
        self.PILOTBandwidth = PILOTBandwidth
        self.DFMBandwidth = DFMBandwidth
        self.callSign = callSign
        self.frequencyCorrection = frequencyCorrection
        self.batPin = batPin
        self.batMin = batMin
        self.batMax = batMax
        self.batType = batType
        self.lcdType = lcdType
        self.nameType = nameType
        self.buzPin = buzPin
        self.softwareVersion = softwareVersion
    }
}

// MARK: - Errors

public enum BLEError: LocalizedError {
    case bluetoothPoweredOff
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case failedToConnect
    case noServicesFound
    case noCharacteristicsFound
    case requiredCharacteristicsNotFound
    
    public var errorDescription: String? {
        switch self {
        case .bluetoothPoweredOff:
            return "Bluetooth is powered off."
        case .bluetoothUnauthorized:
            return "Bluetooth usage is not authorized."
        case .bluetoothUnsupported:
            return "Bluetooth is unsupported on this device."
        case .failedToConnect:
            return "Failed to connect to the device."
        case .noServicesFound:
            return "No services found on the device."
        case .noCharacteristicsFound:
            return "No characteristics found on the device."
        case .requiredCharacteristicsNotFound:
            return "Required UART characteristics not found on the device."
        }
    }
}

private extension UInt8 {
    init(clamping value: Int) {
        if value < 0 {
            self = 0
        } else if value > 255 {
            self = 255
        } else {
            self = UInt8(value)
        }
    }
}
