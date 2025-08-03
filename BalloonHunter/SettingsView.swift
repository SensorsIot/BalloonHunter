import SwiftUI
import CoreBluetooth
import Combine
import OSLog

// Local Settings struct for editing, mirrors SondeSettings fields used in UI
struct EditableSettings {
    var lcdType: Int
    var oledSDA: String
    var oledSCL: String
    var oledRST: String
    var buzPin: String
    var ledPin: String
    var batPin: String
    
    var batMin: String
    var batMax: String
    var batType: Int
    
    var callSign: String
    var rs41Bandwidth: Int
    var m10Bandwidth: Int
    var m20Bandwidth: Int
    var pilotBandwidth: Int
    var dfmBandwidth: Int
    var frequencyCorrection: String
    var nameType: Int
    
    var lcdOn: Int
    var blu: Int
    var baud: Int
    var com: Int
    
    // Added optional prediction settings
    var burstAltitude: String?
    var ascentRate: String?
    var descentRate: String?
    
    // Initialize from SondeSettings
    init(from sondeSettings: SondeSettings) {
        lcdType = sondeSettings.lcdType
        oledSDA = sondeSettings.oledSDA
        oledSCL = sondeSettings.oledSCL
        oledRST = sondeSettings.oledRST
        buzPin = sondeSettings.buzPin
        ledPin = sondeSettings.ledPin
        batPin = sondeSettings.batPin
        
        batMin = sondeSettings.batMin
        batMax = sondeSettings.batMax
        batType = sondeSettings.batType
        
        callSign = sondeSettings.callSign
        rs41Bandwidth = sondeSettings.rs41Bandwidth
        m10Bandwidth = sondeSettings.m10Bandwidth
        m20Bandwidth = sondeSettings.m20Bandwidth
        pilotBandwidth = sondeSettings.pilotBandwidth
        dfmBandwidth = sondeSettings.dfmBandwidth
        frequencyCorrection = sondeSettings.frequencyCorrection
        nameType = sondeSettings.nameType
        
        lcdOn = sondeSettings.lcdOn
        blu = sondeSettings.blu
        baud = sondeSettings.baud
        com = sondeSettings.com
        
        // Initialize optional prediction settings if available
        // Removed assignments to burstAltitude, ascentRate, descentRate as per instructions
    }
    
    // Convert back to SondeSettings
    func toSondeSettings(_ sondeSettings: inout SondeSettings) {
        sondeSettings.lcdType = lcdType
        sondeSettings.oledSDA = oledSDA
        sondeSettings.oledSCL = oledSCL
        sondeSettings.oledRST = oledRST
        sondeSettings.buzPin = buzPin
        sondeSettings.ledPin = ledPin
        sondeSettings.batPin = batPin
        
        sondeSettings.batMin = batMin
        sondeSettings.batMax = batMax
        sondeSettings.batType = batType
        
        sondeSettings.callSign = callSign
        sondeSettings.rs41Bandwidth = rs41Bandwidth
        sondeSettings.m10Bandwidth = m10Bandwidth
        sondeSettings.m20Bandwidth = m20Bandwidth
        sondeSettings.pilotBandwidth = pilotBandwidth
        sondeSettings.dfmBandwidth = dfmBandwidth
        sondeSettings.frequencyCorrection = frequencyCorrection
        sondeSettings.nameType = nameType
        
        sondeSettings.lcdOn = lcdOn
        sondeSettings.blu = blu
        sondeSettings.baud = baud
        sondeSettings.com = com
        
        // Save optional prediction settings if present
        // Removed assignments to sondeSettings.burstAltitude, ascentRate, descentRate as per instructions
    }
}

// Assuming BLEManager is defined elsewhere for sending commands
// For example:

// Define PredictionSettings as an ObservableObject singleton for prediction parameters
class PredictionSettings: ObservableObject {
    static let shared = PredictionSettings()
    
    @Published var burstAltitude: String = "" {
        didSet {
            UserDefaults.standard.set(burstAltitude, forKey: "burstAltitude")
        }
    }
    @Published var ascentRate: String = "" {
        didSet {
            UserDefaults.standard.set(ascentRate, forKey: "ascentRate")
        }
    }
    @Published var descentRate: String = "" {
        didSet {
            UserDefaults.standard.set(descentRate, forKey: "descentRate")
        }
    }
    
    private init() {
        let defaults = UserDefaults.standard
        let defaultBurstAltitude = "35000"
        let defaultAscentRate = "5.0"
        let defaultDescentRate = "5.0"
        
        if let savedBurstAltitude = defaults.string(forKey: "burstAltitude"), !savedBurstAltitude.isEmpty {
            burstAltitude = savedBurstAltitude
        } else {
            burstAltitude = defaultBurstAltitude
            defaults.set(defaultBurstAltitude, forKey: "burstAltitude")
        }
        
        if let savedAscentRate = defaults.string(forKey: "ascentRate"), !savedAscentRate.isEmpty {
            ascentRate = savedAscentRate
        } else {
            ascentRate = defaultAscentRate
            defaults.set(defaultAscentRate, forKey: "ascentRate")
        }
        
        if let savedDescentRate = defaults.string(forKey: "descentRate"), !savedDescentRate.isEmpty {
            descentRate = savedDescentRate
        } else {
            descentRate = defaultDescentRate
            defaults.set(defaultDescentRate, forKey: "descentRate")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var bleManager: BLEManager = .shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var settings: EditableSettings = EditableSettings(from: BLEManager.shared.sondeSettings)
    @ObservedObject var predictionSettings = PredictionSettings.shared
    
    private var rs41BandwidthBinding: Binding<String> {
        Binding(get: { String(self.settings.rs41Bandwidth) }, set: { self.settings.rs41Bandwidth = Int($0) ?? 0 })
    }
    private var m10BandwidthBinding: Binding<String> {
        Binding(get: { String(self.settings.m10Bandwidth) }, set: { self.settings.m10Bandwidth = Int($0) ?? 0 })
    }
    private var m20BandwidthBinding: Binding<String> {
        Binding(get: { String(self.settings.m20Bandwidth) }, set: { self.settings.m20Bandwidth = Int($0) ?? 0 })
    }
    private var pilotBandwidthBinding: Binding<String> {
        Binding(get: { String(self.settings.pilotBandwidth) }, set: { self.settings.pilotBandwidth = Int($0) ?? 0 })
    }
    private var dfmBandwidthBinding: Binding<String> {
        Binding(get: { String(self.settings.dfmBandwidth) }, set: { self.settings.dfmBandwidth = Int($0) ?? 0 })
    }
    
    var body: some View {
        NavigationView {
            TabView {
                // MARK: Pins Tab
                PinsSettingsView(
                    lcdType: $settings.lcdType,
                    oled_sda: $settings.oledSDA,
                    oled_scl: $settings.oledSCL,
                    oled_rst: $settings.oledRST,
                    buz_pin: $settings.buzPin,
                    led_pout: $settings.ledPin,
                    batteryPin: $settings.batPin
                )
                .tabItem {
                    Label("Pins", systemImage: "pin.fill")
                }
                
                // MARK: Battery Tab
                BatterySettingsView(
                    vBatMin: $settings.batMin,
                    vBatMax: $settings.batMax,
                    vBatType: $settings.batType
                )
                .tabItem {
                    Label("Battery", systemImage: "battery.100")
                }
                
                // MARK: Radio Tab
                RadioSettingsView(
                    myCall: $settings.callSign,
                    rs41Bandwidth: rs41BandwidthBinding,
                    m10Bandwidth: m10BandwidthBinding,
                    m20Bandwidth: m20BandwidthBinding,
                    pilotBandwidth: pilotBandwidthBinding,
                    dfmBandwidth: dfmBandwidthBinding,
                    freqofs: $settings.frequencyCorrection
                )
                .tabItem {
                    Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
                }
                
                // MARK: Other Settings Tab (combining general controls and actions)
                OtherSettingsView(
                    lcdOn: $settings.lcdOn,
                    blu: $settings.blu,
                    baud: $settings.baud,
                    com: $settings.com,
                    aprsName: $settings.nameType
                )
                .tabItem {
                    Label("Other", systemImage: "gearshape")
                }
                
                // MARK: Prediction Tab
                PredictionSettingsView(
                    burstAltitude: $predictionSettings.burstAltitude,
                    ascentRate: $predictionSettings.ascentRate,
                    descentRate: $predictionSettings.descentRate
                )
                .tabItem {
                    Label("Prediction", systemImage: "waveform.path.ecg")
                }
            }
            .navigationTitle("Settings") // From screenshot
            .navigationBarTitleDisplayMode(.inline) // Compact title
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(action: {
                            // Convert local settings back to BLEManager's sondeSettings
                            settings.toSondeSettings(&bleManager.sondeSettings)
                            BLEManager.shared.sendCommand(buildBLECommandFromSettings(settings))
                            // Save prediction settings immediately
                            savePredictionSettings()
                            dismiss()
                        }) {
                            Text("Save")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Initialize local settings from BLEManager at time of appearance
            settings = EditableSettings(from: BLEManager.shared.sondeSettings)
            // Removed resetting predictionSettings.burstAltitude, ascentRate, descentRate to empty strings
        }
        // Save prediction settings immediately when any changes happen
        .onChange(of: predictionSettings.burstAltitude) { _ in savePredictionSettings() }
        .onChange(of: predictionSettings.ascentRate) { _ in savePredictionSettings() }
        .onChange(of: predictionSettings.descentRate) { _ in savePredictionSettings() }
    }
    
    private func savePredictionSettings() {
        // Save prediction settings into BLEManager's sondeSettings immediately
        // Removed assignments to sondeSettings as per instructions
        
        // Optionally send commands to BLEManager if required
        BLEManager.shared.sendCommand("burstAltitude=\(predictionSettings.burstAltitude)")
        BLEManager.shared.sendCommand("ascentRate=\(predictionSettings.ascentRate)")
        BLEManager.shared.sendCommand("descentRate=\(predictionSettings.descentRate)")
    }
    
    private func buildBLECommandFromSettings(_ settings: EditableSettings) -> String {
        let tipo = settings.lcdType
        let f = 0
        let aprsName = settings.nameType
        let oled_sda = settings.oledSDA
        let oled_scl = settings.oledSCL
        let oled_rst = settings.oledRST
        let led_pout = settings.ledPin
        let rs41_rxbw = settings.rs41Bandwidth
        let m20_rxbw = settings.m20Bandwidth
        let m10_rxbw = settings.m10Bandwidth
        let pilot_rxbw = settings.pilotBandwidth
        let dfm_rxbw = settings.dfmBandwidth
        let myCall = settings.callSign
        let freqofs = settings.frequencyCorrection
        let battery = settings.batPin
        let vBatMin = settings.batMin
        let vBatMax = settings.batMax
        let vBatType = settings.batType
        let lcd = settings.lcdType
        let buz_pin = settings.buzPin
        let lcdOn = settings.lcdOn
        let blu = settings.blu
        let com = settings.com
        let baud = settings.baud
        
        var parts = [
            "tipo=\(tipo)",
            "f=\(f)",
            "aprsName=\(aprsName)",
            "oled_sda=\(oled_sda)",
            "oled_scl=\(oled_scl)",
            "oled_rst=\(oled_rst)",
            "led_pout=\(led_pout)",
            "rs41.rxbw=\(rs41_rxbw)",
            "m20.rxbw=\(m20_rxbw)",
            "m10.rxbw=\(m10_rxbw)",
            "pilot.rxbw=\(pilot_rxbw)",
            "dfm.rxbw=\(dfm_rxbw)",
            "myCall=\(myCall)",
            "freqofs=\(freqofs)",
            "battery=\(battery)",
            "vBatMin=\(vBatMin)",
            "vBatMax=\(vBatMax)",
            "vBatType=\(vBatType)",
            "lcd=\(lcd)",
            "buz_pin=\(buz_pin)",
            "lcdOn=\(lcdOn)",
            "blu=\(blu)",
            "com=\(com)",
            "baud=\(baud)"
        ]
        
        // Append prediction settings if present
        if let burst = settings.burstAltitude {
            parts.append("burstAltitude=\(burst)")
        }
        if let ascent = settings.ascentRate {
            parts.append("ascentRate=\(ascent)")
        }
        if let descent = settings.descentRate {
            parts.append("descentRate=\(descent)")
        }
        
        return parts.joined(separator: "/")
    }
    
    // Debug print function for SondeSettings type 3 message
    func debugPrintType3Settings(_ settings: SondeSettings) {
        print("[TYPE 3 DEBUG] probeType=\(settings.probeType), frequency=\(settings.frequency), oledSDA=\(settings.oledSDA), oledSCL=\(settings.oledSCL), oledRST=\(settings.oledRST), buzPin=\(settings.buzPin), ledPin=\(settings.ledPin), batPin=\(settings.batPin), batMin=\(settings.batMin), batMax=\(settings.batMax), batType=\(settings.batType), callSign=\(settings.callSign), rs41Bandwidth=\(settings.rs41Bandwidth), m10Bandwidth=\(settings.m10Bandwidth), m20Bandwidth=\(settings.m20Bandwidth), pilotBandwidth=\(settings.pilotBandwidth), dfmBandwidth=\(settings.dfmBandwidth), frequencyCorrection=\(settings.frequencyCorrection), nameType=\(settings.nameType), lcdOn=\(settings.lcdOn), blu=\(settings.blu), baud=\(settings.baud), com=\(settings.com)")
    }
    // Suggestion: Call debugPrintType3Settings with latest SondeSettings when a type 3 message is received elsewhere in your code.
}

//// MARK: - PredictionSettingsView (New tab view for prediction settings)
struct PredictionSettingsView: View {
    @Binding var burstAltitude: String
    @Binding var ascentRate: String
    @Binding var descentRate: String
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Section(header: Text("Prediction Settings").font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledNumberField(label: "Burst Altitude (m)", text: $burstAltitude)
                        LabeledNumberField(label: "Ascent Rate (m/s)", text: $ascentRate)
                        LabeledNumberField(label: "Descent Rate (m/s)", text: $descentRate)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Prediction")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Helper view for labeled number input fields with decimalPad keyboard
struct LabeledNumberField: View {
    let label: String
    @Binding var text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(label, text: $text)
                .keyboardType(.decimalPad)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
        }
    }
}

//// MARK: - PinsSettingsView (unchanged from previous)
struct PinsSettingsView: View {
    @Binding var lcdType: Int // Mapped to LCD-TYPE [cite: 298]
    @Binding var oled_sda: String // Mapped to OLED-SDA [cite: 284]
    @Binding var oled_scl: String // Mapped to OLED-SCL [cite: 285]
    @Binding var oled_rst: String // Mapped to OLED-RST [cite: 286]
    @Binding var buz_pin: String // Mapped to BUZ-PIN [cite: 300]
    @Binding var led_pout: String // Mapped to LED-PIN [cite: 287]
    @Binding var batteryPin: String // Mapped to BAT-PIN [cite: 294]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Section(header: Text("Display & Call").font(.headline)) {
                    Picker("LCD Driver", selection: $lcdType) { // LCD-TYPE
                        Text("SSD1306_128X64").tag(0) // [cite: 298]
                        Text("SH1106_128X64").tag(1) // [cite: 298]
                    }
                    .pickerStyle(.menu)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                }
                .padding(.bottom, 12)
                
                Section(header: Text("Pin Assignments").font(.headline)) {
                    HStack(spacing: 32) {
                        PinInputField(label: "SDA pin", text: $oled_sda, placeholder: "21") // OLED-SDA [cite: 284]
                        PinInputField(label: "SCL pin", text: $oled_scl, placeholder: "22") // OLED-SCL [cite: 285]
                    }
                    HStack(spacing: 32) {
                        PinInputField(label: "RST pin", text: $oled_rst, placeholder: "16") // OLED-RST [cite: 286]
                        PinInputField(label: "Buzzer pin", text: $buz_pin, placeholder: "4") // BUZ-PIN [cite: 300]
                    }
                    HStack(spacing: 32) {
                        PinInputField(label: "LED pin", text: $led_pout, placeholder: "25") // LED-PIN [cite: 287]
                        PinInputField(label: "Battery pin", text: $batteryPin, placeholder: "35") // BAT-PIN [cite: 294]
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Pins")
        .navigationBarTitleDisplayMode(.inline)
    }
}

//// Helper struct for consistent pin input fields (unchanged)
struct PinInputField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(placeholder, text: $text)
                .keyboardType(.numberPad)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
        }
    }
}

//// MARK: - BatterySettingsView (unchanged from previous)
struct BatterySettingsView: View {
    @Binding var vBatMin: String // BAT-MIN [cite: 295]
    @Binding var vBatMax: String // BAT-MAX [cite: 296]
    @Binding var vBatType: Int // BAT-TYPE [cite: 297]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Section(header: Text("Battery Levels (mV)").font(.headline)) {
                    HStack(spacing: 32) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Min (mV)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("2950", text: $vBatMin) // BAT-MIN
                                .keyboardType(.numberPad)
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Max (mV)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("4180", text: $vBatMax) // BAT-MAX
                                .keyboardType(.numberPad)
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                        }
                    }
                }
                
                Section(header: Text("Discharge Type").font(.headline)) {
                    Picker("Battery Discharge Type", selection: $vBatType) { // BAT-TYPE
                        Text("Linear").tag(0) // [cite: 297]
                        Text("Sigmoidal").tag(1) // [cite: 297]
                        Text("Asigmoidal").tag(2) // [cite: 297]
                    }
                    .pickerStyle(.menu)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                }
            }
            .padding(24)
        }
        .navigationTitle("Battery")
        .navigationBarTitleDisplayMode(.inline)
    }
}

//// MARK: - RadioSettingsView (updated parameter types for rx bandwidths)
struct RadioSettingsView: View {
    @Binding var myCall: String // MYCALL [cite: 292]
    var rs41Bandwidth: Binding<String> // RS41-BAND [cite: 288]
    var m10Bandwidth: Binding<String> // M10-BAND [cite: 290]
    var m20Bandwidth: Binding<String> // M20-BAND [cite: 289]
    var pilotBandwidth: Binding<String> // PILOT-BAND [cite: 266]
    var dfmBandwidth: Binding<String> // DFM-BAND [cite: 291]
    @Binding var freqofs: String // FREQ-OFS [cite: 293]
    
    // Frequency options from Appendix 2 [cite: 366, 367, 368, 369, 370, 371, 372, 373, 374, 375, 376, 377, 378, 379, 380, 381, 382, 383, 384, 385]
    static let freqOptions = [
        "2.6 kHz", "3.1 kHz", "3.9 kHz", "5.2 kHz", "6.3 kHz", "7.8 kHz",
        "10.4 kHz", "12.5 kHz", "15.6 kHz", "20.8 kHz", "25.0 kHz", "31.3 kHz",
        "41.7 kHz", "50.0 kHz", "62.5 kHz", "83.3 kHz", "100.0 kHz", "125.0 kHz",
        "166.7 kHz", "200.0 kHz"
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Section(header: Text("Callsign").font(.headline)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("My Call (max 8 chars)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("BUBI", text: $myCall) // MYCALL [cite: 292]
                            .onChange(of: myCall) { newValue in
                                let uppercasedValue = newValue.uppercased()
                                if uppercasedValue.count > 8 {
                                    myCall = String(uppercasedValue.prefix(8))
                                } else {
                                    myCall = uppercasedValue
                                }
                            }
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                    }
                }
                
                Section(header: Text("Rx Bandwidth (kHz)").font(.headline)) {
                    HStack(spacing: 32) {
                        RxBandwidthPicker(label: "RS41", selection: rs41Bandwidth, options: Self.freqOptions) // RS41-BAND [cite: 288]
                        RxBandwidthPicker(label: "M10", selection: m10Bandwidth, options: Self.freqOptions) // M10-BAND [cite: 290]
                    }
                    HStack(spacing: 32) {
                        RxBandwidthPicker(label: "M20", selection: m20Bandwidth, options: Self.freqOptions) // M20-BAND [cite: 289]
                        RxBandwidthPicker(label: "DFM", selection: dfmBandwidth, options: Self.freqOptions) // DFM-BAND [cite: 291]
                    }
                    HStack(spacing: 32) {
                        RxBandwidthPicker(label: "PILOT", selection: pilotBandwidth, options: Self.freqOptions) // PILOT-BAND [cite: 266]
                        Spacer()
                    }
                }
                
                Section(header: Text("Frequency Offset").font(.headline)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Frequency Correction (Hz)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            TextField("0", text: $freqofs) // FREQ-OFS [cite: 293]
                                .keyboardType(.numbersAndPunctuation)
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                            Button(action: {
                                BLEManager.shared.sendCommand("freqofs=\(freqofs)") // [cite: 330] Example command
                            }) {
                                Text("TUNE")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Radio")
        .navigationBarTitleDisplayMode(.inline)
    }
}

//// Helper struct for consistent Rx Bandwidth pickers (unchanged)
struct RxBandwidthPicker: View {
    let label: String
    @Binding var selection: String // Bound to the String representation of the index
    let options: [String]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Picker(label, selection: Binding<Int>( // Bind to Int for picker, convert to String for storage
                get: { Int(selection) ?? 0 }, // Get the integer tag from the string
                set: { selection = String($0) } // Store the integer tag as a string
            )) {
                ForEach(0..<options.count, id: \.self) { index in
                    Text(options[index]).tag(index) // Display full string, tag with index
                }
            }
            .pickerStyle(.menu)
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
        }
    }
}

//// MARK: - OtherSettingsView (renamed from OthersSettingsView and includes general controls & actions)
struct OtherSettingsView: View {
    @Binding var lcdOn: Int // LCDON [cite: 303]
    @Binding var blu: Int // BLUON [cite: 304]
    @Binding var baud: Int // BAUD [cite: 306]
    @Binding var com: Int // COM [cite: 305]
    @Binding var aprsName: Int // NAME-TYPE (Note: This is also in RadioSettingsView; review if it should be unique to one place.) [cite: 299]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: General Controls
                Section(header: Text("General Controls").font(.headline)) {
                    HStack(spacing: 24) {
                        ToggleSettingPicker(label: "LCD On/Off", selection: $lcdOn) // LCDON [cite: 303]
                        ToggleSettingPicker(label: "BLE On/Off", selection: $blu) // BLUON [cite: 304]
                    }
                    HStack(spacing: 24) {
                        BaudRatePicker(selection: $baud) // BAUD [cite: 306]
                        ComPortPicker(selection: $com) // COM [cite: 305]
                    }
                    HStack(spacing: 24) {
                        NameTypePicker(selection: $aprsName) // NAME-TYPE [cite: 299]
                        Spacer()
                    }
                }
                
                // MARK: Actions (These commands MUST be executed singly [cite: 344])
                Section(header: Text("Actions").font(.headline)) {
                    Button(action: {
                        // Request for settings command [cite: 345, 350]
                        BLEManager.shared.sendCommand("?")
                    }) {
                        Text("Request Settings")
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 8)
                    
                    Button(action: {
                        // Sleep forever command [cite: 348, 351]
                        BLEManager.shared.sendCommand("sleep=0")
                    }) {
                        Text("Sleep Forever (Requires Physical Reboot)")
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red) // Highlight critical action
                    .padding(.bottom, 8)
                    
                    Button(action: {
                        // Reboot command [cite: 347]
                        BLEManager.shared.sendCommand("re")
                    }) {
                        Text("Reset Parameters")
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange) // Highlight important action
                    .padding(.bottom, 8)
                }
            }
            .padding(24)
        }
        .navigationTitle("Other")
        .navigationBarTitleDisplayMode(.inline)
    }
}

//// Helper structs for various pickers (unchanged, with citations)
struct ToggleSettingPicker: View {
    let label: String
    @Binding var selection: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Picker(label, selection: $selection) {
                Text("Off").tag(0) // [cite: 303, 304]
                Text("On").tag(1) // [cite: 303, 304]
            }
            .pickerStyle(.menu)
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
        }
    }
}

struct BaudRatePicker: View {
    @Binding var selection: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Baud Rate")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("Baud Rate", selection: $selection) { // BAUD
                Text("4800").tag(0) // [cite: 306]
                Text("9600").tag(1) // [cite: 306]
                Text("19200").tag(2) // [cite: 306]
                Text("38400").tag(3) // [cite: 306]
                Text("57600").tag(4) // [cite: 306]
                Text("115200").tag(5) // [cite: 306]
            }
            .pickerStyle(.menu)
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
        }
    }
}

struct ComPortPicker: View {
    @Binding var selection: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Port")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("Port", selection: $selection) { // COM
                Text("TX1-RX3-USB").tag(0) // [cite: 305]
                Text("TX12-RX2").tag(1) // [cite: 305]
            }
            .pickerStyle(.menu)
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
        }
    }
}

struct NameTypePicker: View {
    @Binding var selection: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name Mode")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("Name Mode", selection: $selection) { // NAME-TYPE
                Text("Serial").tag(0) // [cite: 299]
                Text("APRS NAME").tag(1) // [cite: 299]
            }
            .pickerStyle(.menu)
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
        }
    }
}

#Preview {
    SettingsView()
}
