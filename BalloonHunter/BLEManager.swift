import Foundation
import Combine
import CoreBluetooth

struct SondeSettings: Codable, Equatable, CustomStringConvertible {
    // General Settings
    var lcd: Int = 0
    var lcdOn: Int = 1
    var blu: Int = 1
    var baud: Int = 1
    var com: Int = 0
    var myCall: String = "MYCALL"
    var freqofs: String = "0"
    var aprsName: Int = 0

    // Pin Assignments
    var oled_sda: String = "21"
    var oled_scl: String = "22"
    var oled_rst: String = "16"
    var led_pout: String = "25"
    var buz_pin: String = "0"
    var battery: String = "35"

    // Radio Reception Bandwidth
    var rs41_rxbw: Int = 1
    var m20_rxbw: Int = 7
    var m10_rxbw: Int = 7
    var pilot_rxbw: Int = 7
    var dfm_rxbw: Int = 6

    // Battery Calibration
    var vBatMin: String = "2950"
    var vBatMax: String = "4180"
    var vBatType: Int = 1

    // Other Direct Control Commands
    var frequency: Double = 404.600
    var tipo: Int = 1
    var mute: Int = -1 // -1 = not installed

    var description: String {
        "lcd: \(lcd), lcdOn: \(lcdOn), blu: \(blu), baud: \(baud), com: \(com), myCall: \(myCall), freqofs: \(freqofs), aprsName: \(aprsName), oled_sda: \(oled_sda), oled_scl: \(oled_scl), oled_rst: \(oled_rst), led_pout: \(led_pout), buz_pin: \(buz_pin), battery: \(battery), rs41_rxbw: \(rs41_rxbw), m20_rxbw: \(m20_rxbw), m10_rxbw: \(m10_rxbw), pilot_rxbw: \(pilot_rxbw), dfm_rxbw: \(dfm_rxbw), vBatMin: \(vBatMin), vBatMax: \(vBatMax), vBatType: \(vBatType), frequency: \(frequency), tipo: \(tipo), mute: \(mute)"
    }
}

// MARK: - Telemetry Model
struct Telemetry: Equatable {
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

    static func parseLongFormat(from components: [Substring]) -> Telemetry? {
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
        return Telemetry(
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

    static func parseShortFormat(from components: [Substring]) -> Telemetry? {
        guard components.count >= 8 else { return nil }
        let probeType = String(components[1])
        let frequency = Double(components[2]) ?? 0
        let altitude = Double(components[3]) ?? 0
        let batteryPercentage = Int(components[4]) ?? 0
        let afc = Int(components[5]) ?? 0
        let burstKiller = (components[6] == "1")
        let firmwareVersion = String(components[7])

        return Telemetry(
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
}

// MARK: - TelemetryBuffer Actor
actor TelemetryBuffer {
    private var bufferedTelemetry: Telemetry?
    private var bufferedSignalStrength: Double?
    private var bufferedValidSignal: Bool?
    private var bufferedReceivedText: String = ""
    private var bufferedIsConnected: Bool? = nil

    private var continuation: AsyncStream<Void>.Continuation? = nil

    func updatesStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func notify() {
        continuation?.yield()
    }

    func update(telemetry: Telemetry?, signalStrength: Double?, validSignal: Bool?) {
        self.bufferedTelemetry = telemetry
        self.bufferedSignalStrength = signalStrength
        self.bufferedValidSignal = validSignal
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

    func flush() -> (Telemetry?, Double?, Bool?, String, Bool?) {
        defer {
            bufferedTelemetry = nil
            bufferedSignalStrength = nil
            bufferedValidSignal = nil
            bufferedReceivedText = ""
            bufferedIsConnected = nil
        }
        return (bufferedTelemetry, bufferedSignalStrength, bufferedValidSignal, bufferedReceivedText, bufferedIsConnected)
    }
}

// MARK: - BLEManager
class BLEManager: NSObject, ObservableObject {
    static let shared = BLEManager()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var uartCharacteristics: [CBCharacteristic] = []
    
    private var didSendSettingsRequest = false

    @Published var isConnected = false
    @Published var receivedText = ""
    @Published var latestTelemetry: Telemetry? = nil
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
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)

        Task { [weak self] in
            guard let self = self else { return }
            for await _ in self.telemetryBuffer.updatesStream() {
                let (telemetry, signalStrength, validSignal, receivedText, isConnected) = await self.telemetryBuffer.flush()
                let uiUpdateStart = Date()
                await MainActor.run {
                    if let t = telemetry {
                        self.latestTelemetry = t
                        // Updating frequency and tipo here is silent (no prints)
                        self.sondeSettings.frequency = t.frequency
                        self.sondeSettings.tipo = Int(t.probeType.filter("0123456789".contains)) ?? self.sondeSettings.tipo
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
        print("[BLE DEBUG] Scanning for BLE devices...")
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
        if central.state == .poweredOn {
            connect()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
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
            print("[DEBUG] BLE Rx: \(text)")
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
                // Regardless of parse, if first /0 message and didSendSettingsRequest == false, send "?"
                if !didSendSettingsRequest {
                    print("[BLE DEBUG] First /0 message received. Sending '?' command to request settings.")
                    didSendSettingsRequest = true
                    sendCommand("?")
                }
                if let telemetry = Telemetry.parseLongFormat(from: components) {
                    print("[DEBUG] /0 msg: probeType=\(telemetry.probeType) frequency=\(telemetry.frequency) name=\(telemetry.name) lat=\(telemetry.latitude) lon=\(telemetry.longitude) alt=\(telemetry.altitude) hSpeed=\(telemetry.horizontalSpeed) vSpeed=\(telemetry.verticalSpeed) signal=\(telemetry.signalStrength) batt=\(telemetry.batteryPercentage) afc=\(telemetry.afc) burstKiller=\(telemetry.burstKiller) burstKillerTime=\(telemetry.burstKillerTime) batteryVoltage=\(telemetry.batteryVoltage) buzzerMute=\(telemetry.buzzerMute) firmware=\(telemetry.firmwareVersion)")
                    print("[BLE DEBUG] Type 0: probeType=\(telemetry.probeType) freq=\(telemetry.frequency) alt=\(telemetry.altitude) batt=\(telemetry.batteryPercentage)% ver=\(telemetry.firmwareVersion)")

                    print("[DEBUG] Before persist: UserDefaults frequency:", UserDefaults.standard.double(forKey: "StoredSondeFrequency"), "type:", UserDefaults.standard.string(forKey: "StoredSondeType") ?? "nil")
                    BLEManager.storedFrequency = telemetry.frequency
                    BLEManager.storedType = telemetry.probeType
                    print("[DEBUG] After persist: UserDefaults frequency:", UserDefaults.standard.double(forKey: "StoredSondeFrequency"), "type:", UserDefaults.standard.string(forKey: "StoredSondeType") ?? "nil")
                    print("[DEBUG] Persisted frequency: \(telemetry.frequency)")
                    print("[DEBUG] Persisted probeType: \(telemetry.probeType)")

                    Task { [weak self] in
                        guard let self = self else { return }
                        await MainActor.run {
                            let s = self.sondeSettings
                            let comp = components

                            // Check component count for safety
                            if comp.count >= 21 {
                                self.sondeSettings.oled_sda = String(comp[20])
                                self.sondeSettings.oled_scl = (comp.count > 21) ? String(comp[21]) : s.oled_scl
                                self.sondeSettings.oled_rst = (comp.count > 22) ? String(comp[22]) : s.oled_rst
                                self.sondeSettings.led_pout = (comp.count > 23) ? String(comp[23]) : s.led_pout
                                self.sondeSettings.buz_pin = (comp.count > 24) ? String(comp[24]) : s.buz_pin
                                self.sondeSettings.battery = (comp.count > 25) ? String(comp[25]) : s.battery
                                self.sondeSettings.rs41_rxbw = (comp.count > 26) ? Int(comp[26]) ?? s.rs41_rxbw : s.rs41_rxbw
                                self.sondeSettings.m20_rxbw = (comp.count > 27) ? Int(comp[27]) ?? s.m20_rxbw : s.m20_rxbw
                                self.sondeSettings.m10_rxbw = (comp.count > 28) ? Int(comp[28]) ?? s.m10_rxbw : s.m10_rxbw
                                self.sondeSettings.pilot_rxbw = (comp.count > 29) ? Int(comp[29]) ?? s.pilot_rxbw : s.pilot_rxbw
                                self.sondeSettings.dfm_rxbw = (comp.count > 30) ? Int(comp[30]) ?? s.dfm_rxbw : s.dfm_rxbw
                                self.sondeSettings.myCall = (comp.count > 31) ? String(comp[31]) : s.myCall
                                self.sondeSettings.freqofs = (comp.count > 32) ? String(comp[32]) : s.freqofs
                                self.sondeSettings.vBatMin = (comp.count > 33) ? String(comp[33]) : s.vBatMin
                                self.sondeSettings.vBatMax = (comp.count > 34) ? String(comp[34]) : s.vBatMax
                                self.sondeSettings.vBatType = (comp.count > 35) ? Int(comp[35]) ?? s.vBatType : s.vBatType
                                self.sondeSettings.lcd = (comp.count > 36) ? Int(comp[36]) ?? s.lcd : s.lcd
                                self.sondeSettings.aprsName = (comp.count > 37) ? Int(comp[37]) ?? s.aprsName : s.aprsName
                                self.sondeSettings.frequency = telemetry.frequency
                                self.sondeSettings.tipo = Int(telemetry.probeType.filter("0123456789".contains)) ?? s.tipo
                            }
                            UserDefaults.standard.saveSondeSettings(self.sondeSettings)
                            // Removed prints here for sondeSettings update in case "0"
                        }
                        await self.telemetryBuffer.update(telemetry: telemetry, signalStrength: telemetry.signalStrength, validSignal: true)
                    }
                }
            case "1", "2", "3":
                if let telemetry = Telemetry.parseLongFormat(from: components) {

                    print("[BLE DEBUG] Type \(messageType): probeType=\(telemetry.probeType) freq=\(telemetry.frequency) alt=\(telemetry.altitude) batt=\(telemetry.batteryPercentage)% ver=\(telemetry.firmwareVersion)")

                    // Removed debug prints only if messageType == "3":
                    if messageType != "3" {
                        print("[DEBUG] Before persist: UserDefaults frequency:", UserDefaults.standard.double(forKey: "StoredSondeFrequency"), "type:", UserDefaults.standard.string(forKey: "StoredSondeType") ?? "nil")
                        BLEManager.storedFrequency = telemetry.frequency
                        BLEManager.storedType = telemetry.probeType
                        print("[DEBUG] After persist: UserDefaults frequency:", UserDefaults.standard.double(forKey: "StoredSondeFrequency"), "type:", UserDefaults.standard.string(forKey: "StoredSondeType") ?? "nil")
                        print("[DEBUG] Persisted frequency: \(telemetry.frequency)")
                        print("[DEBUG] Persisted probeType: \(telemetry.probeType)")
                    } else {
                        BLEManager.storedFrequency = telemetry.frequency
                        BLEManager.storedType = telemetry.probeType
                    }

                    Task { [weak self] in
                        guard let self = self else { return }
                        await MainActor.run {
                            let s = self.sondeSettings
                            let comp = components

                            // Check component count for safety
                            if comp.count >= 21 {
                                self.sondeSettings.oled_sda = String(comp[20])
                                self.sondeSettings.oled_scl = (comp.count > 21) ? String(comp[21]) : s.oled_scl
                                self.sondeSettings.oled_rst = (comp.count > 22) ? String(comp[22]) : s.oled_rst
                                self.sondeSettings.led_pout = (comp.count > 23) ? String(comp[23]) : s.led_pout
                                self.sondeSettings.buz_pin = (comp.count > 24) ? String(comp[24]) : s.buz_pin
                                self.sondeSettings.battery = (comp.count > 25) ? String(comp[25]) : s.battery
                                self.sondeSettings.rs41_rxbw = (comp.count > 26) ? Int(comp[26]) ?? s.rs41_rxbw : s.rs41_rxbw
                                self.sondeSettings.m20_rxbw = (comp.count > 27) ? Int(comp[27]) ?? s.m20_rxbw : s.m20_rxbw
                                self.sondeSettings.m10_rxbw = (comp.count > 28) ? Int(comp[28]) ?? s.m10_rxbw : s.m10_rxbw
                                self.sondeSettings.pilot_rxbw = (comp.count > 29) ? Int(comp[29]) ?? s.pilot_rxbw : s.pilot_rxbw
                                self.sondeSettings.dfm_rxbw = (comp.count > 30) ? Int(comp[30]) ?? s.dfm_rxbw : s.dfm_rxbw
                                self.sondeSettings.myCall = (comp.count > 31) ? String(comp[31]) : s.myCall
                                self.sondeSettings.freqofs = (comp.count > 32) ? String(comp[32]) : s.freqofs
                                self.sondeSettings.vBatMin = (comp.count > 33) ? String(comp[33]) : s.vBatMin
                                self.sondeSettings.vBatMax = (comp.count > 34) ? String(comp[34]) : s.vBatMax
                                self.sondeSettings.vBatType = (comp.count > 35) ? Int(comp[35]) ?? s.vBatType : s.vBatType
                                self.sondeSettings.lcd = (comp.count > 36) ? Int(comp[36]) ?? s.lcd : s.lcd
                                self.sondeSettings.aprsName = (comp.count > 37) ? Int(comp[37]) ?? s.aprsName : s.aprsName
                                self.sondeSettings.frequency = telemetry.frequency
                                self.sondeSettings.tipo = Int(telemetry.probeType.filter("0123456789".contains)) ?? s.tipo
                            }
                            UserDefaults.standard.saveSondeSettings(self.sondeSettings)
                            // Only print sondeSettings update if messageType == "3"
                            if messageType == "3" {
                                print("[BLE DEBUG] Received 3/ message: \(text)")
                                // Removed detailed debug prints and field-by-field output per instructions
                            }
                        }
                        await self.telemetryBuffer.update(telemetry: telemetry, signalStrength: telemetry.signalStrength, validSignal: true)
                    }
                }
            default:
                if var telemetry = Telemetry.parseShortFormat(from: components) {
                    print("[BLE DEBUG] Type \(messageType): probeType=\(telemetry.probeType) freq=\(telemetry.frequency) alt=\(telemetry.altitude) batt=\(telemetry.batteryPercentage)% ver=\(telemetry.firmwareVersion)")
                    Task { [weak self] in
                        guard let self = self else { return }
                        if let prev = self.latestTelemetry {
                            telemetry = Telemetry(
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
                        await self.telemetryBuffer.update(telemetry: telemetry, signalStrength: telemetry.signalStrength, validSignal: false)
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
            print("[DEBUG] Saved SondeSettings to UserDefaults.")
        } else {
            print("[DEBUG] Failed to encode SondeSettings.")
        }
    }

    func loadSondeSettings() -> SondeSettings? {
        if let data = data(forKey: Self.sondeSettingsKey),
           let settings = try? JSONDecoder().decode(SondeSettings.self, from: data) {
            print("[DEBUG] Loaded SondeSettings from UserDefaults.")
            return settings
        } else {
            print("[DEBUG] No SondeSettings in UserDefaults (or decode failed). Returning nil.")
            return nil
        }
    }
}

