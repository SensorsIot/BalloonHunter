import SwiftUI

struct ContentView: View {
    @ObservedObject private var ble = BLEManager.shared
    @StateObject private var locationManager = LocationManager()
    @StateObject private var predictionInfo = PredictionInfo()

    @State private var showMenu = false
    
    @State private var pendingSondeSettingsRequest = false
    @State private var pendingSettingsRequest = false

    @State private var sondeFrequency: String = ""
    @State private var sondeTypeIndex: Int = 0
    @State private var isMuted = false
    
    @State private var showBLEError = false
    
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
    
    private func sheetView(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .settings:
            return AnyView(SettingsView())
        case .sondeSettings:
            return AnyView(SondeSettingsInputView(frequency: $sondeFrequency, sondeTypeIndex: $sondeTypeIndex, sondeTypes: ContentView.sondeTypes))
        }
        // Fallback (should never hit):
        // return AnyView(EmptyView())
    }

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
            .environmentObject(predictionInfo)
    }

    // Compact Sonde data panel per user instructions
    private func telemetrySection(_ geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let telemetry = ble.latestTelemetry {
                    VStack(alignment: .leading, spacing: 6) {
                        // Top bar: loudspeaker top right
                        HStack {
                            Spacer()
                            Button(action: {
                                isMuted.toggle()
                                BLEManager.shared.sendCommand("mute=\(isMuted ? 1 : 0)")
                            }) {
                                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .frame(width: 44, height: 44)
                        }
                        // Data panel follows as before, but with increased font size
                        // First line: Sonde type, number, frequency
                        HStack(spacing: 4) {
                            Text("\(telemetry.probeType),")
                            Text(String(format: "%.3f MHz", telemetry.frequency))
                        }
                        
                        // Second line: Altitude and vertical speed
                        HStack(spacing: 8) {
                            Text("Altitude: \(Int(telemetry.altitude)) m,")
                            Text("V-Speed: \(String(format: "%.1f", telemetry.verticalSpeed)) m/s")
                        }
                        
                        // Third line: Signal and battery
                        HStack(spacing: 8) {
                            Text("Signal: \(Int(telemetry.signalStrength)) dB,")
                            Text("Battery: \(telemetry.batteryPercentage)%")
                        }
                        
                        let formatter: DateFormatter = {
                            let f = DateFormatter()
                            f.timeStyle = .short
                            return f
                        }()
                        
                        // Fourth line: Landing and arrival times on one line
                        HStack(spacing: 8) {
                            if let landingTime = predictionInfo.landingTime {
                                Text("Landing: \(formatter.string(from: landingTime))")
                            } else {
                                Text("Landing: --")
                            }
                            if let arrival = predictionInfo.arrivalTime {
                                Text("Arrival: \(formatter.string(from: arrival))")
                            } else {
                                Text("Arrival: --")
                            }
                        }
                        
                        // Fifth line: distance and remaining flight time, always shown
                        HStack(spacing: 8) {
                            Text("Distance: \(predictionInfo.routeDistanceMeters != nil ? String(format: "%.1f", predictionInfo.routeDistanceMeters! / 1000) : "--") km")
                            if let landing = predictionInfo.landingTime {
                                let minutes = Int(landing.timeIntervalSince(Date()) / 60)
                                Text("Remaining: \(minutes > 0 ? "\(minutes) min" : "now")")
                            } else {
                                Text("Remaining: --")
                            }
                        }
                    }
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .padding(8)
                    .padding(.bottom, 20)
                    .background(Color(.systemBackground).opacity(0.9))
                    .cornerRadius(12)
                    .shadow(radius: 6)
                } else {
                    VStack {
                        Text("No telemetry received yet.")
                            .foregroundColor(.secondary)
                            .padding()
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    mapSection
                        .frame(height: geometry.size.height * 0.8)
                    telemetrySection(geometry)
                        .frame(height: geometry.size.height * 0.2)
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
                                if !BLEManager.shared.isConnected {
                                    showBLEError = true
                                    return
                                }
                                BLEManager.shared.sendCommand("?")
                                pendingSondeSettingsRequest = true
                                showMenu = false
                            }) {
                                Image(systemName: "balloon.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                                    .padding(8)
                            }
                            Button(action: {
                                if !BLEManager.shared.isConnected {
                                    showBLEError = true
                                    return
                                }
                                /* Layers action */
                            }) {
                                Image(systemName: "square.3.layers.3d.down.left")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                                    .padding(8)
                            }
                            Button(action: {
                                if !BLEManager.shared.isConnected {
                                    showBLEError = true
                                    return
                                }
                                /* Car action */
                            }) {
                                Image(systemName: "car.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                                    .padding(8)
                            }
                            Button(action: {
                                if !BLEManager.shared.isConnected {
                                    showBLEError = true
                                    return
                                }
                                print("[WRENCH DEBUG] Wrench button pressed. Sending '?' command.")
                                BLEManager.shared.sendCommand("?")
                                let s = BLEManager.shared.sondeSettings
                                print("[DEBUG] sondeSettings: probeType=\(s.probeType), frequency=\(s.frequency), oledSDA=\(s.oledSDA), oledSCL=\(s.oledSCL), oledRST=\(s.oledRST), ledPin=\(s.ledPin), buzPin=\(s.buzPin), batPin=\(s.batPin), lcdType=\(s.lcdType), batMin=\(s.batMin), batMax=\(s.batMax), batType=\(s.batType), callSign=\(s.callSign), rs41Bandwidth=\(s.rs41Bandwidth), m20Bandwidth=\(s.m20Bandwidth), m10Bandwidth=\(s.m10Bandwidth), pilotBandwidth=\(s.pilotBandwidth), dfmBandwidth=\(s.dfmBandwidth), frequencyCorrection=\(s.frequencyCorrection), lcdOn=\(s.lcdOn), blu=\(s.blu), baud=\(s.baud), com=\(s.com), nameType=\(s.nameType)")
                                pendingSettingsRequest = true
                                print("[WRENCH DEBUG] Set pendingSettingsRequest = true")
                                showMenu = false
                            }) {
                                Image(systemName: "wrench.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                                    .padding(8)
                            }
                            Button(action: {
                                if !BLEManager.shared.isConnected {
                                    showBLEError = true
                                    return
                                }
                                /* Info/help action */
                            }) {
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
            sheetView(for: sheet)
        }
        .alert("No RadiosondyGo Connected", isPresented: $showBLEError) {
            Button("OK", role: .cancel) { showBLEError = false }
        } message: {
            Text("Please connect to a RadiosondyGo device before accessing Sonde settings or device options.")
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
