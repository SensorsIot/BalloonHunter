import SwiftUI
import Foundation
import Combine

struct SettingsView: View {
    @EnvironmentObject var serviceManager: ServiceManager

    @State private var selectedTab = 0
    @State private var workingDeviceSettings: DeviceSettings = .default // Working copy for UI
    @State private var originalDeviceSettings: DeviceSettings = .default // For Undo
    @State private var workingUserSettings: UserSettings = .default // Working copy for UI
    @State private var originalUserSettings: UserSettings = .default // For Undo

    @State private var isConnectedToSonde = false
    @State private var showSondeNotConnectedMessage = false

    var body: some View {
        VStack {
            Picker("Settings Tab", selection: $selectedTab) {
                Text("Sonde").tag(0)
                Text("Settings").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()

            if showSondeNotConnectedMessage {
                Text("Sonde not connected")
                    .foregroundColor(.red)
                    .padding()
            }

            TabView(selection: $selectedTab) {
                // Sonde Tab
                SondeSettingsView(
                    workingDeviceSettings: $workingDeviceSettings,
                    originalDeviceSettings: $originalDeviceSettings,
                    isConnectedToSonde: $isConnectedToSonde
                )
                .tabItem {
                    Label("Sonde", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(0)

                // Settings Tab
                DeviceSettingsView(
                    workingDeviceSettings: $workingDeviceSettings,
                    originalDeviceSettings: $originalDeviceSettings,
                    workingUserSettings: $workingUserSettings,
                    originalUserSettings: $originalUserSettings,
                    isConnectedToSonde: $isConnectedToSonde
                )
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(1)
            }
        }
        .onAppear {
            // Initialize working copies with fresh data from PersistenceService
            // These will be updated by onReceive when deviceSettings are actually received
            workingDeviceSettings = serviceManager.persistenceService.deviceSettings ?? .default
            originalDeviceSettings = serviceManager.persistenceService.deviceSettings ?? .default
            workingUserSettings = serviceManager.persistenceService.userSettings
            originalUserSettings = serviceManager.persistenceService.userSettings

            // Set initial state based on sonde connection status
            isConnectedToSonde = serviceManager.bleCommunicationService.connectionStatus == .connected
            showSondeNotConnectedMessage = serviceManager.bleCommunicationService.connectionStatus != .connected

            // Request current settings from MySondyGo
            // serviceManager.bleCommunicationService.connect() // No direct connect method, handled by BLECommunicationService init
        }
        .onDisappear {
            // Save UserSettings (Prediction tab)
            serviceManager.persistenceService.save(userSettings: workingUserSettings)
            
            // Send DeviceSettings to sonde if connected and changed
            if isConnectedToSonde && workingDeviceSettings != originalDeviceSettings {
                let command = "o{f=\(workingDeviceSettings.frequency)/tipo=\(workingDeviceSettings.sondeType)}o"
                serviceManager.bleCommunicationService.sendCommand(command: command)
            }
            serviceManager.bleCommunicationService.disconnect()
        }
        .onChange(of: serviceManager.bleCommunicationService.connectionStatus) { oldValue, newValue in
            print("[DEBUG] SettingsView: onChange - isConnected: \(newValue)")
            isConnectedToSonde = newValue == .connected
            showSondeNotConnectedMessage = newValue != .connected
            if newValue == .connected {
                // If connected, update working copies with fresh data
                workingDeviceSettings = serviceManager.persistenceService.deviceSettings ?? .default
                originalDeviceSettings = serviceManager.persistenceService.deviceSettings ?? .default
            }
        }
        
    }

    // MARK: - Nested Views

    struct SondeSettingsView: View {
        @EnvironmentObject var serviceManager: ServiceManager

        @Binding var workingDeviceSettings: DeviceSettings
        @Binding var originalDeviceSettings: DeviceSettings
        @Binding var isConnectedToSonde: Bool

        @State private var isShowingTuneView = false

        // Define the formatter here
        private static let threeDecimalFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 3
            formatter.maximumFractionDigits = 3
            return formatter
        }()

        var body: some View {
            VStack(alignment: .leading, spacing: 20) { // Use VStack for overall layout
                Text("Sonde Type and Frequency")
                    .font(.headline)
                    .padding(.bottom, 5)

                Picker("Sonde Type", selection: $workingDeviceSettings.sondeType) {
                    Text("RS41").tag("RS41")
                    Text("M20").tag("M20")
                    Text("M10").tag("M10")
                    Text("PILOT").tag("PILOT")
                    Text("DFM").tag("DFM")
                }
                .pickerStyle(.segmented) // Modern segmented picker
                .disabled(!isConnectedToSonde)

                TextField("Frequency (MHz)", value: $workingDeviceSettings.frequency, formatter: SondeSettingsView.threeDecimalFormatter) // Use the custom formatter
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder) // Modern text field style
                    .disabled(!isConnectedToSonde)

                VStack(alignment: .leading) {
                    Text("Frequency (MHz): \(workingDeviceSettings.frequency, specifier: "%.3f")")
                        .font(.subheadline)
                    Slider(value: $workingDeviceSettings.frequency, in: 100.0...500.0, step: 0.001) { // Example range and step
                        Text("Frequency")
                    } minimumValueLabel: {
                        Text("100.000")
                    } maximumValueLabel: {
                        Text("500.000")
                    }
                    .disabled(!isConnectedToSonde)
                }
                .padding(.top, 10)

                // Buttons
                VStack(spacing: 15) { // VStack for buttons
                    Button("Restore") {
                        workingDeviceSettings = originalDeviceSettings
                    }
                    .buttonStyle(.plain)
                    .font(.body)
                    .foregroundColor(.red)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Capsule().fill(Color.red.opacity(0.1)))
                    .overlay(Capsule().stroke(Color.red, lineWidth: 1))
                    .disabled(!isConnectedToSonde)

                    Button("Tune") {
                        isShowingTuneView = true
                    }
                    .buttonStyle(.plain)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .background(Capsule().fill(Color.accentColor))
                    .disabled(!isConnectedToSonde)
                }
                .frame(maxWidth: .infinity) // Center buttons horizontally
            }
            .padding() // Overall padding for the view
            .background(Color(.systemGroupedBackground)) // Clean background
            .cornerRadius(15) // Rounded corners for the whole view
            .shadow(radius: 5) // Subtle shadow
            .sheet(isPresented: $isShowingTuneView) {
                TuneView(isShowingTuneView: $isShowingTuneView)
            }
        }
    }

    struct DeviceSettingsView: View {
        @EnvironmentObject var serviceManager: ServiceManager

        @Binding var workingDeviceSettings: DeviceSettings
        @Binding var originalDeviceSettings: DeviceSettings
        @Binding var workingUserSettings: UserSettings
        @Binding var originalUserSettings: UserSettings
        @Binding var isConnectedToSonde: Bool

        @State private var selectedSubTab = 0

        var body: some View {
            VStack {
                Picker("Device Settings Tab", selection: $selectedSubTab) {
                    Text("Pins").tag(0)
                    Text("Battery").tag(1)
                    Text("Radio").tag(2)
                    Text("Prediction").tag(3)
                    Text("Others").tag(4)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()

                if !isConnectedToSonde {
                    Text("Sonde not connected. Device settings are disabled.")
                        .foregroundColor(.red)
                        .padding()
                }

                TabView(selection: $selectedSubTab) {
                    // Pins Tab
                    PinsSettingsView(workingDeviceSettings: $workingDeviceSettings, isConnectedToSonde: $isConnectedToSonde)
                        .tabItem { Label("Pins", systemImage: "pin.fill") }.tag(0)
                    // Battery Tab
                    BatterySettingsView(workingDeviceSettings: $workingDeviceSettings, isConnectedToSonde: $isConnectedToSonde)
                        .tabItem { Label("Battery", systemImage: "battery.100.bolt") }.tag(1)
                    // Radio Tab
                    RadioSettingsView(workingDeviceSettings: $workingDeviceSettings, isConnectedToSonde: $isConnectedToSonde)
                        .tabItem { Label("Radio", systemImage: "antenna.radiowaves.left.and.right") }.tag(2)
                    // Prediction Tab
                    PredictionSettingsView(workingUserSettings: $workingUserSettings)
                        .tabItem { Label("Prediction", systemImage: "chart.line.uptrend.rectangle") }.tag(3)
                    // Others Tab
                    OthersSettingsView(workingDeviceSettings: $workingDeviceSettings, isConnectedToSonde: $isConnectedToSonde)
                        .tabItem { Label("Others", systemImage: "ellipsis.circle") }.tag(4)
                }
                
                HStack {
                    Button("Undo") {
                        workingDeviceSettings = originalDeviceSettings
                        workingUserSettings = originalUserSettings
                    }
                    .disabled(!isConnectedToSonde && selectedSubTab != 3) // Disable if not connected, unless it's Prediction tab
                    
                    Spacer()
                    
                    Button("Save") {
                        // This save button is for the whole DeviceSettingsView
                        // The actual BLE command sending will happen on onDisappear of SettingsView
                        // For now, just update original settings for undo
                        originalDeviceSettings = workingDeviceSettings
                        originalUserSettings = workingUserSettings
                    }
                    .disabled(!isConnectedToSonde && selectedSubTab != 3)
                }
                .padding()
            }
        }
    }

    struct PinsSettingsView: View {
        @Binding var workingDeviceSettings: DeviceSettings
        @Binding var isConnectedToSonde: Bool
        var body: some View {
            Form {
                Section(header: Text("OLED Pins")) {
                    TextField("OLED SDA", value: $workingDeviceSettings.oledSDA, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .disabled(!isConnectedToSonde)
                    TextField("OLED SCL", value: $workingDeviceSettings.oledSCL, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .disabled(!isConnectedToSonde)
                    TextField("OLED RST", value: $workingDeviceSettings.oledRST, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .disabled(!isConnectedToSonde)
                }
                Section(header: Text("Other Pins")) {
                    TextField("LED Pin", value: $workingDeviceSettings.ledPin, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .disabled(!isConnectedToSonde)
                    TextField("Buzzer Pin", value: $workingDeviceSettings.buzPin, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .disabled(!isConnectedToSonde)
                    TextField("LCD Type", value: $workingDeviceSettings.lcdType, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .disabled(!isConnectedToSonde)
                }
            }
        }
    }

    struct BatterySettingsView: View {
        @Binding var workingDeviceSettings: DeviceSettings
        @Binding var isConnectedToSonde: Bool

        var body: some View {
            Form {
                Section(header: Text("Battery Settings")) {
                    TextField("Battery Pin", value: $workingDeviceSettings.batPin, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .disabled(!isConnectedToSonde)
                    TextField("Battery Min (mV)", value: $workingDeviceSettings.batMin, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .disabled(!isConnectedToSonde)
                    TextField("Battery Max (mV)", value: $workingDeviceSettings.batMax, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .disabled(!isConnectedToSonde)
                    Picker("Battery Type", selection: $workingDeviceSettings.batType) {
                        Text("Type 0").tag(0)
                        Text("Type 1").tag(1)
                        // Add more types as needed
                    }
                    .disabled(!isConnectedToSonde)
                }
            }
        }
    }

    struct RadioSettingsView: View {
        @Binding var workingDeviceSettings: DeviceSettings
        @Binding var isConnectedToSonde: Bool

        var body: some View {
            Form {
                Section(header: Text("Radio Settings")) {
                    TextField("Call Sign", text: $workingDeviceSettings.callSign)
                        .disabled(!isConnectedToSonde)
                    Picker("RS41 Bandwidth", selection: $workingDeviceSettings.RS41Bandwidth) {
                        ForEach(0..<8) { i in
                            Text("\(i)").tag(i)
                        }
                    }
                    .disabled(!isConnectedToSonde)
                    Picker("M20 Bandwidth", selection: $workingDeviceSettings.M20Bandwidth) {
                        ForEach(0..<8) { i in
                            Text("\(i)").tag(i)
                        }
                    }
                    .disabled(!isConnectedToSonde)
                    Picker("M10 Bandwidth", selection: $workingDeviceSettings.M10Bandwidth) {
                        ForEach(0..<8) { i in
                            Text("\(i)").tag(i)
                        }
                    }
                    .disabled(!isConnectedToSonde)
                    Picker("PILOT Bandwidth", selection: $workingDeviceSettings.PILOTBandwidth) {
                        ForEach(0..<8) { i in
                            Text("\(i)").tag(i)
                        }
                    }
                    .disabled(!isConnectedToSonde)
                    Picker("DFM Bandwidth", selection: $workingDeviceSettings.DFMBandwidth) {
                        ForEach(0..<8) { i in
                            Text("\(i)").tag(i)
                        }
                    }
                    .disabled(!isConnectedToSonde)
                }
            }
        }
    }

    struct PredictionSettingsView: View {
        @EnvironmentObject var serviceManager: ServiceManager
        @Binding var workingUserSettings: UserSettings

        var body: some View {
            Form {
                Section(header: Text("Prediction Settings")) {
                    TextField("Burst Altitude (m)", value: $workingUserSettings.burstAltitude, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                    TextField("Ascent Rate (m/s)", value: $workingUserSettings.ascentRate, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                    TextField("Descent Rate (m/s)", value: $workingUserSettings.descentRate, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                }
            }
        }
    }

    struct OthersSettingsView: View {
        @Binding var workingDeviceSettings: DeviceSettings
        @Binding var isConnectedToSonde: Bool

        var body: some View {
            Form {
                Section(header: Text("Other Settings")) {
                    Toggle("LCD On", isOn: Binding(get: { workingDeviceSettings.lcdStatus == 1 }, set: { workingDeviceSettings.lcdStatus = $0 ? 1 : 0 }))
                        .disabled(!isConnectedToSonde)
                    Toggle("Bluetooth On", isOn: Binding(get: { workingDeviceSettings.bluetoothStatus == 1 }, set: { workingDeviceSettings.bluetoothStatus = $0 ? 1 : 0 }))
                        .disabled(!isConnectedToSonde)
                    TextField("Serial Speed", value: $workingDeviceSettings.serialSpeed, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .disabled(!isConnectedToSonde)
                    TextField("Serial Port", value: $workingDeviceSettings.serialPort, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .disabled(!isConnectedToSonde)
                    Picker("APRS Name Type", selection: $workingDeviceSettings.nameType) {
                        Text("Type 0").tag(0)
                        Text("Type 1").tag(1)
                        // Add more types as needed
                    }
                    .disabled(!isConnectedToSonde)
                }
            }
        }
    }

    struct TuneView: View {
        @EnvironmentObject var serviceManager: ServiceManager

        @Binding var isShowingTuneView: Bool // To dismiss the view

        @State private var currentAFCAverage: Double = 0.0
        @State private var currentFrequencyCorrection: Int = 0

        var body: some View {
            VStack {
                Text("Tune Function")
                    .font(.largeTitle)
                    .padding()

                Text("Moving Average of AFC (last 20 messages): \(currentAFCAverage, specifier: "%.2f")")
                    .font(.title2)
                    .padding()

                Text("Current Frequency Correction: \(currentFrequencyCorrection)")
                    .font(.title2)
                    .padding()

                HStack {
                    Button("Save") {
                        // Save the current AFC average as frequencyCorrection
                        // This requires sending a BLE command: setFreqCorrection
                        // The command format is not specified, assuming "o{freqcorr=value}o"
                        let command = "o{freqcorr=\(Int(currentAFCAverage))}o"
                        serviceManager.bleCommunicationService.sendCommand(command: command)
                        
                        // Update local device settings with the new frequency correction
                        var updatedSettings = serviceManager.persistenceService.deviceSettings ?? .default
                        updatedSettings.frequencyCorrection = Int(currentAFCAverage)
                        serviceManager.persistenceService.save(deviceSettings: updatedSettings)

                        // Update local state
                        currentFrequencyCorrection = Int(currentAFCAverage)
                    }
                    .padding()

                    Button("Cancel") {
                        isShowingTuneView = false // Dismiss the view
                    }
                    .padding()
                }
            }
            .onAppear {
                // Initialize current frequency correction from device settings
                currentFrequencyCorrection = serviceManager.persistenceService.deviceSettings?.frequencyCorrection ?? 0
            }
            .onReceive(serviceManager.bleCommunicationService.$afcHistory) { afcHistory in
                // Calculate moving average
                if !afcHistory.isEmpty {
                    let sum = afcHistory.reduce(0, +)
                    currentAFCAverage = Double(sum) / Double(afcHistory.count)
                } else {
                    currentAFCAverage = 0.0
                }
            }
        }
    }
}

// MARK: - Preview
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(ServiceManager())
    }
}
