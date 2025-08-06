import Foundation
import Combine
import CoreBluetooth

struct SondeSettings: Codable, Equatable, CustomStringConvertible {
    // General Settings
    var lcdType: Int = 0
    var lcdOn: Int = 1
    var blu: Int = 1
    var baud: Int = 1
    var com: Int = 0
    var callSign: String = "MYCALL"
    var frequencyCorrection: String = "0"
    var nameType: Int = 0

    // Pin Assignments
    var oledSDA: String = "21"
    var oledSCL: String = "22"
    var oledRST: String = "16"
    var ledPin: String = "25"
    var buzPin: String = "0"
    var batPin: String = "35"

    // Radio Reception Bandwidth
    var rs41Bandwidth: Int = 1
    var m20Bandwidth: Int = 7
    var m10Bandwidth: Int = 7
    var pilotBandwidth: Int = 7
    var dfmBandwidth: Int = 6

    // Battery Calibration
    var batMin: String = "2950"
    var batMax: String = "4180"
    var batType: Int = 1

    // Other Direct Control Commands
    var frequency: Double = 404.600
    var probeType: Int = 1
    var mute: Int = -1 // -1 = not installed

    var description: String {
        "lcdType: \(lcdType), lcdOn: \(lcdOn), blu: \(blu), baud: \(baud), com: \(com), callSign: \(callSign), frequencyCorrection: \(frequencyCorrection), nameType: \(nameType), oledSDA: \(oledSDA), oledSCL: \(oledSCL), oledRST: \(oledRST), ledPin: \(ledPin), buzPin: \(buzPin), batPin: \(batPin), rs41Bandwidth: \(rs41Bandwidth), m20Bandwidth: \(m20Bandwidth), m10Bandwidth: \(m10Bandwidth), pilotBandwidth: \(pilotBandwidth), dfmBandwidth: \(dfmBandwidth), batMin: \(batMin), batMax: \(batMax), batType: \(batType), frequency: \(frequency), probeType: \(probeType), mute: \(mute)"
    }

    /// Serializes all settings as a single command string according to the device protocol
    /// Each setting is sent as key=value pairs joined by '/'.
    /// This format matches the expected command string for the BLE device firmware.
    func serializeToCommand() -> String {
        // Each setting is sent as key=value, joined by '/'
        var commandParts: [String] = []
        commandParts.append("lcdType=\(lcdType)")
        commandParts.append("lcdOn=\(lcdOn)")
        commandParts.append("blu=\(blu)")
        commandParts.append("baud=\(baud)")
        commandParts.append("com=\(com)")
        commandParts.append("callSign=\(callSign)")
        commandParts.append("frequencyCorrection=\(frequencyCorrection)")
        commandParts.append("nameType=\(nameType)")
        commandParts.append("oledSDA=\(oledSDA)")
        commandParts.append("oledSCL=\(oledSCL)")
        commandParts.append("oledRST=\(oledRST)")
        commandParts.append("ledPin=\(ledPin)")
        commandParts.append("buzPin=\(buzPin)")
        commandParts.append("batPin=\(batPin)")
        commandParts.append("rs41Bandwidth=\(rs41Bandwidth)")
        commandParts.append("m20Bandwidth=\(m20Bandwidth)")
        commandParts.append("m10Bandwidth=\(m10Bandwidth)")
        commandParts.append("pilotBandwidth=\(pilotBandwidth)")
        commandParts.append("dfmBandwidth=\(dfmBandwidth)")
        commandParts.append("batMin=\(batMin)")
        commandParts.append("batMax=\(batMax)")
        commandParts.append("batType=\(batType)")
        commandParts.append("frequency=\(frequency)")
        commandParts.append("probeType=\(probeType)")
        commandParts.append("mute=\(mute)")
        return commandParts.joined(separator: "/")
    }
}

// MARK: - Telemetry Model
struct TelemetryStruct: Equatable {
    let probeType: String
    let frequency: Double
    let name: String
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalSpeed: Double
    let verticalSpeed: Double
    let signalStrength: Double
    let batteryPercentage: Int
    let afc: Int
    let burstKiller: Bool
    let burstKillerTime: Int
    let batteryVoltage: Int
    let buzzerMute: Int
    let firmwareVersion: String

    static func parseLongFormat(from components: [Substring]) -> TelemetryStruct? {
        guard components.count >= 21,
              let frequency = Double(components[2]),
              let latitude = Double(components[4]),
              let longitude = Double(components[5]),
              let altitude = Double(components[6]),
              let hSpeed = Double(components[7]),
              let vSpeed = Double(components[8]),
              let signal = Double(components[9]),
              let batteryPercent = Int(components[10]),
              let afc = Int(components[11]),
              let bkTime = Int(components[13]),
              let batteryVoltage = Int(components[14]),
              let buzzerMute = Int(components[18]) else {
            return nil
        }
        return TelemetryStruct(
            probeType: String(components[1]),
            frequency: frequency,
            name: String(components[3]),
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalSpeed: hSpeed,
            verticalSpeed: vSpeed,
            signalStrength: signal,
            batteryPercentage: batteryPercent,
            afc: afc,
            burstKiller: components[12] == "1",
            burstKillerTime: bkTime,
            batteryVoltage: batteryVoltage,
            buzzerMute: buzzerMute,
            firmwareVersion: String(components[19])
        )
    }

    static func parseShortFormat(from components: [Substring]) -> TelemetryStruct? {
        guard components.count >= 8 else { return nil }
        let probeType = String(components[1])
        let frequency = Double(components[2]) ?? 0
        let altitude = Double(components[3]) ?? 0
        let batteryPercentage = Int(components[4]) ?? 0
        let afc = Int(components[5]) ?? 0
        let burstKiller = (components[6] == "1")
        let firmwareVersion = String(components[7])

        return TelemetryStruct(
            probeType: probeType,
            frequency: frequency,
            name: "-",
            latitude: 0,
            longitude: 0,
            altitude: altitude,
            horizontalSpeed: 0,
            verticalSpeed: 0,
            signalStrength: 0,
            batteryPercentage: batteryPercentage,
            afc: afc,
            burstKiller: burstKiller,
            burstKillerTime: 0,
            batteryVoltage: 0,
            buzzerMute: 0,
            firmwareVersion: firmwareVersion
        )
    }
    
    // MARK: - Vertical Speed Smoothing

    private static var verticalSpeedHistory: [Double] = []
    private static let maxVerticalSpeedSamples = 10

    /// Adds a vertical speed sample and returns the moving average vertical speed.
    /// This static method centralizes the smoothing logic for vertical speed.
    static func addVerticalSpeedSample(_ speed: Double) -> Double {
        verticalSpeedHistory.append(speed)
        if verticalSpeedHistory.count > maxVerticalSpeedSamples {
            verticalSpeedHistory.removeFirst()
        }
        let sum = verticalSpeedHistory.reduce(0.0, +)
        return sum / Double(verticalSpeedHistory.count)
    }
}

// MARK: - TelemetryBuffer Actor
actor TelemetryBuffer {
    private var bufferedTelemetry: TelemetryStruct?
    private var bufferedSignalStrength: Double?
    private var bufferedValidSignal: Bool?
    private var bufferedReceivedText: String = ""
    private var bufferedIsConnected: Bool? = nil
    private var bufferedMessageType: String? = nil

    private var continuation: AsyncStream<Void>.Continuation? = nil

    func updatesStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func notify() {
        continuation?.yield()
    }

    func update(telemetry: TelemetryStruct?, signalStrength: Double?, validSignal: Bool?, messageType: String? = nil) {
        self.bufferedTelemetry = telemetry
        self.bufferedSignalStrength = signalStrength
        self.bufferedValidSignal = validSignal
        self.bufferedMessageType = messageType
        notify()
    }
    
    func appendReceivedText(_ text: String) {
        bufferedReceivedText += text
        notify()
    }

    func updateIsConnected(_ connected: Bool) {
        self.bufferedIsConnected = connected
        notify()
    }

    func flush() -> (TelemetryStruct?, Double?, Bool?, String, Bool?, String?) {
        defer {
            bufferedTelemetry = nil
            bufferedSignalStrength = nil
            bufferedValidSignal = nil
            bufferedReceivedText = ""
            bufferedIsConnected = nil
            bufferedMessageType = nil
        }
        return (bufferedTelemetry, bufferedSignalStrength, bufferedValidSignal, bufferedReceivedText, bufferedIsConnected, bufferedMessageType)
    }
}

// MARK: - BLEManager
class BLEManager: NSObject, ObservableObject {
    static let shared = BLEManager()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var uartCharacteristics: [CBCharacteristic] = []
    
    private var didSendSettingsRequest = false
    private var didSendStartupQuestion = false

    // Removed verticalSpeedHistory, maxVerticalSpeedSamples, verticalSpeedMovingAverage.
    // Vertical speed smoothing now centralized in TelemetryStruct.
    
    @Published var isConnected = false
    @Published var receivedText = ""
    @Published var latestTelemetry: TelemetryStruct? = nil
    @Published var signalStrength: Double? = nil
    @Published var validSignalReceived: Bool = false
    @Published var sondeSettings: SondeSettings = UserDefaults.standard.loadSondeSettings() ?? SondeSettings()

    let telemetryBuffer = TelemetryBuffer()

    private static let storedFrequencyKey = "StoredSondeFrequency"
    private static let storedTypeKey = "StoredSondeType"

    static var storedFrequency: Double? {
        get {
            let val = UserDefaults.standard.double(forKey: storedFrequencyKey)
            return val == 0 ? nil : val
        }
        set {
            if let value = newValue {
                UserDefaults.standard.set(value, forKey: storedFrequencyKey)
            }
        }
    }

    static var storedType: String? {
        get { UserDefaults.standard.string(forKey: storedTypeKey) }
        set { UserDefaults.standard.setValue(newValue, forKey: storedTypeKey) }
    }

    override init() {
        print("[BLEManager] Initializing BLEManager singleton")
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        print("[BLEManager] Created CBCentralManager, waiting for state update...")

        if !didSendStartupQuestion {
            sendCommand("?") // Send ? command at startup to request settings and fill fields via type 3 message
            didSendStartupQuestion = true
        }

        Task { [weak self] in
            guard let self = self else { return }
            for await _ in self.telemetryBuffer.updatesStream() {
                let (telemetry, signalStrength, validSignal, receivedText, isConnected, messageType) = await self.telemetryBuffer.flush()
                let uiUpdateStart = Date()
                await MainActor.run {
                    if let t = telemetry {
                        // verticalSpeed is now always the moving average from TelemetryStruct smoothing logic
                        print("[DEBUG] Received Telemetry Position (type=\(messageType ?? "?")): lat=\(t.latitude), lon=\(t.longitude)")
                        self.latestTelemetry = t
                        // Updating frequency and probeType here is silent (no prints)
                        self.sondeSettings.frequency = t.frequency
                        self.sondeSettings.probeType = Int(t.probeType.filter("0123456789".contains)) ?? self.sondeSettings.probeType
                        // Save updated settings to UserDefaults silently
                        UserDefaults.standard.saveSondeSettings(self.sondeSettings)
                    }
                    if let s = signalStrength { self.signalStrength = s }
                    if let v = validSignal { self.validSignalReceived = v }
                    if !receivedText.isEmpty { self.receivedText += receivedText }
                    if let c = isConnected { self.isConnected = c }
                }
                let uiUpdateEnd = Date()
                let duration = uiUpdateEnd.timeIntervalSince(uiUpdateStart)
                // No debug prints here
            }
        }
    }

    func connect() {
        print("[BLEManager] connect() called. Scanning for BLE devices...")
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    func sendCommand(_ command: String) {
        print("[BLE DEBUG] Sending BLE command: \(command)")
        guard !uartCharacteristics.isEmpty, let p = peripheral else { return }
        let wrappedCommand = "o{\(command)}o"
        if let data = wrappedCommand.data(using: .utf8) {
            let characteristic = uartCharacteristics[0]
            p.writeValue(data, for: characteristic, type: .withResponse)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[BLEManager] centralManagerDidUpdateState: \(central.state.rawValue)")
        if central.state == .poweredOn {
            print("[BLEManager] BLE is powered on. Attempting to scan for peripherals.")
            connect()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        print("[BLEManager] didDiscover peripheral: \(peripheral.name ?? "<no name>")")
        if let name = peripheral.name {
            print("[BLE DEBUG] Found BLE device: \(name)")
            if name.contains("Sondy") || name.contains("MySondy") {
                self.peripheral = peripheral
                self.peripheral?.delegate = self
                central.stopScan()
                print("[BLE DEBUG] Connecting to \(name)")
                central.connect(peripheral, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        print("[BLEManager] didConnect called for peripheral: \(peripheral.name ?? "<no name>")")
        if let name = peripheral.name {
            print("[BLE DEBUG] Connected to \(name)")
        }
        // Reset didSendSettingsRequest upon connection
        didSendSettingsRequest = false
        print("[BLE DEBUG] BLE connected. Waiting for first /0 message before sending '?' command.")

        Task { [weak self] in await self?.telemetryBuffer.updateIsConnected(true) }
        if let name = peripheral.name {
            print("[BLE DEBUG] Discovering services for \(name)")
        }
        peripheral.discoverServices(nil)
        // Commented out to prevent sending '?' immediately after connection
        // self.sendCommand("?")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        print("[BLEManager] didDisconnectPeripheral called for peripheral: \(peripheral.name ?? "<no name>")")
        if let name = peripheral.name {
            print("[BLE DEBUG] Disconnected from \(name) (will reconnect)")
        }
        // Reset didSendSettingsRequest on disconnect
        didSendSettingsRequest = false
        print("[BLE DEBUG] BLE disconnected. Reset didSendSettingsRequest.")
        
        Task { [weak self] in
            await self?.telemetryBuffer.updateIsConnected(false)
            self?.uartCharacteristics.removeAll()
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            self?.connect()
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if error != nil {
            return
        }

        guard let services = peripheral.services else {
            return
        }
        if let name = peripheral.name {
            print("[BLE DEBUG] Discovered services for \(name)")
        }

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let characteristics = service.characteristics else {
            return
        }

        print("[BLE DEBUG] Discovered characteristics for service \(service.uuid)")

        for characteristic in characteristics {
            if characteristic.properties.contains(.notify) {
                print("[BLE DEBUG] Subscribing to notifications for characteristic \(characteristic.uuid)")
                peripheral.setNotifyValue(true, for: characteristic)
            }

            if characteristic.properties.contains(.write) ||
               characteristic.properties.contains(.writeWithoutResponse) {
                print("[BLE DEBUG] Writeable characteristic \(characteristic.uuid)")
                if !uartCharacteristics.contains(where: { $0.uuid == characteristic.uuid }) {
                    uartCharacteristics.append(characteristic)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let data = characteristic.value,
           let text = String(data: data, encoding: .utf8) {
            // print("[BLE RAW MESSAGE] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            // print("[BLE DEBUG] Received message: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            Task { [weak self] in
                guard let self = self else { return }

                if trimmed == "?" {
                    await MainActor.run {
                        self.sondeSettings = UserDefaults.standard.loadSondeSettings() ?? self.sondeSettings
                        // Removed prints on receiving "?" reload
                    }
                    return
                }

                await self.telemetryBuffer.appendReceivedText(trimmed + "\n")
            }

            let components = trimmed.split(separator: "/")
            guard !components.isEmpty else { return }

            let messageType = String(components[0])

            switch messageType {
            case "0":
                // Parse and update settings and UserDefaults, but do NOT update telemetry (position) for type 0.
                if let telemetry = TelemetryStruct.parseLongFormat(from: components) {
                    // Filter out invalid telemetry with zero latitude AND zero longitude to prevent bogus messages
                    if telemetry.latitude == 0.0 && telemetry.longitude == 0.0 {
                        return
                    }

                    BLEManager.storedFrequency = telemetry.frequency
                    BLEManager.storedType = telemetry.probeType

                    Task { [weak self] in
                        guard let self = self else { return }
                        await MainActor.run {
                            let s = self.sondeSettings
                            let comp = components

                            // Check component count for safety
                            if comp.count >= 21 {
                                self.sondeSettings.oledSDA = String(comp[20])
                                self.sondeSettings.oledSCL = (comp.count > 21) ? String(comp[21]) : s.oledSCL
                                self.sondeSettings.oledRST = (comp.count > 22) ? String(comp[22]) : s.oledRST
                                self.sondeSettings.ledPin = (comp.count > 23) ? String(comp[23]) : s.ledPin
                                self.sondeSettings.buzPin = (comp.count > 24) ? String(comp[24]) : s.buzPin
                                self.sondeSettings.batPin = (comp.count > 25) ? String(comp[25]) : s.batPin
                                self.sondeSettings.rs41Bandwidth = (comp.count > 26) ? Int(comp[26]) ?? s.rs41Bandwidth : s.rs41Bandwidth
                                self.sondeSettings.m20Bandwidth = (comp.count > 27) ? Int(comp[27]) ?? s.m20Bandwidth : s.m20Bandwidth
                                self.sondeSettings.m10Bandwidth = (comp.count > 28) ? Int(comp[28]) ?? s.m10Bandwidth : s.m10Bandwidth
                                self.sondeSettings.pilotBandwidth = (comp.count > 29) ? Int(comp[29]) ?? s.pilotBandwidth : s.pilotBandwidth
                                self.sondeSettings.dfmBandwidth = (comp.count > 30) ? Int(comp[30]) ?? s.dfmBandwidth : s.dfmBandwidth
                                self.sondeSettings.callSign = (comp.count > 31) ? String(comp[31]) : s.callSign
                                self.sondeSettings.frequencyCorrection = (comp.count > 32) ? String(comp[32]) : s.frequencyCorrection
                                self.sondeSettings.batMin = (comp.count > 33) ? String(comp[33]) : s.batMin
                                self.sondeSettings.batMax = (comp.count > 34) ? String(comp[34]) : s.batMax
                                self.sondeSettings.batType = (comp.count > 35) ? Int(comp[35]) ?? s.batType : s.batType
                                self.sondeSettings.lcdType = (comp.count > 36) ? Int(comp[36]) ?? s.lcdType : s.lcdType
                                self.sondeSettings.nameType = (comp.count > 37) ? Int(comp[37]) ?? s.nameType : s.nameType
                                self.sondeSettings.frequency = telemetry.frequency
                                self.sondeSettings.probeType = Int(telemetry.probeType.filter("0123456789".contains)) ?? s.probeType
                            }
                            UserDefaults.standard.saveSondeSettings(self.sondeSettings)
                        }
                    }
                }
            case "1":
                // ONLY for type "1" messages do we update telemetry (position) and UI.
                if let telemetry = TelemetryStruct.parseLongFormat(from: components) {
                    // Filter out invalid telemetry with zero latitude AND zero longitude to prevent bogus messages
                    if telemetry.latitude == 0.0 && telemetry.longitude == 0.0 {
                        return
                    }
                    BLEManager.storedFrequency = telemetry.frequency
                    BLEManager.storedType = telemetry.probeType

                    Task { [weak self] in
                        guard let self = self else { return }
                        await MainActor.run {
                            // For message type "1", update sondeSettings with extended fields if present
                            let s = self.sondeSettings
                            let comp = components

                            if comp.count >= 21 {
                                self.sondeSettings.oledSDA = String(comp[20])
                                self.sondeSettings.oledSCL = (comp.count > 21) ? String(comp[21]) : s.oledSCL
                                self.sondeSettings.oledRST = (comp.count > 22) ? String(comp[22]) : s.oledRST
                                self.sondeSettings.ledPin = (comp.count > 23) ? String(comp[23]) : s.ledPin
                                self.sondeSettings.buzPin = (comp.count > 24) ? String(comp[24]) : s.buzPin
                                self.sondeSettings.batPin = (comp.count > 25) ? String(comp[25]) : s.batPin
                                self.sondeSettings.rs41Bandwidth = (comp.count > 26) ? Int(comp[26]) ?? s.rs41Bandwidth : s.rs41Bandwidth
                                self.sondeSettings.m20Bandwidth = (comp.count > 27) ? Int(comp[27]) ?? s.m20Bandwidth : s.m20Bandwidth
                                self.sondeSettings.m10Bandwidth = (comp.count > 28) ? Int(comp[28]) ?? s.m10Bandwidth : s.m10Bandwidth
                                self.sondeSettings.pilotBandwidth = (comp.count > 29) ? Int(comp[29]) ?? s.pilotBandwidth : s.pilotBandwidth
                                self.sondeSettings.dfmBandwidth = (comp.count > 30) ? Int(comp[30]) ?? s.dfmBandwidth : s.dfmBandwidth
                                self.sondeSettings.callSign = (comp.count > 31) ? String(comp[31]) : s.callSign
                                self.sondeSettings.frequencyCorrection = (comp.count > 32) ? String(comp[32]) : s.frequencyCorrection
                                self.sondeSettings.batMin = (comp.count > 33) ? String(comp[33]) : s.batMin
                                self.sondeSettings.batMax = (comp.count > 34) ? String(comp[34]) : s.batMax
                                self.sondeSettings.batType = (comp.count > 35) ? Int(comp[35]) ?? s.batType : s.batType
                                self.sondeSettings.lcdType = (comp.count > 36) ? Int(comp[36]) ?? s.lcdType : s.lcdType
                                self.sondeSettings.nameType = (comp.count > 37) ? Int(comp[37]) ?? s.nameType : s.nameType
                                self.sondeSettings.frequency = telemetry.frequency
                                self.sondeSettings.probeType = Int(telemetry.probeType.filter("0123456789".contains)) ?? s.probeType
                            }
                            UserDefaults.standard.saveSondeSettings(self.sondeSettings)

                            // Vertical speed smoothing now centralized in TelemetryStruct:
                            let smoothedVS = TelemetryStruct.addVerticalSpeedSample(telemetry.verticalSpeed)
                            // Removed assignment to verticalSpeedMovingAverage property (no longer exists)
                        }

                        // Create a new telemetry struct replacing verticalSpeed with the moving average
                        let smoothedVerticalSpeed = TelemetryStruct.addVerticalSpeedSample(telemetry.verticalSpeed)
                        let smoothedTelemetry = TelemetryStruct(
                            probeType: telemetry.probeType,
                            frequency: telemetry.frequency,
                            name: telemetry.name,
                            latitude: telemetry.latitude,
                            longitude: telemetry.longitude,
                            altitude: telemetry.altitude,
                            horizontalSpeed: telemetry.horizontalSpeed,
                            verticalSpeed: smoothedVerticalSpeed, // smoothed vertical speed from TelemetryStruct
                            signalStrength: telemetry.signalStrength,
                            batteryPercentage: telemetry.batteryPercentage,
                            afc: telemetry.afc,
                            burstKiller: telemetry.burstKiller,
                            burstKillerTime: telemetry.burstKillerTime,
                            batteryVoltage: telemetry.batteryVoltage,
                            buzzerMute: telemetry.buzzerMute,
                            firmwareVersion: telemetry.firmwareVersion
                        )

                        await self.telemetryBuffer.update(telemetry: smoothedTelemetry, signalStrength: telemetry.signalStrength, validSignal: true, messageType: messageType)
                    }
                }
            case "2":
                // Parse and update settings and UserDefaults, but do NOT update telemetry (position) for type 2.
                if let telemetry = TelemetryStruct.parseLongFormat(from: components) {
                    // Filter out invalid telemetry with zero latitude AND zero longitude to prevent bogus messages
                    if telemetry.latitude == 0.0 && telemetry.longitude == 0.0 {
                        return
                    }

                    BLEManager.storedFrequency = telemetry.frequency
                    BLEManager.storedType = telemetry.probeType

                    Task { [weak self] in
                        guard let self = self else { return }
                        await MainActor.run {
                            let s = self.sondeSettings
                            let comp = components

                            // Check component count for safety
                            if comp.count >= 21 {
                                self.sondeSettings.oledSDA = String(comp[20])
                                self.sondeSettings.oledSCL = (comp.count > 21) ? String(comp[21]) : s.oledSCL
                                self.sondeSettings.oledRST = (comp.count > 22) ? String(comp[22]) : s.oledRST
                                self.sondeSettings.ledPin = (comp.count > 23) ? String(comp[23]) : s.ledPin
                                self.sondeSettings.buzPin = (comp.count > 24) ? String(comp[24]) : s.buzPin
                                self.sondeSettings.batPin = (comp.count > 25) ? String(comp[25]) : s.batPin
                                self.sondeSettings.rs41Bandwidth = (comp.count > 26) ? Int(comp[26]) ?? s.rs41Bandwidth : s.rs41Bandwidth
                                self.sondeSettings.m20Bandwidth = (comp.count > 27) ? Int(comp[27]) ?? s.m20Bandwidth : s.m20Bandwidth
                                self.sondeSettings.m10Bandwidth = (comp.count > 28) ? Int(comp[28]) ?? s.m10Bandwidth : s.m10Bandwidth
                                self.sondeSettings.pilotBandwidth = (comp.count > 29) ? Int(comp[29]) ?? s.pilotBandwidth : s.pilotBandwidth
                                self.sondeSettings.dfmBandwidth = (comp.count > 30) ? Int(comp[30]) ?? s.dfmBandwidth : s.dfmBandwidth
                                self.sondeSettings.callSign = (comp.count > 31) ? String(comp[31]) : s.callSign
                                self.sondeSettings.frequencyCorrection = (comp.count > 32) ? String(comp[32]) : s.frequencyCorrection
                                self.sondeSettings.batMin = (comp.count > 33) ? String(comp[33]) : s.batMin
                                self.sondeSettings.batMax = (comp.count > 34) ? String(comp[34]) : s.batMax
                                self.sondeSettings.batType = (comp.count > 35) ? Int(comp[35]) ?? s.batType : s.batType
                                self.sondeSettings.lcdType = (comp.count > 36) ? Int(comp[36]) ?? s.lcdType : s.lcdType
                                self.sondeSettings.nameType = (comp.count > 37) ? Int(comp[37]) ?? s.nameType : s.nameType
                                self.sondeSettings.frequency = telemetry.frequency
                                self.sondeSettings.probeType = Int(telemetry.probeType.filter("0123456789".contains)) ?? s.probeType
                            }
                            UserDefaults.standard.saveSondeSettings(self.sondeSettings)
                        }
                    }
                }
            case "3":
                // Parse and update settings for type 3, but do NOT update telemetry (position) for type 3.
                if let telemetry = TelemetryStruct.parseLongFormat(from: components) {
                    // Filter out invalid telemetry with zero latitude AND zero longitude to prevent bogus messages
                    if telemetry.latitude == 0.0 && telemetry.longitude == 0.0 {
                        return
                    }
                    BLEManager.storedFrequency = telemetry.frequency
                    BLEManager.storedType = telemetry.probeType

                    Task { [weak self] in
                        guard let self = self else { return }
                        await MainActor.run {
                            // Indices taken from the type 3 BLE message format specification:
                            // 0: type (skip)
                            // 1: probeType
                            // 2: frequency
                            // 3: oledSDA
                            // 4: oledSCL
                            // 5: oledRST
                            // 6: ledPin
                            // 7: rs41Bandwidth
                            // 8: m20Bandwidth
                            // 9: m10Bandwidth
                            // 10: pilotBandwidth
                            // 11: dfmBandwidth
                            // 12: callSign
                            // 13: frequencyCorrection
                            // 14: batPin
                            // 15: batMin
                            // 16: batMax
                            // 17: batType
                            // 18: lcdType
                            // 19: nameType
                            // 20: buzPin
                            // 21: firmwareVersion (if present)
                            // 22: reserved/end marker

                            let comp = components

                            // Safely assign with checks for component count and conversions
                            if comp.count > 20 {
                                self.sondeSettings.probeType = Int(comp[1].filter("0123456789".contains)) ?? self.sondeSettings.probeType
                                self.sondeSettings.frequency = Double(comp[2]) ?? self.sondeSettings.frequency
                                self.sondeSettings.oledSDA = String(comp[3])
                                self.sondeSettings.oledSCL = String(comp[4])
                                self.sondeSettings.oledRST = String(comp[5])
                                self.sondeSettings.ledPin = String(comp[6])
                                self.sondeSettings.rs41Bandwidth = Int(comp[7]) ?? self.sondeSettings.rs41Bandwidth
                                self.sondeSettings.m20Bandwidth = Int(comp[8]) ?? self.sondeSettings.m20Bandwidth
                                self.sondeSettings.m10Bandwidth = Int(comp[9]) ?? self.sondeSettings.m10Bandwidth
                                self.sondeSettings.pilotBandwidth = Int(comp[10]) ?? self.sondeSettings.pilotBandwidth
                                self.sondeSettings.dfmBandwidth = Int(comp[11]) ?? self.sondeSettings.dfmBandwidth
                                self.sondeSettings.callSign = String(comp[12])
                                self.sondeSettings.frequencyCorrection = String(comp[13])
                                self.sondeSettings.batPin = String(comp[14])
                                self.sondeSettings.batMin = String(comp[15])
                                self.sondeSettings.batMax = String(comp[16])
                                self.sondeSettings.batType = Int(comp[17]) ?? self.sondeSettings.batType
                                self.sondeSettings.lcdType = Int(comp[18]) ?? self.sondeSettings.lcdType
                                self.sondeSettings.nameType = Int(comp[19]) ?? self.sondeSettings.nameType
                                self.sondeSettings.buzPin = String(comp[20])
                                // firmwareVersion at index 21 may be present, but sondeSettings doesn't hold it
                                // So we don't update sondeSettings for firmwareVersion here
                                UserDefaults.standard.saveSondeSettings(self.sondeSettings)
                            }
                            // Debug print for live comparison/debugging of type 3 responses
                            SettingsView().debugPrintType3Settings(self.sondeSettings)
                        }
                    }
                }
            default:
                // For other messages, parse short format telemetry but do NOT update UI position telemetry.
                if var telemetry = TelemetryStruct.parseShortFormat(from: components) {
                    Task { [weak self] in
                        guard let self = self else { return }
                        if let prev = self.latestTelemetry {
                            // Filter out updates where both previous and current latitude and longitude are zero,
                            // to avoid bogus telemetry updates.
                            if prev.latitude == 0.0 && prev.longitude == 0.0 && telemetry.latitude == 0.0 && telemetry.longitude == 0.0 {
                                return
                            }
                            telemetry = TelemetryStruct(
                                probeType: telemetry.probeType,
                                frequency: telemetry.frequency,
                                name: telemetry.name,
                                latitude: prev.latitude,
                                longitude: prev.longitude,
                                altitude: telemetry.altitude,
                                horizontalSpeed: telemetry.horizontalSpeed,
                                verticalSpeed: telemetry.verticalSpeed,
                                signalStrength: telemetry.signalStrength,
                                batteryPercentage: telemetry.batteryPercentage,
                                afc: telemetry.afc,
                                burstKiller: telemetry.burstKiller,
                                burstKillerTime: telemetry.burstKillerTime,
                                batteryVoltage: telemetry.batteryVoltage,
                                buzzerMute: telemetry.buzzerMute,
                                firmwareVersion: telemetry.firmwareVersion
                            )
                        }
                        // Do NOT assign self.latestTelemetry or print telemetry position here.
                        await self.telemetryBuffer.update(telemetry: telemetry, signalStrength: telemetry.signalStrength, validSignal: false, messageType: nil)
                    }
                }
            }
        }
    }
}

extension UserDefaults {
    private static let sondeSettingsKey = "SondeSettingsStructV1"

    func saveSondeSettings(_ settings: SondeSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            set(data, forKey: Self.sondeSettingsKey)
            // print("[DEBUG] Saved SondeSettings to UserDefaults.")
        } else {
            // print("[DEBUG] Failed to encode SondeSettings.")
        }
    }

    func loadSondeSettings() -> SondeSettings? {
        if let data = data(forKey: Self.sondeSettingsKey),
           let settings = try? JSONDecoder().decode(SondeSettings.self, from: data) {
            // print("[DEBUG] Loaded SondeSettings from UserDefaults.")
            return settings
        } else {
            // print("[DEBUG] No SondeSettings in UserDefaults (or decode failed). Returning nil.")
            return nil
        }
    }
}

