//
//  BLEManager.swift
//  BalloonHunter
//
//  Created by Assistant on 2025-08-10.
//

import Foundation
import CoreBluetooth
import Combine

public protocol BLEManagerDelegate: AnyObject {
    func bleManager(_ manager: BLEManager, didUpdateTelemetry telemetry: Telemetry)
    func bleManager(_ manager: BLEManager, didUpdateDeviceSettings settings: DeviceSettings)
    func bleManager(_ manager: BLEManager, didChangeState state: BLEManager.ConnectionState)
}

public final class BLEManager: NSObject, ObservableObject {
    // MARK: - BLE Constants
    
    public static let uartServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let uartTXCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // Peripheral -> Central (Notify)
    public static let uartRXCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // Central -> Peripheral (Write)
    
    // Device name to scan for
    private let targetDeviceName = "MySondyGo"
    
    // MARK: - Public Types
    
    public enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case connecting
        case connected
        case ready
        case failed(Error)
    }
    
    // MARK: - Published Properties
    
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var telemetry: Telemetry?
    @Published public private(set) var deviceSettings: DeviceSettings?
    
    // MARK: - Private Properties
    
    private var centralManager: CBCentralManager!
    private var uartPeripheral: CBPeripheral?
    private var uartTXCharacteristic: CBCharacteristic? // Notify from peripheral
    private var uartRXCharacteristic: CBCharacteristic? // Write to peripheral
    
    private var isScanning = false
    private var reconnectTimer: Timer?
    
    /// Buffer for incoming UART data packets
    private var incomingDataBuffer = Data()
    
    private let packetDispatchQueue = DispatchQueue(label: "com.balloonhunter.ble.packetDispatchQueue")
    
    private var cancellables = Set<AnyCancellable>()
    
    // Delegate for integrating with MainViewModel and PersistenceService
    public weak var delegate: BLEManagerDelegate?
    
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
            guard centralManager.state == .poweredOn else {
                connectionState = .failed(BLEError.bluetoothPoweredOff)
                return
            }
            startScanning()
        }
    }
    
    /// Disconnect from current device and stop scanning
    public func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        
        if let peripheral = uartPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        uartPeripheral = nil
        uartTXCharacteristic = nil
        uartRXCharacteristic = nil
        
        connectionState = .disconnected
        incomingDataBuffer.removeAll()
    }
    
    /// Send data to peripheral UART RX characteristic
    /// - Parameter data: Data to send
    public func send(data: Data) {
        guard let peripheral = uartPeripheral,
              let txChar = uartRXCharacteristic else { return }
        
        // Write without response for UART RX characteristic
        peripheral.writeValue(data, for: txChar, type: .withResponse)
    }
    
    /// Get latest telemetry data if available
    public func getLatestTelemetry() -> Telemetry? {
        telemetry
    }
    
    /// Get latest device settings if available
    public func getLatestDeviceSettings() -> DeviceSettings? {
        deviceSettings
    }
    
    // MARK: - Private Methods
    
    private func startScanning() {
        guard !isScanning else { return }
        
        connectionState = .scanning
        isScanning = true
        
        centralManager.scanForPeripherals(withServices: [Self.uartServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    
    private func stopScanning() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
    }
    
    private func scheduleReconnect(delay: TimeInterval = 5.0) {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }
    
    private func clearDataBuffer() {
        incomingDataBuffer.removeAll()
    }
    
    /// Called on receiving new data from UART TX characteristic (peripheral -> central)
    private func handleIncomingData(_ data: Data) {
        packetDispatchQueue.async { [weak self] in
            self?.incomingDataBuffer.append(data)
            self?.processIncomingBuffer()
        }
    }
    
    /// Process incomingDataBuffer to extract full packets and parse them
    private func processIncomingBuffer() {
        // RadioSondyGo FSD packet format assumptions:
        // For the sake of this example, we assume packets start with a header byte 0xAA,
        // have a length byte, followed by payload and checksum.
        // This is a placeholder parser and should be replaced with real FSD parsing logic.
        
        while true {
            guard incomingDataBuffer.count >= 3 else { return }
            
            // Search for header byte 0xAA
            guard let headerIndex = incomingDataBuffer.firstIndex(of: 0xAA) else {
                // No header found, discard all buffer
                incomingDataBuffer.removeAll()
                return
            }
            
            if headerIndex > 0 {
                // Remove bytes before header
                incomingDataBuffer.removeSubrange(0..<headerIndex)
            }
            
            guard incomingDataBuffer.count >= 3 else { return }
            
            // Length byte is second byte (index 1)
            let lengthByte = incomingDataBuffer[1]
            let packetLength = Int(lengthByte)
            
            guard packetLength >= 3 else {
                // Invalid length, discard header byte and retry
                incomingDataBuffer.removeFirst()
                continue
            }
            
            guard incomingDataBuffer.count >= packetLength else {
                // Wait for more data
                return
            }
            
            let packet = incomingDataBuffer.subdata(in: 0..<packetLength)
            incomingDataBuffer.removeSubrange(0..<packetLength)
            
            // Validate packet checksum and parse
            if validatePacket(packet) {
                parsePacket(packet)
            } else {
                // Invalid checksum, discard and continue parsing
                continue
            }
        }
    }
    
    private func validatePacket(_ packet: Data) -> Bool {
        // Placeholder validation: simple checksum last byte = XOR of all previous bytes
        guard packet.count >= 3 else { return false }
        let checksum = packet.last!
        let dataToCheck = packet.dropLast()
        
        let calcChecksum = dataToCheck.reduce(0, ^)
        return checksum == calcChecksum
    }
    
    private func parsePacket(_ packet: Data) {
        // Packet format:
        // Byte 0: Header (0xAA)
        // Byte 1: Length
        // Byte 2: Packet type (e.g. 1 = telemetry, 3 = device settings)
        // Bytes 3..(length-2): Payload
        // Last byte: Checksum
        
        guard packet.count >= 4 else { return }
        let packetType = packet[2]
        
        let payload = packet.subdata(in: 3..<(packet.count - 1))
        
        switch packetType {
        case 1:
            if let telemetry = parseTelemetryPayload(payload) {
                DispatchQueue.main.async { [weak self] in
                    self?.telemetry = telemetry
                    self?.delegate?.bleManager(self!, didUpdateTelemetry: telemetry)
                }
            }
        case 3:
            if let settings = parseDeviceSettingsPayload(payload) {
                DispatchQueue.main.async { [weak self] in
                    self?.deviceSettings = settings
                    self?.delegate?.bleManager(self!, didUpdateDeviceSettings: settings)
                }
            }
        default:
            // Unknown packet type, ignore
            break
        }
    }
    
    private func parseTelemetryPayload(_ data: Data) -> Telemetry? {
        // Placeholder parsing:
        // Assume fixed length payload with:
        // [0-3] altitude (Float32, meters)
        // [4-7] temperature (Float32, °C)
        // [8-11] battery voltage (Float32, V)
        
        guard data.count >= 12 else { return nil }
        
        let altitude = data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: Float32.self) }
        let temperature = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: Float32.self) }
        let batteryVoltage = data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: Float32.self) }
        
        return Telemetry(altitude: Double(altitude),
                         temperature: Double(temperature),
                         batteryVoltage: Double(batteryVoltage))
    }
    
    private func parseDeviceSettingsPayload(_ data: Data) -> DeviceSettings? {
        // Placeholder parsing:
        // Assume first byte is device mode (UInt8)
        // Next 4 bytes are float sampleRate (Hz)
        
        guard data.count >= 5 else { return nil }
        let mode = data[0]
        let sampleRate = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: Float32.self) }
        
        return DeviceSettings(deviceMode: mode, sampleRateHz: Double(sampleRate))
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Ready to scan/connect
            break
        case .poweredOff:
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .failed(BLEError.bluetoothPoweredOff)
            }
        case .unauthorized:
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .failed(BLEError.bluetoothUnauthorized)
            }
        case .unsupported:
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .failed(BLEError.bluetoothUnsupported)
            }
        default:
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .disconnected
            }
        }
    }
    
    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String : Any],
                               rssi RSSI: NSNumber) {
        guard uartPeripheral == nil else {
            // Already connected to a device, ignore others
            return
        }
        
        if peripheral.name == targetDeviceName || advertisementData[CBAdvertisementDataLocalNameKey] as? String == targetDeviceName {
            stopScanning()
            uartPeripheral = peripheral
            uartPeripheral?.delegate = self
            connectionState = .connecting
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == uartPeripheral else { return }
        connectionState = .connected
        peripheral.discoverServices([Self.uartServiceUUID])
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == uartPeripheral else { return }
        connectionState = .failed(error ?? BLEError.failedToConnect)
        uartPeripheral = nil
        scheduleReconnect()
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == uartPeripheral else { return }
        connectionState = .disconnected
        uartPeripheral = nil
        uartTXCharacteristic = nil
        uartRXCharacteristic = nil
        incomingDataBuffer.removeAll()
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            connectionState = .failed(error)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        guard let services = peripheral.services else {
            connectionState = .failed(BLEError.noServicesFound)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        for service in services where service.uuid == Self.uartServiceUUID {
            peripheral.discoverCharacteristics([Self.uartTXCharacteristicUUID, Self.uartRXCharacteristicUUID], for: service)
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error = error {
            connectionState = .failed(error)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        guard let characteristics = service.characteristics else {
            connectionState = .failed(BLEError.noCharacteristicsFound)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        for char in characteristics {
            if char.uuid == Self.uartTXCharacteristicUUID {
                uartTXCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            } else if char.uuid == Self.uartRXCharacteristicUUID {
                uartRXCharacteristic = char
            }
        }
        
        if uartTXCharacteristic != nil && uartRXCharacteristic != nil {
            connectionState = .ready
        } else {
            connectionState = .failed(BLEError.requiredCharacteristicsNotFound)
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            connectionState = .failed(error)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            // Log error but do not disconnect immediately
            print("Error receiving data: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else { return }
        
        if characteristic.uuid == Self.uartTXCharacteristicUUID {
            handleIncomingData(data)
        }
    }
}

// MARK: - Supporting Models

public struct Telemetry: Equatable {
    public let altitude: Double
    public let temperature: Double
    public let batteryVoltage: Double
    
    public init(altitude: Double, temperature: Double, batteryVoltage: Double) {
        self.altitude = altitude
        self.temperature = temperature
        self.batteryVoltage = batteryVoltage
    }
}

public struct DeviceSettings: Equatable {
    public let deviceMode: UInt8
    public let sampleRateHz: Double
    
    public init(deviceMode: UInt8, sampleRateHz: Double) {
        self.deviceMode = deviceMode
        self.sampleRateHz = sampleRateHz
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
