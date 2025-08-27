// SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var userSettings: UserSettings
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var persistenceService: PersistenceService

    @State private var selection: Int = 0

    var body: some View {
        VStack {
            Picker("", selection: $selection) {
                Text("Sonde").tag(0)
                Text("Device").tag(1)
                Text("Tune").tag(2)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()

            TabView(selection: $selection) {
                SondeSettingsView().tag(0)
                DeviceSettingsView().tag(1)
                TuneView().tag(2)
            }
        }
    }
}

struct SondeSettingsView: View {
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var appSettings: AppSettings

    var body: some View {
        Form {
            TextField("Sonde Type", text: $appSettings.deviceSettings.sondeType)
            TextField("Frequency", value: $appSettings.deviceSettings.frequency, formatter: NumberFormatter())
            Button("Save") {
                bleService.sendCommand(command: "f=\(appSettings.deviceSettings.frequency)/tipo=\(appSettings.deviceSettings.sondeType)")
            }
        }
        .onAppear {
            // Temporary: Start BLE service before sending initial command to ensure connection is ready
            // bleService.start() // <-- Removed as this method does not exist in BLECommunicationService
            bleService.sendCommand(command: "?")
        }
        .onReceive(bleService.$deviceSettings) { settings in
            appSettings.deviceSettings = settings
        }
    }
}

struct DeviceSettingsView: View {
    var body: some View {
        TabView {
            PinsSettingsTab()
                .tabItem { Text("Pins") }
            BatterySettingsTab()
                .tabItem { Text("Battery") }
            RadioSettingsTab()
                .tabItem { Text("Radio") }
            PredictionSettingsTab()
                .tabItem { Text("Prediction") }
            OtherSettingsTab()
                .tabItem { Text("Others") }
        }
    }
}

struct PinsSettingsTab: View {
    @EnvironmentObject var appSettings: AppSettings

    var body: some View {
        Form {
            TextField("OLED SDA", value: $appSettings.deviceSettings.oledSDA, formatter: NumberFormatter())
            TextField("OLED SCL", value: $appSettings.deviceSettings.oledSCL, formatter: NumberFormatter())
            TextField("OLED RST", value: $appSettings.deviceSettings.oledRST, formatter: NumberFormatter())
            TextField("LED Pin", value: $appSettings.deviceSettings.ledPin, formatter: NumberFormatter())
            TextField("Buzzer Pin", value: $appSettings.deviceSettings.buzPin, formatter: NumberFormatter())
        }
    }
}

struct BatterySettingsTab: View {
    @EnvironmentObject var appSettings: AppSettings

    var body: some View {
        Form {
            TextField("Battery Pin", value: $appSettings.deviceSettings.batPin, formatter: NumberFormatter())
            TextField("Min Voltage", value: $appSettings.deviceSettings.batMin, formatter: NumberFormatter())
            TextField("Max Voltage", value: $appSettings.deviceSettings.batMax, formatter: NumberFormatter())
            TextField("Battery Type", value: $appSettings.deviceSettings.batType, formatter: NumberFormatter())
        }
    }
}

struct RadioSettingsTab: View {
    @EnvironmentObject var appSettings: AppSettings

    var body: some View {
        Form {
            TextField("Call Sign", text: $appSettings.deviceSettings.callSign)
            TextField("RS41 Bandwidth", value: $appSettings.deviceSettings.RS41Bandwidth, formatter: NumberFormatter())
            TextField("M20 Bandwidth", value: $appSettings.deviceSettings.M20Bandwidth, formatter: NumberFormatter())
            TextField("M10 Bandwidth", value: $appSettings.deviceSettings.M10Bandwidth, formatter: NumberFormatter())
            TextField("PILOT Bandwidth", value: $appSettings.deviceSettings.PILOTBandwidth, formatter: NumberFormatter())
            TextField("DFM Bandwidth", value: $appSettings.deviceSettings.DFMBandwidth, formatter: NumberFormatter())
        }
    }
}

struct PredictionSettingsTab: View {
    @EnvironmentObject var userSettings: UserSettings

    var body: some View {
        Form {
            TextField("Burst Altitude", value: $userSettings.burstAltitude, formatter: NumberFormatter())
            TextField("Ascent Rate", value: $userSettings.ascentRate, formatter: NumberFormatter())
            TextField("Descent Rate", value: $userSettings.descentRate, formatter: NumberFormatter())
        }
    }
}

struct OtherSettingsTab: View {
    @EnvironmentObject var appSettings: AppSettings

    var body: some View {
        Form {
            TextField("LCD Status", value: $appSettings.deviceSettings.lcdStatus, formatter: NumberFormatter())
            TextField("Bluetooth Status", value: $appSettings.deviceSettings.bluetoothStatus, formatter: NumberFormatter())
            TextField("Serial Speed", value: $appSettings.deviceSettings.serialSpeed, formatter: NumberFormatter())
            TextField("Serial Port", value: $appSettings.deviceSettings.serialPort, formatter: NumberFormatter())
            TextField("APRS Name", value: $appSettings.deviceSettings.aprsName, formatter: NumberFormatter())
        }
    }
}

struct TuneView: View {
    @EnvironmentObject var bleService: BLECommunicationService
    @State private var afcValues: [Int] = []
    @State private var movingAverage: Double = 0.0

    var body: some View {
        VStack {
            Text("AFC Moving Average: \(movingAverage, specifier: "%.2f")")
            Button("Save") {
                bleService.sendCommand(command: "freqofs=\(Int(movingAverage))")
            }
        }
        .onReceive(bleService.telemetryData) { telemetry in
            afcValues.append(telemetry.afcFrequency)
            if afcValues.count > 20 {
                afcValues.removeFirst()
            }
            movingAverage = Double(afcValues.reduce(0, +)) / Double(afcValues.count)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
        .environmentObject(UserSettings())
        .environmentObject(BLECommunicationService(persistenceService: PersistenceService()))
        .environmentObject(PersistenceService())
}
