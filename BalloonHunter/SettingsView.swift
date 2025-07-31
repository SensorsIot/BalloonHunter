import SwiftUI
import CoreBluetooth
import Combine
import OSLog

// Assuming BLEManager is defined elsewhere for sending commands
// For example:

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    // All State variables for the settings
    @State private var lcd: Int = 0 // Mapped to LCD-TYPE [cite: 298]
    @State private var lcdOn: Int = 1 // Mapped to LCDON [cite: 303]
    @State private var blu: Int = 1 // Mapped to BLUON [cite: 304]
    @State private var baud: Int = 1 // Mapped to BAUD [cite: 306]
    @State private var com: Int = 0 // Mapped to COM [cite: 305]
    @State private var oled_sda: String = "21" // Mapped to OLED-SDA [cite: 284]
    @State private var oled_scl: String = "22" // Mapped to OLED-SCL [cite: 285]
    @State private var oled_rst: String = "16" // Mapped to OLED-RST [cite: 286]
    @State private var buz_pin: String = "4" // Mapped to BUZ-PIN [cite: 300]
    @State private var led_pout: String = "25" // Mapped to LED-PIN [cite: 287]
    @State private var batteryPin: String = "35" // Mapped to BAT-PIN [cite: 294]
    @State private var vBatMin: String = "2950" // Mapped to BAT-MIN [cite: 295]
    @State private var vBatMax: String = "4180" // Mapped to BAT-MAX [cite: 296]
    @State private var vBatType: Int = 1 // Mapped to BAT-TYPE [cite: 297]
    @State private var rs41_rxbw: String = "4" // Mapped to RS41-BAND (Default 1 from doc, screenshot 3100 implies a value 4 from Appendix 2) [cite: 288, 370]
    @State private var m10_rxbw: String = "7" // Mapped to M10-BAND [cite: 290]
    @State private var dfm_rxbw: String = "6" // Mapped to DFM-BAND [cite: 291]
    @State private var m20_rxbw: String = "7" // Mapped to M20-BAND [cite: 289]
    @State private var pilot_rxbw: String = "7" // Mapped to PILOT-BAND [cite: 266] (Implied from the screenshot's "PIL 12500" matching M20's default [cite: 373])
    @State private var aprsName: Int = 0 // Mapped to NAME-TYPE [cite: 299]
    @State private var freqofs: String = "0" // Mapped to FREQ-OFS [cite: 293]
    @State private var myCall: String = "BUBI" // Mapped to MYCALL [cite: 292]

    @State private var didRequestSettings = false

    // Added as per instructions
    @State private var frequency: Double = BLEManager.shared.latestTelemetry?.frequency ?? 404.2
    @State private var probeType: Int = 2

    var body: some View {
        NavigationView {
            TabView {
                // MARK: Pins Tab
                PinsSettingsView(
                    lcdType: $lcd, // LCD-TYPE
                    oled_sda: $oled_sda, // OLED-SDA
                    oled_scl: $oled_scl, // OLED-SCL
                    oled_rst: $oled_rst, // OLED-RST
                    buz_pin: $buz_pin, // BUZ-PIN
                    led_pout: $led_pout, // LED-PIN
                    batteryPin: $batteryPin // BAT-PIN
                )
                .tabItem {
                    Label("Pins", systemImage: "pin.fill")
                }

                // MARK: Battery Tab
                BatterySettingsView(
                    vBatMin: $vBatMin, // BAT-MIN
                    vBatMax: $vBatMax, // BAT-MAX
                    vBatType: $vBatType // BAT-TYPE
                )
                .tabItem {
                    Label("Battery", systemImage: "battery.100")
                }

                // MARK: Radio Tab
                RadioSettingsView(
                    myCall: $myCall, // MYCALL
                    rs41_rxbw: $rs41_rxbw, // RS41-BAND
                    m10_rxbw: $m10_rxbw, // M10-BAND
                    m20_rxbw: $m20_rxbw, // M20-BAND
                    pilot_rxbw: $pilot_rxbw, // PILOT-BAND
                    dfm_rxbw: $dfm_rxbw, // DFM-BAND
                    freqofs: $freqofs, // FREQ-OFS
                    aprsName: $aprsName // NAME-TYPE
                )
                .tabItem {
                    Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
                }
                
                // MARK: Other Settings Tab (combining general controls and actions)
                OtherSettingsView(
                    lcdOn: $lcdOn,
                    blu: $blu,
                    baud: $baud,
                    com: $com,
                    aprsName: $aprsName // This seems duplicated, if `aprsName` is part of Radio settings, it should not be here.
                                        // Keeping it for now as it was in your 'OthersSettingsView'
                )
                .tabItem {
                    Label("Other", systemImage: "gearshape")
                }
            }
            .navigationTitle("Settings (2.30)") // From screenshot
            .navigationBarTitleDisplayMode(.inline) // Compact title
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(action: {
                            saveSettings()
                            dismiss()
                        }) {
                            Text("Save")
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: {
                            // Action for the 'RESET' button. This sends 'o{Re}o' [cite: 346, 349]
                            BLEManager.shared.sendCommand("Re")
                        }) {
                            Text("RESET")
                        }
                    }
                }
            }
        }
        .task {
            if !didRequestSettings {
                BLEManager.shared.sendCommand("?")
                didRequestSettings = true
            }
        }
        .onReceive(BLEManager.shared.$receivedText) { text in
            if let settingsLine = text.split(separator: "\n").last(where: { $0.hasSuffix("/o") }) {
                parseSettingsResponse(String(settingsLine))
            }
        }
    }

    private func saveSettings() {
        Logger().info("[DEBUG] Current frequency: \(frequency), probeType: \(probeType)")
        // Send frequency and probeType individually first to ensure they are processed correctly before bulk settings
        Logger().info("[DEBUG] Sending command: f=\(frequency)")
        BLEManager.shared.sendCommand("f=\(frequency)")
        Logger().info("[DEBUG] Sent command: f=\(frequency)")
        Logger().info("[DEBUG] Sending command: tipo=\(probeType)")
        BLEManager.shared.sendCommand("tipo=\(probeType)")
        Logger().info("[DEBUG] Sent command: tipo=\(probeType)")

        var commands: [String] = []

        // Pins Tab Settings
        commands.append("lcd=\(lcd)") // [cite: 314]
        commands.append("oled_sda=\(oled_sda)") // [cite: 319]
        commands.append("oled_scl=\(oled_scl)") // [cite: 320]
        commands.append("oled_rst=\(oled_rst)") // [cite: 321]
        commands.append("buz_pin=\(buz_pin)") // [cite: 323]
        commands.append("led_pout=\(led_pout)") // [cite: 322]
        commands.append("battery=\(batteryPin)") // [cite: 331]

        // Battery Tab Settings
        commands.append("vBatMin=\(vBatMin)") // [cite: 332]
        commands.append("vBatMax=\(vBatMax)") // [cite: 333]
        commands.append("vBatType=\(vBatType)") // [cite: 334]

        // Radio Tab Settings
        commands.append("myCall=\(myCall)") // [cite: 335]
        // Convert the string index back to the integer value for the API
        // NOTE: The API expects the integer band index (0-19), not the kHz string.
        if let rs41Index = RadioSettingsView.freqOptions.firstIndex(of: "\(rs41_rxbw) kHz") {
             commands.append("rs41.rxbw=\(rs41Index)") // [cite: 324]
        }
        if let m10Index = RadioSettingsView.freqOptions.firstIndex(of: "\(m10_rxbw) kHz") {
            commands.append("m10.rxbw=\(m10Index)") // [cite: 326]
        }
        if let m20Index = RadioSettingsView.freqOptions.firstIndex(of: "\(m20_rxbw) kHz") {
            commands.append("m20.rxbw=\(m20Index)") // [cite: 325]
        }
        if let pilotIndex = RadioSettingsView.freqOptions.firstIndex(of: "\(pilot_rxbw) kHz") {
            commands.append("pilot.rxbw=\(pilotIndex)") // [cite: 327]
        }
        if let dfmIndex = RadioSettingsView.freqOptions.firstIndex(of: "\(dfm_rxbw) kHz") {
            commands.append("dfm.rxbw=\(dfmIndex)") // [cite: 328]
        }
        commands.append("aprsName=\(aprsName)") // [cite: 329]
        commands.append("freqofs=\(freqofs)") // [cite: 330]

        // Other Settings (from original OthersSettingsView)
        commands.append("lcdOn=\(lcdOn)") // [cite: 315]
        commands.append("blu=\(blu)") // [cite: 316]
        commands.append("baud=\(baud)") // [cite: 317]
        commands.append("com=\(com)") // [cite: 318]
        // Note: aprsName is already covered in Radio Tab settings, avoid duplication if it's meant to be unique.

        Logger().info("[DEBUG] Commands array: \(commands)")
        let commandString = commands.joined(separator: "/") // [cite: 312]
        Logger().info("[DEBUG] Sending command: \(commandString)")
        BLEManager.shared.sendCommand(commandString) // [cite: 309, 310, 311]

        // Optional: Show a confirmation message to the user
        // For production, you might want to wait for a BLE response
    }

    private func parseSettingsResponse(_ response: String) {
        Logger().info("[DEBUG] Received settings response: \(response)")
        // Remove trailing "/o" if present
        let trimmed = response.hasSuffix("/o") ? String(response.dropLast(2)) : response
        let parts = trimmed.split(separator: "/").map(String.init)
        if parts.count < 2 {
            return
        }
        let type = parts[0]
        switch type {
        case "0":
            for (i, _) in parts.enumerated() {
            }
        case "1":
            for (i, _) in parts.enumerated() {
            }
        case "2":
            for (i, _) in parts.enumerated() {
            }
        case "3":
            for (i, _) in parts.enumerated() {
            }
            if parts.count < 23 {
                return
            }
            oled_sda = parts[3]
            oled_scl = parts[4]
            oled_rst = parts[5]
            led_pout = parts[6]
            rs41_rxbw = parts[7]
            m20_rxbw = parts[8]
            m10_rxbw = parts[9]
            pilot_rxbw = parts[10]
            dfm_rxbw = parts[11]
            myCall = parts[12]
            freqofs = parts[13]
            batteryPin = parts[14]
            vBatMin = parts[15]
            vBatMax = parts[16]
            if let vBatTypeValue = Int(parts[17]) {
                vBatType = vBatTypeValue
            }
            if let lcdValue = Int(parts[18]) {
                lcd = lcdValue
            }
            if let aprsNameValue = Int(parts[19]) {
                aprsName = aprsNameValue
            }
            buz_pin = parts[20]
            let _ = parts[21]

            Logger().info("[DEBUG] Parsed sonde settings: oled_sda=\(oled_sda), oled_scl=\(oled_scl), oled_rst=\(oled_rst), led_pout=\(led_pout), rs41_rxbw=\(rs41_rxbw), m20_rxbw=\(m20_rxbw), m10_rxbw=\(m10_rxbw), pilot_rxbw=\(pilot_rxbw), dfm_rxbw=\(dfm_rxbw), myCall=\(myCall), freqofs=\(freqofs), batteryPin=\(batteryPin), vBatMin=\(vBatMin), vBatMax=\(vBatMax), vBatType=\(vBatType), lcd=\(lcd), aprsName=\(aprsName), buz_pin=\(buz_pin)")
        default:
            for (i, _) in parts.enumerated() {
            }
        }
    }
}

// MARK: - PinsSettingsView (unchanged from previous)
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

// Helper struct for consistent pin input fields (unchanged)
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

// MARK: - BatterySettingsView (unchanged from previous)
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

// MARK: - RadioSettingsView (unchanged from previous, except for freqOptions to be global for easy access)
struct RadioSettingsView: View {
    @Binding var myCall: String // MYCALL [cite: 292]
    @Binding var rs41_rxbw: String // RS41-BAND [cite: 288]
    @Binding var m10_rxbw: String // M10-BAND [cite: 290]
    @Binding var m20_rxbw: String // M20-BAND [cite: 289]
    @Binding var pilot_rxbw: String // PILOT-BAND [cite: 266]
    @Binding var dfm_rxbw: String // DFM-BAND [cite: 291]
    @Binding var freqofs: String // FREQ-OFS [cite: 293]
    @Binding var aprsName: Int // NAME-TYPE [cite: 299]

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
                                if newValue.count > 8 { // Max 8 characters
                                    myCall = String(newValue.prefix(8))
                                }
                            }
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                    }
                }

                Section(header: Text("Rx Bandwidth (kHz)").font(.headline)) {
                    HStack(spacing: 32) {
                        RxBandwidthPicker(label: "RS41", selection: $rs41_rxbw, options: Self.freqOptions) // RS41-BAND [cite: 288]
                        RxBandwidthPicker(label: "M10", selection: $m10_rxbw, options: Self.freqOptions) // M10-BAND [cite: 290]
                    }
                    HStack(spacing: 32) {
                        RxBandwidthPicker(label: "M20", selection: $m20_rxbw, options: Self.freqOptions) // M20-BAND [cite: 289]
                        RxBandwidthPicker(label: "DFM", selection: $dfm_rxbw, options: Self.freqOptions) // DFM-BAND [cite: 291]
                    }
                    HStack(spacing: 32) {
                        RxBandwidthPicker(label: "PILOT", selection: $pilot_rxbw, options: Self.freqOptions) // PILOT-BAND [cite: 266]
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
                                // Send tune command. The API implies "f" for freq, but "TUNE" is a UI button
                                // Assuming "freqofs" is for fine-tuning.
                                // If "TUNE" sends the current "freqofs" as a command
                                BLEManager.shared.sendCommand("freqofs=\(freqofs)") // [cite: 330] Example command
                            }) {
                                Text("TUNE")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                
                Section(header: Text("Name Display Type").font(.headline)) {
                    NameTypePicker(selection: $aprsName) // NAME-TYPE [cite: 299]
                }
            }
            .padding(24)
        }
        .navigationTitle("Radio")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Helper struct for consistent Rx Bandwidth pickers (unchanged)
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

// MARK: - OtherSettingsView (renamed from OthersSettingsView and includes general controls & actions)
// Removed redundant battery settings from here as they are now in BatterySettingsView
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
                    // If aprsName is truly global and not specific to Radio, it could live here.
                    // If it belongs in Radio, remove it from here.
                    // Keeping it here for now as per your original 'OthersSettingsView' structure.
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
                        Text("Reboot Device")
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange) // Highlight important action
                    .padding(.bottom, 8)

                    // You could add a TextField for `sleep=SECONDS`
                    // For example:
                    // @State private var sleepSeconds: String = ""
                    // TextField("Sleep seconds", text: $sleepSeconds)
                    // Button("Go to Sleep") { BLEManager.shared.sendCommand("sleep=\(sleepSeconds)") }
                }
            }
            .padding(24)
        }
        .navigationTitle("Other")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// Helper structs for various pickers (unchanged, with citations)
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
