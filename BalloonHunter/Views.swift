// Views.swift
// Contains all small and supporting SwiftUI views, merged for clarity

import SwiftUI

// MARK: - SettingsView (formerly SettingsView.swift)
private let lcdTypeNames = ["SSD1306", "SH1106"]

struct SettingsView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @State private var editSettings: SondeSettings = SondeSettings()

    var body: some View {
        Form {
            Section(header: Text("Display Settings")) {
                Picker("LCD Type", selection: $editSettings.lcdType) {
                    ForEach(lcdTypeNames.indices, id: \.self) { idx in
                        Text(lcdTypeNames[idx]).tag(idx)
                    }
                }
                TextField("OLED SDA Pin", value: $editSettings.oledSDA, formatter: NumberFormatter())
                TextField("OLED SCL Pin", value: $editSettings.oledSCL, formatter: NumberFormatter())
            }

            Section(header: Text("Radio Settings")) {
                TextField("Frequency (MHz)", value: $editSettings.frequency, formatter: NumberFormatter())
            }

            Button("Save") {
                viewModel.updateSondeSettings(editSettings)
            }
        }
        .onAppear {
            editSettings = viewModel.sondeSettings
        }
    }
}

// MARK: - SettingsSheetView and subviews (formerly ContentView.swift)
struct SettingsSheetView: View {
    @State private var isShowingSondeSettings = false
    @State private var isShowingAppSettings = false
    @State private var isShowingBluetoothSettings = false
    
    var body: some View {
        NavigationView {
            List {
                Button("Sonde Settings") {
                    isShowingSondeSettings = true
                }
                .sheet(isPresented: $isShowingSondeSettings) {
                    SondeSettingsView()
                }
                
                Button("App Settings") {
                    isShowingAppSettings = true
                }
                .sheet(isPresented: $isShowingAppSettings) {
                    AppSettingsView()
                }
                
                Button("Bluetooth Settings") {
                    isShowingBluetoothSettings = true
                }
                .sheet(isPresented: $isShowingBluetoothSettings) {
                    BluetoothSettingsView()
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct SondeSettingsView: View {
    @State private var threshold = AppSettings.shared.settings.threshold
    @State private var isEnabled = AppSettings.shared.settings.isEnabled
    
    var body: some View {
        Form {
            Toggle("Enabled", isOn: $isEnabled)
            Slider(value: $threshold, in: 0...1) {
                Text("Threshold")
            }
        }
        .padding()
        .navigationTitle("Sonde Settings")
        .onDisappear {
            AppSettings.shared.settings.isEnabled = isEnabled
            AppSettings.shared.settings.threshold = threshold
        }
    }
}

struct AppSettingsView: View {
    @State private var darkMode = AppSettings.shared.settings.darkMode
    
    var body: some View {
        Form {
            Toggle("Dark Mode", isOn: $darkMode)
        }
        .padding()
        .navigationTitle("App Settings")
        .onDisappear {
            AppSettings.shared.settings.darkMode = darkMode
        }
    }
}

struct BluetoothSettingsView: View {
    @State private var deviceName = AppSettings.shared.settings.deviceName
    
    var body: some View {
        Form {
            TextField("Device Name", text: $deviceName)
        }
        .padding()
        .navigationTitle("Bluetooth Settings")
        .onDisappear {
            AppSettings.shared.settings.deviceName = deviceName
        }
    }
}

// MARK: - Previews
struct SettingsSheetView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsSheetView()
    }
}
