import SwiftUI

// MARK: - Device Settings View (Sheet)
struct DeviceSettingsView: View {
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var persistenceService: PersistenceService
    @EnvironmentObject var userSettings: UserSettings
    @Environment(\.dismiss) private var dismiss

    @State private var deviceSettingsCopy: DeviceSettings = .default
    @State private var initialDeviceSettings: DeviceSettings = .default
    @State private var deviceConfigReceived: Bool = false
    @State private var deviceSettingsLoading: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if deviceSettingsLoading {
                    ProgressView("Loading Device Settings...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !deviceConfigReceived {
                    Form {
                        Section {
                            Text("Sonde not connected")
                                .foregroundColor(.red)
                                .fontWeight(.semibold)
                        }
                        disabledFormFields()
                    }
                    .disabled(true)
                } else {
                    TabView {
                        pinsSettingsTab.tabItem { Label("Pins", systemImage: "pin") }
                        batterySettingsTab.tabItem { Label("Battery", systemImage: "battery.100") }
                        radioSettingsTab.tabItem { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                        predictionSettingsTab.tabItem { Label("Prediction", systemImage: "cloud.sun") }
                        otherSettingsTab.tabItem { Label("Other", systemImage: "ellipsis") }
                    }
                    .tabViewStyle(.automatic)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Device Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button("Undo") { revertDeviceSettings() }
                        .disabled(!deviceConfigReceived)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                loadDeviceSettings()
            }
            .onDisappear {
                saveDeviceSettings()
            }
        }
    }

    // MARK: - Device Settings Tabs
    
    private func disabledFormFields() -> some View {
        Group {
            Section(header: Text("OLED/LCD Pins")) {
                TextField("oledSDA", value: .constant(0), formatter: NumberFormatter())
                TextField("oledSCL", value: .constant(0), formatter: NumberFormatter())
                TextField("oledRST", value: .constant(0), formatter: NumberFormatter())
                TextField("ledPin", value: .constant(0), formatter: NumberFormatter())
                TextField("buzPin", value: .constant(0), formatter: NumberFormatter())
            }
            Section(header: Text("Battery")) {
                TextField("batPin", value: .constant(0), formatter: NumberFormatter())
                TextField("batMin", value: .constant(0), formatter: NumberFormatter())
                TextField("batMax", value: .constant(0), formatter: NumberFormatter())
                Picker("batType", selection: .constant(0)) {
                    ForEach([0,1,2], id: \.self) { Text("\($0)") }
                }
            }
            Section(header: Text("Radio Settings")) {
                TextField("callSign", text: .constant(""))
                TextField("RS41Bandwidth", value: .constant(0), formatter: NumberFormatter())
                TextField("M20Bandwidth", value: .constant(0), formatter: NumberFormatter())
                TextField("M10Bandwidth", value: .constant(0), formatter: NumberFormatter())
                TextField("PILOTBandwidth", value: .constant(0), formatter: NumberFormatter())
                TextField("DFMBandwidth", value: .constant(0), formatter: NumberFormatter())
            }
            Section(header: Text("Other")) {
                Picker("lcdType", selection: .constant(0)) {
                    Text("SSD1306").tag(0)
                    Text("SH1106").tag(1)
                }
                Picker("nameType", selection: .constant(0)) {
                    Text("Serial").tag(0)
                    Text("APRS Name").tag(1)
                }
                Picker("bluetoothStatus", selection: .constant(1)) {
                    Text("On").tag(1)
                    Text("Off").tag(0)
                }
                Picker("lcdStatus", selection: .constant(1)) {
                    Text("On").tag(1)
                    Text("Off").tag(0)
                }
                TextField("serialSpeed", value: .constant(0), formatter: NumberFormatter())
                TextField("serialPort", value: .constant(0), formatter: NumberFormatter())
                Picker("aprsName", selection: .constant(0)) {
                    Text("Serial").tag(0)
                    Text("APRS").tag(1)
                }
            }
        }
    }

    var pinsSettingsTab: some View {
        Form {
            Section(header: Text("OLED/LCD Pins")) {
                HStack {
                    Text("oledSDA")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.oledSDA, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("oledSCL")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.oledSCL, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("oledRST")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.oledRST, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("ledPin")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.ledPin, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("buzPin")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.buzPin, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    var batterySettingsTab: some View {
        Form {
            Section(header: Text("Battery")) {
                HStack {
                    Text("batPin")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.batPin, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("batMin")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.batMin, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("batMax")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.batMax, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("batType")
                    Spacer()
                    Picker("", selection: $deviceSettingsCopy.batType) {
                        Text("Linear").tag(0)
                        Text("Sigmoidal").tag(1)
                        Text("Asigmoidal").tag(2)
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    var radioSettingsTab: some View {
        Form {
            Section(header: Text("Radio Settings")) {
                HStack {
                    Text("callSign")
                    Spacer()
                    TextField("", text: $deviceSettingsCopy.callSign)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("RS41Bandwidth")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.RS41Bandwidth, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("M20Bandwidth")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.M20Bandwidth, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("M10Bandwidth")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.M10Bandwidth, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("PILOTBandwidth")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.PILOTBandwidth, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("DFMBandwidth")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.DFMBandwidth, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    var predictionSettingsTab: some View {
        Form {
            Section(header: Text("Prediction Settings")) {
                TextField("Burst Altitude", value: $userSettings.burstAltitude, formatter: NumberFormatter())
                    .keyboardType(.numberPad)
                TextField("Ascent Rate", value: $userSettings.ascentRate, formatter: NumberFormatter())
                    .keyboardType(.numberPad)
                TextField("Descent Rate", value: $userSettings.descentRate, formatter: NumberFormatter())
                    .keyboardType(.numberPad)
            }
        }
    }

    var otherSettingsTab: some View {
        Form {
            Section(header: Text("Other")) {
                HStack {
                    Text("lcdType")
                    Spacer()
                    Picker("", selection: $deviceSettingsCopy.lcdType) {
                        Text("SSD1306").tag(0)
                        Text("SH1106").tag(1)
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("nameType")
                    Spacer()
                    Picker("", selection: $deviceSettingsCopy.nameType) {
                        Text("Serial").tag(0)
                        Text("APRS Name").tag(1)
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("bluetoothStatus")
                    Spacer()
                    Picker("", selection: $deviceSettingsCopy.bluetoothStatus) {
                        Text("On").tag(1)
                        Text("Off").tag(0)
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("lcdStatus")
                    Spacer()
                    Picker("", selection: $deviceSettingsCopy.lcdStatus) {
                        Text("On").tag(1)
                        Text("Off").tag(0)
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("serialSpeed")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.serialSpeed, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("serialPort")
                    Spacer()
                    TextField("", value: $deviceSettingsCopy.serialPort, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("aprsName")
                    Spacer()
                    Picker("", selection: $deviceSettingsCopy.aprsName) {
                        Text("Serial").tag(0)
                        Text("APRS").tag(1)
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    // MARK: - Device Settings Loading & Saving
    private func loadDeviceSettings() {
        deviceSettingsLoading = true
        deviceConfigReceived = false

        guard bleService.isReadyForCommands else {
            deviceSettingsLoading = false
            return
        }

        bleService.sendCommand(command: "o{?}o")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let devSettings = persistenceService.deviceSettings {
                deviceSettingsCopy = devSettings
                initialDeviceSettings = devSettings
                deviceConfigReceived = true
            } else {
                deviceConfigReceived = false
            }
            deviceSettingsLoading = false
        }
    }

    private func saveDeviceSettings() {
        guard deviceConfigReceived else { return }
        sendDeviceSettingsToBLE()
        persistenceService.save(deviceSettings: deviceSettingsCopy)
        persistenceService.save(userSettings: userSettings)
    }

    private func revertDeviceSettings() {
        deviceSettingsCopy = initialDeviceSettings
    }

    private func sendDeviceSettingsToBLE() {
        // Compare current settings with initial and send commands only for changed values.
        
        // Pins
        if deviceSettingsCopy.oledSDA != initialDeviceSettings.oledSDA {
            let command = "o{oled_sda=\(deviceSettingsCopy.oledSDA)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.oledSCL != initialDeviceSettings.oledSCL {
            let command = "o{oled_scl=\(deviceSettingsCopy.oledSCL)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.oledRST != initialDeviceSettings.oledRST {
            let command = "o{oled_rst=\(deviceSettingsCopy.oledRST)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.ledPin != initialDeviceSettings.ledPin {
            let command = "o{led_pout=\(deviceSettingsCopy.ledPin)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.buzPin != initialDeviceSettings.buzPin {
            let command = "o{buz_pin=\(deviceSettingsCopy.buzPin)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        
        // Battery
        if deviceSettingsCopy.batPin != initialDeviceSettings.batPin {
            let command = "o{battery=\(deviceSettingsCopy.batPin)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.batMin != initialDeviceSettings.batMin {
            let command = "o{vBatMin=\(deviceSettingsCopy.batMin)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.batMax != initialDeviceSettings.batMax {
            let command = "o{vBatMax=\(deviceSettingsCopy.batMax)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.batType != initialDeviceSettings.batType {
            let command = "o{vBatType=\(deviceSettingsCopy.batType)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        
        // Radio Settings
        if deviceSettingsCopy.callSign != initialDeviceSettings.callSign {
            let command = "o{myCall=\(deviceSettingsCopy.callSign)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.RS41Bandwidth != initialDeviceSettings.RS41Bandwidth {
            let command = "o{rs41.rxbw=\(deviceSettingsCopy.RS41Bandwidth)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.M20Bandwidth != initialDeviceSettings.M20Bandwidth {
            let command = "o{m20.rxbw=\(deviceSettingsCopy.M20Bandwidth)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.M10Bandwidth != initialDeviceSettings.M10Bandwidth {
            let command = "o{m10.rxbw=\(deviceSettingsCopy.M10Bandwidth)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.PILOTBandwidth != initialDeviceSettings.PILOTBandwidth {
            let command = "o{pilot.rxbw=\(deviceSettingsCopy.PILOTBandwidth)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.DFMBandwidth != initialDeviceSettings.DFMBandwidth {
            let command = "o{dfm.rxbw=\(deviceSettingsCopy.DFMBandwidth)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }

        // Other Settings
        if deviceSettingsCopy.lcdType != initialDeviceSettings.lcdType {
            let command = "o{lcd=\(deviceSettingsCopy.lcdType)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.bluetoothStatus != initialDeviceSettings.bluetoothStatus {
            let command = "o{blu=\(deviceSettingsCopy.bluetoothStatus)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.lcdStatus != initialDeviceSettings.lcdStatus {
            let command = "o{lcdOn=\(deviceSettingsCopy.lcdStatus)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.serialSpeed != initialDeviceSettings.serialSpeed {
            let command = "o{baud=\(deviceSettingsCopy.serialSpeed)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.serialPort != initialDeviceSettings.serialPort {
            let command = "o{com=\(deviceSettingsCopy.serialPort)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
        if deviceSettingsCopy.aprsName != initialDeviceSettings.aprsName {
            let command = "o{aprsName=\(deviceSettingsCopy.aprsName)}o"
            print("BLE Command: \(command)")
            bleService.sendCommand(command: command)
        }
    }
}


// MARK: - Main Settings View
struct SettingsView: View {
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var persistenceService: PersistenceService
    @EnvironmentObject var userSettings: UserSettings
    
    @State private var selectedTab: Int = 0
    @State private var isShowingDeviceSettings = false
    
    // For Sonde Settings
    @State private var tempDeviceSettings: DeviceSettings = .default
    @State private var freqDigits: [Int] = Array(repeating: 0, count: 5)
    @State private var initialSondeType: String = ""
    @State private var initialFrequency: Double = 0.0
    @State private var showRestoreAlert = false
    
    // For Tune window
    @State private var tempTuneFrequencyCorrection: Int = 0
    @State private var tuneInitialFrequencyCorrection: Int = 0
    @State private var isSavingTune: Bool = false
    
    private let sondeTypeMapping: [String: Int] = ["RS41": 1, "M20": 2, "M10": 3, "PILOT": 4, "DFM": 5]
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selectedTab) {
                    sondeTab.tag(0)
                    tuneTab.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
                .edgesIgnoringSafeArea(.bottom)
            }
            .navigationTitle(titleForTab(selectedTab))
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    if selectedTab == 0 { // Sonde
                        Button("Revert") { revertSondeSettings() }
                            .disabled(!bleService.isReadyForCommands)
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if selectedTab == 0 { // Sonde
                        Button("Device Settings") { isShowingDeviceSettings = true }
                            .disabled(!bleService.isReadyForCommands)
                        Button("Tune") { selectedTab = 1 }
                            .disabled(!bleService.isReadyForCommands)
                    } else { // Tune
                        Button("Save") { saveTuneSettings() }
                            .disabled(!bleService.isReadyForCommands || isSavingTune)
                    }
                }
            }
            .onAppear {
                loadSondeSettings()
            }
            .onDisappear {
                if selectedTab == 0 {
                    saveSondeSettingsOnDismiss()
                }
            }
            .sheet(isPresented: $isShowingDeviceSettings) {
                DeviceSettingsView()
            }
            .alert("Restore original values?", isPresented: $showRestoreAlert) {
                Button("Restore", role: .destructive) {
                    loadSondeSettings()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
    
    private func titleForTab(_ tab: Int) -> String {
        switch tab {
        case 0: return "Sonde Settings"
        case 1: return "Tune AFC"
        default: return "Settings"
        }
    }
    
    // MARK: - Sonde Settings Logic
    private func loadSondeSettings() {
        tempDeviceSettings = persistenceService.deviceSettings ?? .default
        tempTuneFrequencyCorrection = tempDeviceSettings.frequencyCorrection
        updateFreqDigitsFromFrequency()
        initialSondeType = tempDeviceSettings.sondeType
        initialFrequency = tempDeviceSettings.frequency
    }
    
    private func saveSondeSettingsOnDismiss() {
        let frequency = frequencyFromDigits()
        tempDeviceSettings.frequency = frequency
        
        let probeType = tempDeviceSettings.sondeType
        let probeTypeNumber = sondeTypeMapping[probeType] ?? 0
        let commandString = "o{f=\(String(format: "%.2f", frequency))/tipo=\(probeTypeNumber)}o"
        print("BLE Command: \(commandString)")
        bleService.sendCommand(command: commandString)
        
        tempDeviceSettings.frequency = frequency
        tempDeviceSettings.sondeType = probeType
        
        persistenceService.save(deviceSettings: tempDeviceSettings)
    }
    
    private func revertSondeSettings() {
        tempDeviceSettings.sondeType = initialSondeType
        tempDeviceSettings.frequency = initialFrequency
        updateFreqDigitsFromFrequency()
    }
    
    private func updateFreqDigitsFromFrequency() {
        let freqInt = Int((tempDeviceSettings.frequency * 100).rounded())
        var digits = Array(repeating: 0, count: 5)
        var remainder = freqInt
        for i in (0..<5).reversed() {
            digits[i] = remainder % 10
            remainder /= 10
        }
        freqDigits = digits
    }

    private func frequencyFromDigits() -> Double {
        var total = 0
        for digit in freqDigits {
            total = total * 10 + digit
        }
        return Double(total) / 100.0
    }
    
    // MARK: - Tune Settings Logic
    private func loadTuneSettings() {
        tempTuneFrequencyCorrection = persistenceService.deviceSettings?.frequencyCorrection ?? 0
        tuneInitialFrequencyCorrection = tempTuneFrequencyCorrection
    }
    
    private func saveTuneSettings() {
        isSavingTune = true
        bleService.sendCommand(command: "o{freqofs=\(tempTuneFrequencyCorrection)}o")
        if var devSettings = persistenceService.deviceSettings {
            devSettings.frequencyCorrection = tempTuneFrequencyCorrection
            persistenceService.save(deviceSettings: devSettings)
        }
        isSavingTune = false
    }
    
    // MARK: - Views
    var sondeTab: some View {
        Form {
            if !bleService.isReadyForCommands {
                Section {
                    Text("Sonde not connected")
                        .foregroundColor(.red)
                        .fontWeight(.semibold)
                }
                Section(header: Text("Sonde Type & Frequency")) {
                    Picker("Sonde Type", selection: $tempDeviceSettings.sondeType) {
                        ForEach(["RS41", "M20", "M10", "PILOT", "DFM"], id: \.self) { Text($0) }
                    }
                    .disabled(true)
                    
                    HStack(spacing: 4) {
                        ForEach(0..<5, id: \.self) { i in
                            Picker("", selection: $freqDigits[i]) {
                                ForEach(0..<10) {
                                    Text("\($0)")
                                        .font(.system(size: 40, weight: .bold))
                                        .tag($0)
                                }
                            }
                            .pickerStyle(WheelPickerStyle())
                            .frame(maxWidth: .infinity, maxHeight: 180)
                            .clipped()
                            .disabled(true)
                            .layoutPriority(1)
                        }
                        Text("MHz")
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                Section(header: Text("Sonde Type & Frequency")) {
                    Picker("Sonde Type", selection: $tempDeviceSettings.sondeType) {
                        ForEach(["RS41", "M20", "M10", "PILOT", "DFM"], id: \.self) { Text($0) }
                    }
                    .disabled(!bleService.isReadyForCommands)
                    
                    HStack(spacing: 4) {
                        ForEach(0..<5, id: \.self) { i in
                            Picker("", selection: $freqDigits[i]) {
                                ForEach(0..<10) {
                                    Text("\($0)")
                                        .font(.system(size: 40, weight: .bold))
                                        .tag($0)
                                }
                            }
                            .pickerStyle(WheelPickerStyle())
                            .frame(maxWidth: .infinity, maxHeight: 180)
                            .clipped()
                            .disabled(!bleService.isReadyForCommands)
                            .layoutPriority(1)
                        }
                        Text("MHz")
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .tabItem { Label("Sonde", systemImage: "antenna.radiowaves.left.and.right") }
    }
    
    var tuneTab: some View {
        Form {
            Section(header: Text("AFC Calibration")) {
                TextField("Correction", value: $tempTuneFrequencyCorrection, formatter: NumberFormatter())
                    .keyboardType(.numberPad)
                    .font(.title)
                Button("Save") {
                    saveTuneSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!bleService.isReadyForCommands || isSavingTune)
            }
        }
    }
}
