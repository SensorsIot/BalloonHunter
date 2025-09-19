import SwiftUI
import Combine

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
                    NumericTextField("", value: $deviceSettingsCopy.oledSDA)
                }
                if let warn = ESP32PinRules.i2cWarning(pin: deviceSettingsCopy.oledSDA) {
                    Text(warn).font(.footnote).foregroundColor(.red)
                }
                HStack {
                    Text("oledSCL")
                    Spacer()
                    NumericTextField("", value: $deviceSettingsCopy.oledSCL)
                }
                if let warn = ESP32PinRules.i2cWarning(pin: deviceSettingsCopy.oledSCL) {
                    Text(warn).font(.footnote).foregroundColor(.red)
                }
                HStack {
                    Text("oledRST")
                    Spacer()
                    NumericTextField("", value: $deviceSettingsCopy.oledRST)
                }
                if let warn = ESP32PinRules.outputWarning(pin: deviceSettingsCopy.oledRST) {
                    Text(warn).font(.footnote).foregroundColor(.red)
                }
                HStack {
                    Text("ledPin")
                    Spacer()
                    NumericTextField("", value: $deviceSettingsCopy.ledPin)
                }
                if let warn = ESP32PinRules.outputWarning(pin: deviceSettingsCopy.ledPin) {
                    Text(warn).font(.footnote).foregroundColor(.red)
                }
                HStack {
                    Text("buzPin")
                    Spacer()
                    NumericTextField("", value: $deviceSettingsCopy.buzPin)
                }
                if let warn = ESP32PinRules.outputWarning(pin: deviceSettingsCopy.buzPin) {
                    Text(warn).font(.footnote).foregroundColor(.red)
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
                    NumericTextField("", value: $deviceSettingsCopy.batPin)
                }
                if let warn = ESP32PinRules.batteryWarning(pin: deviceSettingsCopy.batPin) {
                    Text(warn).font(.footnote).foregroundColor(.red)
                }
                HStack {
                    Text("batMin")
                    Spacer()
                    NumericTextField("", value: $deviceSettingsCopy.batMin)
                }
                HStack {
                    Text("batMax")
                    Spacer()
                    NumericTextField("", value: $deviceSettingsCopy.batMax)
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
                    NumericTextField("", value: $deviceSettingsCopy.RS41Bandwidth)
                }
                HStack {
                    Text("M20Bandwidth")
                    Spacer()
                    NumericTextField("", value: $deviceSettingsCopy.M20Bandwidth)
                }
                HStack {
                    Text("M10Bandwidth")
                    Spacer()
                    NumericTextField("", value: $deviceSettingsCopy.M10Bandwidth)
                }
                HStack {
                    Text("PILOTBandwidth")
                    Spacer()
                    NumericTextField("", value: $deviceSettingsCopy.PILOTBandwidth)
                }
                HStack {
                    Text("DFMBandwidth")
                    Spacer()
                    NumericTextField("", value: $deviceSettingsCopy.DFMBandwidth)
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
                    NumericTextField("", value: $deviceSettingsCopy.serialSpeed)
                }
                HStack {
                    Text("serialPort")
                    Spacer()
                    NumericTextField("", value: $deviceSettingsCopy.serialPort)
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
    
    // serialSpeedToBaudIndex removed (logic now in BLECommunicationService)

    private func sendDeviceSettingsToBLE() {
        // Business logic moved to BLECommunicationService for proper separation of concerns
        bleService.sendDeviceSettings(current: deviceSettingsCopy, initial: initialDeviceSettings)
    }

    // Pin validation helpers moved to ESP32PinRules for reuse and testing
    
}


// MARK: - Main Settings View
struct SettingsView: View {
    @EnvironmentObject var serviceCoordinator: ServiceCoordinator
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
    
    // AFC tracking managed by ServiceCoordinator (moved for proper separation of concerns)
    // Sonde type mapping moved to ServiceCoordinator for proper separation of concerns
    
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
                        Button("Reset") {
                            saveTuneSettings(correctionValue: 0)
                        }
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
                // Removed saveTuneSettings on disappear for Tune tab as per instructions
                // No code here modifies selectedTab
            }
            .sheet(isPresented: $isShowingDeviceSettings, onDismiss: loadSondeSettings) {
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
        initialSondeType = tempDeviceSettings.probeType
        initialFrequency = tempDeviceSettings.frequency
    }
    
    private func saveSondeSettingsOnDismiss() {
        // Update frequency from digits using service layer
        tempDeviceSettings.updateFrequencyFromDigits(freqDigits)
        
        // Delegate command generation and sending to ServiceCoordinator
        serviceCoordinator.sendFrequencyAndTypeToDevice(
            frequency: tempDeviceSettings.frequency,
            probeType: tempDeviceSettings.probeType
        )
        
        // Save to persistence
        persistenceService.save(deviceSettings: tempDeviceSettings)
    }
    
    private func revertSondeSettings() {
        tempDeviceSettings.probeType = initialSondeType
        tempDeviceSettings.frequency = initialFrequency
        updateFreqDigitsFromFrequency()
    }
    
    
    private func updateFreqDigitsFromFrequency() {
        // Business logic moved to DeviceSettings model for proper separation of concerns
        freqDigits = tempDeviceSettings.frequencyToDigits()
    }

    private func frequencyFromDigits() -> Double {
        // Use DeviceSettings method for proper separation of concerns
        var tempSettings = tempDeviceSettings
        tempSettings.updateFrequencyFromDigits(freqDigits)
        return tempSettings.frequency
    }
    
    // MARK: - Tune Settings Logic
    
    private func loadTuneSettings() {
        tempTuneFrequencyCorrection = persistenceService.deviceSettings?.frequencyCorrection ?? 0
        tuneInitialFrequencyCorrection = tempTuneFrequencyCorrection
    }
    
    /// Send the frequency correction value to BLE and save it persistently.
    private func saveTuneSettings(correctionValue: Int) {
        isSavingTune = true
        bleService.sendCommand(command: "o{freqofs=\(correctionValue)}o")
        if var devSettings = persistenceService.deviceSettings {
            devSettings.frequencyCorrection = correctionValue
            persistenceService.save(deviceSettings: devSettings)
        }
        isSavingTune = false
        // Update tempTuneFrequencyCorrection so UI matches saved value
        tempTuneFrequencyCorrection = correctionValue
        tuneInitialFrequencyCorrection = correctionValue
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
                    Picker("Sonde Type", selection: $tempDeviceSettings.probeType) {
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
                    Picker("Sonde Type", selection: $tempDeviceSettings.probeType) {
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
                            .onChange(of: freqDigits[i]) { _, _ in
                                // Update frequency immediately when digits change
                                tempDeviceSettings.frequency = frequencyFromDigits()
                            }
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
            Section(header: Text("Live AFC Value")) {
                VStack(spacing: 15) {
                    Text("\(serviceCoordinator.afcMovingAverage) Hz")
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .padding(.vertical, 10)

                    Button("Transfer") {
                        tempTuneFrequencyCorrection = serviceCoordinator.afcMovingAverage
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
            }
            
            Section(header: Text("Current Offset")) {
                HStack {
                    Text("Current:")
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                    Spacer()
                    Text("\(tuneInitialFrequencyCorrection)")
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                }
            }
            
            Section(header: Text("Calibration")) {
                HStack {
                    Text("New:")
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .fixedSize()
                    TextField("", value: $tempTuneFrequencyCorrection, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10)
                    Spacer()
                    Button("Save") {
                        saveTuneSettings(correctionValue: tempTuneFrequencyCorrection)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!bleService.isReadyForCommands)
                }
            }
        }
        .onAppear {
            loadTuneSettings()
            // AFC tracking moved to ServiceCoordinator for proper separation of concerns
            // No need to manage subscription here - just observe serviceCoordinator.afcFrequencies
        }
        .onDisappear {
            // AFC tracking managed by ServiceCoordinator - no cleanup needed
            // Removed any selectedTab = 0 here to prevent automatic tab switching
        }
        .tabItem { Label("Tune", systemImage: "slider.horizontal.3") }
    }
}
