import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import os

@MainActor
final class BLECommunicationService: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    private var centralManager: CBCentralManager!
    private var persistenceService: PersistenceService
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    weak var annotationService: AnnotationService?
    weak var predictionService: PredictionService?
    weak var currentLocationService: CurrentLocationService?
    weak var serviceManager: ServiceManager?

    private let UART_SERVICE_UUID = CBUUID(string: "53797269-614D-6972-6B6F-44616C6D6F6E")
    private let UART_RX_CHARACTERISTIC_UUID = CBUUID(string: "53797267-614D-6972-6B6F-44616C6D6F8E")
    private let UART_TX_CHARACTERISTIC_UUID = CBUUID(string: "53797268-614D-6972-6B6F-44616C6D6F7E")

    private var hasSentReadSettingsCommand = false

    // Buffer to accumulate incoming BLE data fragments until a full message is received
    private var incomingBLEBuffer: Data = Data()

    @Published var telemetryAvailabilityState: Bool = false

    init(persistenceService: PersistenceService, serviceManager: ServiceManager) {
        self.persistenceService = persistenceService
        self.serviceManager = serviceManager
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)

        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateTelemetryAvailabilityState()
            }
        }
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
                print("[BLECommunicationService] Telemetry GAINED: lastTelemetryUpdateTime within 3 seconds.")
            } else {
                print("[BLECommunicationService] Telemetry LOST: lastTelemetryUpdateTime older than 3 seconds.")
            }
        }
    }

    private func checkTelemetryAvailability(_ newTelemetry: TelemetryData?) {
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        case .poweredOff:
            connectionStatus = .disconnected
        case .resetting:
            break
        case .unauthorized:
            break
        case .unknown:
            break
        case .unsupported:
            break
        @unknown default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let peripheralName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            if peripheralName.contains("MySondy") {
                centralManager.stopScan()
                connectedPeripheral = peripheral
                connectionStatus = .connecting
                centralManager.connect(peripheral, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionStatus = .connected
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([UART_SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStatus = .disconnected
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionStatus = .disconnected
        connectedPeripheral = nil
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if error != nil {
            return
        }
        guard let services = peripheral.services else {
            return
        }
        for service in services {
            if service.uuid == UART_SERVICE_UUID {
                peripheral.discoverCharacteristics([UART_RX_CHARACTERISTIC_UUID, UART_TX_CHARACTERISTIC_UUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            appLog("Error discovering characteristics for service \(service.uuid.uuidString): \(error.localizedDescription)", category: .service, level: .error)
            return
        }
        guard let characteristics = service.characteristics else {
            appLog("No characteristics found for service \(service.uuid.uuidString).", category: .service, level: .debug)
            return
        }
        appLog("Discovered \(characteristics.count) characteristic(s) for service \(service.uuid.uuidString).", category: .service, level: .debug)
        for characteristic in characteristics {
            if characteristic.uuid == UART_RX_CHARACTERISTIC_UUID {
                appLog("Found UART RX Characteristic. Checking notify property...", category: .service, level: .debug)
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                    appLog("Set notify value to true for RX characteristic.", category: .service, level: .debug)
                } else {
                    appLog("UART RX Characteristic does not have notify property.", category: .service, level: .error)
                }
            } else if characteristic.uuid == UART_TX_CHARACTERISTIC_UUID {
                appLog("Found UART TX Characteristic. Checking write properties...", category: .service, level: .debug)
                if characteristic.properties.contains(.write) {
                    self.writeCharacteristic = characteristic
                    appLog("Assigned TX characteristic for writing (write).", category: .service, level: .debug)
                } else if characteristic.properties.contains(.writeWithoutResponse) {
                    self.writeCharacteristic = characteristic
                    appLog("Assigned TX characteristic for writing (writeWithoutResponse).", category: .service, level: .debug)
                } else {
                    appLog("UART TX Characteristic does not have write or writeWithoutResponse properties.", category: .service, level: .error)
                }
            }
        }
        if writeCharacteristic == nil {
            isReadyForCommands = false
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil {
            return
        }
        guard let data = characteristic.value else {
            return
        }
        if let string = String(data: data, encoding: .utf8) {
            self.parse(message: string)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil {
            // Error occurred during write
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil {
            // Error occurred during notification state update
        } else {
            // Notification state updated successfully
        }
    }

    @Published var isReadyForCommands = false

    private func parse(message: String) {
        if !isReadyForCommands {
            isReadyForCommands = true
        }
        
        let components = message.components(separatedBy: "/")
        guard components.count > 1 else {
            return
        }
        let messageType = components[0]
        if messageType == "3" {
            var deviceSettings = DeviceSettings()
            deviceSettings.parse(message: message)
            persistenceService.save(deviceSettings: deviceSettings)
            
        } else {
            var telemetryData = TelemetryData()
            telemetryData.parse(message: message)
            if telemetryData.latitude == 0.0 && telemetryData.longitude == 0.0 {
                return
            }
            self.latestTelemetry = telemetryData

            self.lastTelemetryUpdateTime = Date()
            self.telemetryData.send(telemetryData)
            self.serviceManager?.telemetryPublisher.send(TelemetryEvent(telemetryData: telemetryData))

            if !hasSentReadSettingsCommand && isReadyForCommands {
                readSettings()
                hasSentReadSettingsCommand = true
            }
        }
    }
    @Published var latestTelemetry: TelemetryData? = nil {
        didSet {
        }
    }
    @Published var deviceSettings: DeviceSettings = .default
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var telemetryData = PassthroughSubject<TelemetryData, Never>()
    @Published var lastTelemetryUpdateTime: Date? = nil

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
        guard let data = command.data(using: .utf8) else {
            return
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }
    
    func disconnect() {
        if let connectedPeripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(connectedPeripheral)
        }
        centralManager.stopScan()
        connectionStatus = .disconnected
    }

    func sendSettingsCommand(frequency: Double, probeType: Int) {
        let formattedCommand = String(format: "o{f=%.2f/tipo=%d}o", frequency, probeType)
        sendCommand(command: formattedCommand)
    }
}

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
