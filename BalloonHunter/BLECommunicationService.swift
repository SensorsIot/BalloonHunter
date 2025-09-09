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
        print("[DEBUG] BLECommunicationService init")

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
        print("[DEBUG] Central Manager did update state: \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            print("[DEBUG] BLE is powered on. Starting scan...")
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        case .poweredOff:
            print("[DEBUG] BLE is powered off.")
            connectionStatus = .disconnected
        case .resetting:
            print("[DEBUG] BLE is resetting.")
        case .unauthorized:
            print("[DEBUG] BLE is unauthorized.")
        case .unknown:
            print("[DEBUG] BLE state is unknown.")
        case .unsupported:
            print("[DEBUG] BLE is unsupported.")
        @unknown default:
            print("[DEBUG] Unknown BLE state.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print("[DEBUG] Did discover peripheral: \(peripheral.name ?? "Unknown") (UUID: \(peripheral.identifier.uuidString)), RSSI: \(RSSI)")

        if let peripheralName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            if peripheralName.contains("MySondy") {
                print("[DEBUG] Found MySondy: \(peripheralName). Stopping scan and connecting...")
                centralManager.stopScan()
                connectedPeripheral = peripheral
                connectionStatus = .connecting
                centralManager.connect(peripheral, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[DEBUG] Successfully connected to peripheral: \(peripheral.name ?? "Unknown")")
        connectionStatus = .connected
        connectedPeripheral = peripheral
        peripheral.delegate = self
        print("[DEBUG] Discovering services for peripheral: \(peripheral.name ?? "Unknown") with UUID: \(UART_SERVICE_UUID.uuidString)")
        peripheral.discoverServices([UART_SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[DEBUG] Failed to connect to peripheral: \(peripheral.name ?? "Unknown"). Error: \(error?.localizedDescription ?? "Unknown error")")
        connectionStatus = .disconnected
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[DEBUG] Disconnected from peripheral: \(peripheral.name ?? "Unknown"). Error: \(error?.localizedDescription ?? "No error")")
        connectionStatus = .disconnected
        connectedPeripheral = nil
        print("[DEBUG] Restarting scan after disconnection...")
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[DEBUG] Error discovering services for \(peripheral.name ?? "Unknown"): \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            print("[DEBUG] No services found for \(peripheral.name ?? "Unknown").")
            return
        }
        print("[DEBUG] Discovered \(services.count) service(s) for \(peripheral.name ?? "Unknown").")
        for service in services {
            if service.uuid == UART_SERVICE_UUID {
                print("[DEBUG] Found UART Service. Discovering characteristics for service: \(service.uuid.uuidString) with RX: \(UART_RX_CHARACTERISTIC_UUID.uuidString) and TX: \(UART_TX_CHARACTERISTIC_UUID.uuidString)")
                peripheral.discoverCharacteristics([UART_RX_CHARACTERISTIC_UUID, UART_TX_CHARACTERISTIC_UUID], for: service)
            } else {
                print("[DEBUG] Skipping non-UART service: \(service.uuid.uuidString)")
            }
        }
        if services.allSatisfy({ $0.uuid != UART_SERVICE_UUID }) {
            print("[DEBUG] UART Service not found among discovered services. Is the BLE device advertising the correct service?")
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
        if let error = error {
            print("[DEBUG] Error updating value for characteristic \(characteristic.uuid.uuidString): \(error.localizedDescription)") // Re-added debug print
            return
        }
        guard let data = characteristic.value else {
            print("[DEBUG] No data received for characteristic \(characteristic.uuid.uuidString).") // Re-added debug print
            return
        }
        if let string = String(data: data, encoding: .utf8) {
            self.parse(message: string)
        } else {
            print("[DEBUG] Could not decode data to UTF8 string for characteristic \(characteristic.uuid.uuidString). Raw data: \(data.hexEncodedString())") // Re-added debug print
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

    @Published var isReadyForCommands = false

    private func parse(message: String) {
        print("[DEBUG] Raw BLE message received: \(message)") // Re-added debug print
        if !isReadyForCommands {
            isReadyForCommands = true
            print("[DEBUG] First BLE message received. isReadyForCommands is now true.")
        }
        
        let components = message.components(separatedBy: "/")
        guard components.count > 1 else {
            print("[DEBUG] Parse: Message too short or invalid format: \(message)")
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
                print("[BLECommunicationService] Ignoring telemetry with (0,0) coordinates (likely invalid).")
                return
            }
            self.latestTelemetry = telemetryData

            self.lastTelemetryUpdateTime = Date()
            self.telemetryData.send(telemetryData)
            self.serviceManager?.telemetryPublisher.send(TelemetryEvent(telemetryData: telemetryData))

            if !hasSentReadSettingsCommand && isReadyForCommands {
                print("[DEBUG] First type 1 message parsed and TX ready. Reading settings...")
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
            print("[DEBUG] sendCommand blocked: TX characteristic not ready. Wait until BLE connection and discovery complete. Check previous debug output for service and characteristic discovery issues.")
            return
        }
        guard let peripheral = connectedPeripheral else {
            print("[DEBUG] sendCommand Error: Not connected to a peripheral.")
            return
        }
        guard let characteristic = writeCharacteristic else {
            print("[DEBUG] sendCommand Error: Write characteristic not found.")
            return
        }
        guard let data = command.data(using: .utf8) else {
            print("[DEBUG] sendCommand Error: Could not convert command string to data.")
            return
        }
        print("[DEBUG] Sending command: \(command) (Raw Data: \(data.hexEncodedString()))")
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }
    
    func disconnect() {
        print("[DEBUG] Disconnect: Attempting to disconnect from peripheral.")
        if let connectedPeripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(connectedPeripheral)
        }
        centralManager.stopScan()
        connectionStatus = .disconnected
    }

    func sendSettingsCommand(frequency: Double, probeType: Int) {
        let formattedCommand = String(format: "o{f=%.2f/tipo=%d}o", frequency, probeType)
        print("[DEBUG] sendSettingsCommand: Sending command: \(formattedCommand)")
        sendCommand(command: formattedCommand)
    }
}

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
