import SwiftUI

struct ContentView: View {
    @ObservedObject private var ble = BLEManager.shared
    @StateObject private var locationManager = LocationManager()

    @State private var showMenu = false
    
    @State private var pendingSondeSettingsRequest = false
    @State private var pendingSettingsRequest = false

    @State private var sondeFrequency: String = ""
    @State private var sondeTypeIndex: Int = 0
    
    enum ActiveSheet: Identifiable {
        case settings, sondeSettings
        var id: Int {
            switch self {
            case .settings: return 0
            case .sondeSettings: return 1
            }
        }
    }
    @State private var activeSheet: ActiveSheet?

    static let sondeTypes = ["RS41", "M20", "M10", "PILOT", "DFM"]

    static let sondeTypeIdMap: [String: Int] = [
        "RS41": 1,
        "M20": 2,
        "M10": 3,
        "PILOT": 4,
        "DFM": 5
    ]

    enum MenuItem: String, CaseIterable, Identifiable {
        case sondeSettings = "Sonde settings"
        case settings = "Settings"

        var id: String { rawValue }
    }

    private var mapSection: some View {
        MapView(locationManager: locationManager)
    }

    private func telemetrySection(_ geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: geometry.size.height * 0.8)
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

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    mapSection
                        .frame(height: geometry.size.height * 0.8)
                }
                .overlay(
                    VStack {
                        HStack {
                            Button {
                                showMenu = true
                            } label: {
                                Image(systemName: "line.horizontal.3")
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundColor(.primary)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(.ultraThinMaterial)
                                            .opacity(0.85)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                    )
                                    .shadow(radius: 2, y: 1)
                            }
                            .accessibilityLabel("Menu")
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding([.top, .leading], 16)
                    , alignment: .topLeading
                )

                telemetrySection(geometry)
            }
            
            if showMenu {
                HStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.2)
                            .frame(width: 88)
                            .edgesIgnoringSafeArea(.all)
                        VStack(spacing: 36) {
                            Spacer().frame(height: 48)
                            Button(action: {
                                BLEManager.shared.sendCommand("?")
                                pendingSondeSettingsRequest = true
                                showMenu = false
                            }) {
                                Image(systemName: "balloon.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                                    .padding(8)
                            }
                            Button(action: { /* Layers action */ }) {
                                Image(systemName: "square.3.layers.3d.down.left")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                                    .padding(8)
                            }
                            Button(action: { /* Car action */ }) {
                                Image(systemName: "car.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                                    .padding(8)
                            }
                            Button(action: {
                                // Pressing wrench triggers BLE settings request.
                                // The settings sheet will open only after the response is received and processed.
                                print("[WRENCH DEBUG] Wrench button pressed.")
                                print("[WRENCH DEBUG] Calling sendCommand('?') on BLEManager.")
                                BLEManager.shared.sendCommand("?")
                                let s = BLEManager.shared.sondeSettings
                                print("[DEBUG] sondeSettings: probeType=\(s.probeType), frequency=\(s.frequency), oledSDA=\(s.oledSDA), oledSCL=\(s.oledSCL), oledRST=\(s.oledRST), ledPin=\(s.ledPin), buzPin=\(s.buzPin), batPin=\(s.batPin), lcdType=\(s.lcdType), batMin=\(s.batMin), batMax=\(s.batMax), batType=\(s.batType), callSign=\(s.callSign), rs41Bandwidth=\(s.rs41Bandwidth), m20Bandwidth=\(s.m20Bandwidth), m10Bandwidth=\(s.m10Bandwidth), pilotBandwidth=\(s.pilotBandwidth), dfmBandwidth=\(s.dfmBandwidth), frequencyCorrection=\(s.frequencyCorrection), lcdOn=\(s.lcdOn), blu=\(s.blu), baud=\(s.baud), com=\(s.com), nameType=\(s.nameType)")
                                print("[WRENCH DEBUG] Set pendingSettingsRequest = true")
                                pendingSettingsRequest = true
                                showMenu = false
                            }) {
                                Image(systemName: "wrench.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                                    .padding(8)
                            }
                            Button(action: { /* Info/help action */ }) {
                                Image(systemName: "questionmark.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                                    .padding(8)
                            }
                            Spacer()
                        }
                    }
                    Spacer()
                }
                .transition(.move(edge: .leading))
                .animation(.easeInOut, value: showMenu)
                .zIndex(100)
                .onTapGesture {
                    showMenu = false
                }
            }
        }
        // MARK: - Handle BLE settings response separately from telemetry updates
        .onReceive(BLEManager.shared.$receivedText) { receivedText in
            print("[WRENCH DEBUG] .onReceive: receivedText updated.")
            // Check if there is a pending settings request and if the received text contains a line ending with "/o"
            // which indicates the settings response is received
            if pendingSettingsRequest, receivedText.contains("\n"), receivedText.components(separatedBy: "\n").contains(where: { $0.hasSuffix("/o") }) {
                print("[WRENCH DEBUG] Settings response detected, showing settings sheet.")
                activeSheet = .settings
                pendingSettingsRequest = false
                // Optionally clear receivedText if desired:
                // BLEManager.shared.receivedText = ""
            }
        }
        .onChange(of: ble.latestTelemetry) { telemetry in
            if pendingSondeSettingsRequest {
                if let telemetry = telemetry {
                    sondeFrequency = String(format: "%.3f", telemetry.frequency)
                    if let index = ContentView.sondeTypes.firstIndex(of: telemetry.probeType) {
                        sondeTypeIndex = index
                    } else {
                        sondeTypeIndex = 0
                    }
                } else {
                    sondeFrequency = ""
                    sondeTypeIndex = 0
                }
                activeSheet = .sondeSettings
                pendingSondeSettingsRequest = false
            }
            // Removed the else if activeSheet == .sondeSettings block to prevent overwriting user input
        }
        .navigationTitle("Sonde Tracker")
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView()
            case .sondeSettings:
                SondeSettingsInputView(frequency: $sondeFrequency, sondeTypeIndex: $sondeTypeIndex, sondeTypes: ContentView.sondeTypes)
            }
        }
    }
}

struct SondeSettingsInputView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var frequency: String
    @Binding var sondeTypeIndex: Int
    let sondeTypes: [String]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Sonde Settings")) {
                    TextField("Frequency (MHz)", text: $frequency)
                        .keyboardType(.decimalPad)
                    Picker("Sonde Type", selection: $sondeTypeIndex) {
                        ForEach(sondeTypes.indices, id: \.self) { index in
                            Text(sondeTypes[index]).tag(index)
                        }
                    }
                    .pickerStyle(WheelPickerStyle())
                }
                Section {
                    Button("Submit") {
                        submit()
                    }
                }
            }
            .navigationTitle("Sonde Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func submit() {
        BLEManager.shared.sendCommand("f=\(frequency)")
        let selectedType = sondeTypes[sondeTypeIndex]
        let mappedId = ContentView.sondeTypeIdMap[selectedType] ?? 1
        BLEManager.shared.sendCommand("tipo=\(mappedId)")
        dismiss()
    }
}

#Preview {
    ContentView()
}

