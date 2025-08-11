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

// MARK: - Supporting Models

/// Telemetry data structure containing key sensor readings
public struct TelemetryPacket: Equatable {
    public let probeType: String
    public let frequency: Double
    public let sondeName: String
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let horizontalSpeed: Double
    public let verticalSpeed: Double
    public let rssi: Double
    public let batPercentage: Int
    public let afcFrequency: Int
    public let burstKillerEnabled: Bool
    public let burstKillerTime: Int
    public let batVoltage: Int
    public let buzmute: Bool
    public let softwareVersion: String

    public init(probeType: String, frequency: Double, sondeName: String, latitude: Double, longitude: Double, altitude: Double, horizontalSpeed: Double, verticalSpeed: Double, rssi: Double, batPercentage: Int, afcFrequency: Int, burstKillerEnabled: Bool, burstKillerTime: Int, batVoltage: Int, buzmute: Bool, softwareVersion: String) {
        self.probeType = probeType
        self.frequency = frequency
        self.sondeName = sondeName
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalSpeed = horizontalSpeed
        self.verticalSpeed = verticalSpeed
        self.rssi = rssi
        self.batPercentage = batPercentage
        self.afcFrequency = afcFrequency
        self.burstKillerEnabled = burstKillerEnabled
        self.burstKillerTime = burstKillerTime
        self.batVoltage = batVoltage
        self.buzmute = buzmute
        self.softwareVersion = softwareVersion
    }
}

/// DeviceSettingsModel matching full specification of type 3 message.
public struct BLEDeviceSettingsModel: Equatable {
    public let probeType: String
    public let frequency: Double
    public let oledSDA: Int
    public let oledSCL: Int
    public let oledRST: Int
    public let ledPin: Int
    public let RS41Bandwidth: Int
    public let M20Bandwidth: Int
    public let M10Bandwidth: Int
    public let PILOTBandwidth: Int
    public let DFMBandwidth: Int
    public let callSign: String
    public let frequencyCorrection: Int
    public let batPin: Int
    public let batMin: Int
    public let batMax: Int
    public let batType: Int
    public let lcdType: Int
    public let nameType: Int
    public let buzPin: Int
    public let softwareVersion: String
    
    public init(
        probeType: String, frequency: Double, oledSDA: Int, oledSCL: Int, oledRST: Int, ledPin: Int, RS41Bandwidth: Int, M20Bandwidth: Int, M10Bandwidth: Int, PILOTBandwidth: Int, DFMBandwidth: Int, callSign: String, frequencyCorrection: Int, batPin: Int, batMin: Int, batMax: Int, batType: Int, lcdType: Int, nameType: Int, buzPin: Int, softwareVersion: String
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

/// Type 2 Packet: Signal and status info packet
/// Fields:
/// 0: "2" (packet type)
/// 1: probeType (String)
/// 2: frequency (Double)
/// 3: sondeName (String)
/// 4: RSSI (Double)
/// 5: batPercentage (Int)
/// 6: afcFrequency (Int)
/// 7: batVoltage (Int)
/// 8: buzmute (Bool; 1=true, 0=false)
/// 9: softwareVersion (String)
public struct Type2Packet: CustomStringConvertible {
    public let probeType: String
    public let frequency: Double
    public let sondeName: String
    public let rssi: Double
    public let batPercentage: Int
    public let afcFrequency: Int
    public let batVoltage: Int
    public let buzmute: Bool
    public let softwareVersion: String
    
    public var description: String {
        "Type2Packet(probeType: \(probeType), frequency: \(frequency), sondeName: \(sondeName), rssi: \(rssi), batPercentage: \(batPercentage), afcFrequency: \(afcFrequency), batVoltage: \(batVoltage), buzmute: \(buzmute), softwareVersion: \(softwareVersion))"
    }
}


// MARK: - Delegate and Manager class

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
            // This is the correct logic to update the main telemetry
            let telemetry = TelemetryPacket(
                probeType: packet.probeType,
                frequency: packet.frequency,
                sondeName: packet.sondeName,
                latitude: packet.latitude,
                longitude: packet.longitude,
                altitude: packet.altitude,
                horizontalSpeed: packet.horizontalSpeed,
                verticalSpeed: packet.verticalSpeed,
                rssi: packet.rssi,
                batPercentage: packet.batPercentage,
                afcFrequency: packet.afcFrequency,
                burstKillerEnabled: packet.burstKillerEnabled,
                burstKillerTime: packet.burstKillerTime,
                batVoltage: packet.batVoltage,
                buzmute: packet.buzmute,
                softwareVersion: packet.softwareVersion
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
    private func parseType1(_ fields: [String]) -> TelemetryPacket? {
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
        func doubleAt(_ idx: Int) -> Double? {
            guard idx < fields.count else { return nil }
            if let val = Double(fields[idx]) { return val }
            if bleDebug { print("[BLE][Parse] Failed to parse Double at index \(idx) from '\(fields[idx])'") }
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
        
        let probeType = stringAt(1)
        guard let frequency = doubleAt(2) else { return nil }
        let sondeName = stringAt(3)
        guard let latitude = doubleAt(4),
              let longitude = doubleAt(5),
              let altitude = doubleAt(6),
              let horizontalSpeed = doubleAt(7),
              let verticalSpeed = doubleAt(8),
              let rssi = doubleAt(9),
              let batPercentage = intAt(10),
              let afcFrequency = intAt(11)
        else {
            return nil
        }
        
        let burstKillerEnabled = boolAt(12)
        guard let burstKillerTime = intAt(13),
              let batVoltage = intAt(14)
        else {
            return nil
        }
        
        let buzmute = boolAt(15)
        // No reserved fields are used in TelemetryPacket struct
        // let reserved1 = intAt(16) ?? 0
        // let reserved2 = intAt(17) ?? 0
        // let reserved3 = intAt(18) ?? 0
        let softwareVersion = stringAt(19)
        
        return TelemetryPacket(
            probeType: probeType,
            frequency: frequency,
            sondeName: sondeName,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalSpeed: horizontalSpeed,
            verticalSpeed: verticalSpeed,
            rssi: rssi,
            batPercentage: batPercentage,
            afcFrequency: afcFrequency,
            burstKillerEnabled: burstKillerEnabled,
            burstKillerTime: burstKillerTime,
            batVoltage: batVoltage,
            buzmute: buzmute,
            softwareVersion: softwareVersion
        )
    }
    
    /// Type 2 Packet: Signal and status info packet
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
        
        let probeType = stringAt(1)
        guard let frequency = doubleAt(2) else { return nil }
        let sondeName = stringAt(3)
        guard let rssi = doubleAt(4),
              let batPercentage = intAt(5),
              let afcFrequency = intAt(6),
              let batVoltage = intAt(7)
        else {
            return nil
        }
        let buzmute = boolAt(8)
        let softwareVersion = stringAt(9)
        
        return Type2Packet(
            probeType: probeType,
            frequency: frequency,
            sondeName: sondeName,
            rssi: rssi,
            batPercentage: batPercentage,
            afcFrequency: afcFrequency,
            batVoltage: batVoltage,
            buzmute: buzmute,
            softwareVersion: softwareVersion
        )
    }
    
    /// Type 3 Packet: Device settings packet
    private func parseType3(_ fields: [String]) -> BLEDeviceSettingsModel? {
        guard fields.count >= 22 else {
            if bleDebug { print("[BLE][Parse] Device settings packet with insufficient fields (need at least 22): \(fields.count)") }
            return nil
        }
        
        func intAt(_ idx: Int) -> Int? {
            guard idx < fields.count else { return nil }
            if let val = Int(fields[idx]) { return val }
            if bleDebug { print("[BLE][Parse] Failed to parse Int at index \(idx) from '\(fields[idx])'") }
            return nil
        }
        func doubleAt(_ idx: Int) -> Double? {
            guard idx < fields.count else { return nil }
            if let val = Double(fields[idx]) { return val }
            if bleDebug { print("[BLE][Parse] Failed to parse Double at index \(idx) from '\(fields[idx])'") }
            return nil
        }
        func stringAt(_ idx: Int) -> String {
            guard idx < fields.count else { return "" }
            return fields[idx]
        }
        
        let probeType = stringAt(1)
        guard let frequency = doubleAt(2),
              let oledSDA = intAt(3),
              let oledSCL = intAt(4),
              let oledRST = intAt(5),
              let ledPin = intAt(6),
              let RS41Bandwidth = intAt(7),
              let M20Bandwidth = intAt(8),
              let M10Bandwidth = intAt(9),
              let PILOTBandwidth = intAt(10),
              let DFMBandwidth = intAt(11)
        else { return nil }
        
        let callSign = stringAt(12)
        
        guard let frequencyCorrection = intAt(13),
              let batPin = intAt(14),
              let batMin = intAt(15),
              let batMax = intAt(16),
              let batType = intAt(17),
              let lcdType = intAt(18),
              let nameType = intAt(19),
              let buzPin = intAt(20)
        else { return nil }
        
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
        if let error = error {
            if bleDebug { print("[BLE] Error receiving data: \(error.localizedDescription)") }
            return
        }
        
        guard let data = characteristic.value else { return }
        
        if characteristic.uuid == Self.uartRXCharacteristicUUID {
            handleIncomingData(data)
        }
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
