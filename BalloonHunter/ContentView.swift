import SwiftUI

struct ContentView: View {
    @State private var showingMenu = false
    @ObservedObject private var ble = BLEManager.shared
    @StateObject private var locationManager = LocationManager()

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    MapView(locationManager: locationManager)
                        .frame(height: geometry.size.height * 0.8)
                    
                    Group {
                        if let telemetry = ble.latestTelemetry {
                            GroupBox(label: Text("Sonde Data").font(.headline)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text("Type:"); Spacer(); Text("\(telemetry.probeType)").bold() }
                                    HStack { Text("Freq:"); Spacer(); Text(String(format: "%.3f MHz", telemetry.frequency)).bold() }
                                    HStack { Text("Lat/Lon:"); Spacer(); Text("\(telemetry.latitude), \(telemetry.longitude)").bold() }
                                    HStack { Text("Alt:"); Spacer(); Text("\(Int(telemetry.altitude)) m").bold() }
                                    HStack { Text("Batt:"); Spacer(); Text("\(telemetry.batteryPercentage)%").bold() }
                                    HStack { Text("Signal:"); Spacer(); Text("\(Int(telemetry.signalStrength)) dB").bold() }
                                    HStack { Text("FW:"); Spacer(); Text(telemetry.firmwareVersion).font(.caption) }
                                }
                            }
                            .padding()
                            .background(Color(.systemBackground).opacity(0.9))
                            .cornerRadius(12)
                            .shadow(radius: 6)
                            .frame(maxWidth: .infinity, alignment: .top)
                        } else {
                            VStack {
                                Text("No telemetry received yet.")
                                    .foregroundColor(.secondary)
                                    .padding()
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .background(Color(.systemGroupedBackground))
                    .frame(height: geometry.size.height * 0.2)
                }
            }

            // Hamburger menu button
            Button(action: { showingMenu.toggle() }) {
                Image(systemName: "line.horizontal.3")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.primary)
                    .shadow(radius: 3)
                    .padding(16)
                    .background(Color(.systemBackground).opacity(0.8))
                    .clipShape(Circle())
            }
            .padding(.top, 32)
            .padding(.leading, 16)
            .accessibilityLabel("Menu")
            .sheet(isPresented: $showingMenu) {
                SettingsView()
            }
        }
    }
}

#Preview {
    ContentView()
}
