import SwiftUI

// Main entry point: Sonde Settings
struct SondeSettingsView: View {
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var persistenceService: PersistenceService
    @EnvironmentObject var userSettings: UserSettings
    @Environment(\.dismiss) private var dismiss

    @State private var showDeviceSettings = false
    @State private var showTune = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Text("Sonde Settings (to be implemented)")
                    .font(.title2)
                    .padding()
                HStack {
                    Button("Device Settings") { showDeviceSettings = true }
                        .buttonStyle(.borderedProminent)
                    Button("Tune") { showTune = true }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .padding()
            }
            .navigationTitle("Sonde Settings")
            .sheet(isPresented: $showDeviceSettings) {
                DeviceSettingsView()
                    .environmentObject(bleService)
                    .environmentObject(persistenceService)
                    .environmentObject(userSettings)
            }
            .sheet(isPresented: $showTune) {
                TuneView()
                    .environmentObject(bleService)
            }
        }
    }
}

// DeviceSettingsView with tab structure
struct DeviceSettingsView: View {
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var persistenceService: PersistenceService
    @EnvironmentObject var userSettings: UserSettings
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    var body: some View {
        NavigationStack {
            TabView(selection: $tab) {
                Text("Pins settings here").tabItem { Label("Pins", systemImage: "pin") }.tag(0)
                Text("Battery settings here").tabItem { Label("Battery", systemImage: "battery.100") }.tag(1)
                Text("Radio settings here").tabItem { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }.tag(2)
                Text("Prediction settings here").tabItem { Label("Prediction", systemImage: "cloud.sun") }.tag(3)
                Text("Other settings here").tabItem { Label("Others", systemImage: "ellipsis") }.tag(4)
            }
            .navigationTitle("Device Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// TuneView placeholder
struct TuneView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Tune Function (to be implemented)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

#Preview {
    SondeSettingsView()
        .environmentObject(BLECommunicationService(persistenceService: PersistenceService()))
        .environmentObject(PersistenceService())
        .environmentObject(UserSettings())
}
