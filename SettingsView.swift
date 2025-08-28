import SwiftUI
import CoreBluetooth

struct SettingsView: View {
    @EnvironmentObject var bleCommunicationService: BLECommunicationService
    @EnvironmentObject var persistenceService: PersistenceService

    @State private var currentSondeType: String = "RS41"
    @State private var currentFrequency: Double = 403.500

    @State private var initialSondeType: String = "RS41"
    @State private var initialFrequency: Double = 403.500

    // For digit-by-digit frequency input
    @State private var freqHundreds: Int = 4
    @State private var freqTens: Int = 0
    @State private var freqUnits: Int = 3
    @State private var freqDecimal1: Int = 5
    @State private var freqDecimal2: Int = 0
    @State private var freqDecimal3: Int = 0

    let sondeTypes = ["RS41", "M20", "M10", "PILOT", "DFM"]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Sonde Settings")) {
                    if bleCommunicationService.connectionStatus == .disconnected {
                        Text("Sonde not connected")
                            .foregroundColor(.red)
                    } else {
                        Picker("Sonde Type", selection: $currentSondeType) {
                            ForEach(sondeTypes, id: \.self) { type in
                                Text(type).tag(type)
                            }
                        }
                        .pickerStyle(.menu)

                        VStack(alignment: .leading) {
                            Text("Frequency")
                            HStack(spacing: 0) {
                                // First digit (fixed for now as per requirement)
                                Text("4")
                                    .font(.title2)
                                    .frame(width: 20)

                                // Tens digit (now fixed)
                                Text("0")
                                    .font(.title2)
                                    .frame(width: 20)

                                // Units digit
                                Picker("", selection: $freqUnits) {
                                    ForEach(0..<10) { digit in
                                        Text("\(digit)").tag(digit)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 96, height: 120)
                                .clipped()
                                .font(.system(size: 110, weight: .black))
                                .padding(.horizontal, -10)

                                Text(".")
                                    .font(.title2)

                                // First decimal digit
                                Picker("", selection: $freqDecimal1) {
                                    ForEach(0..<10) { digit in
                                        Text("\(digit)").tag(digit)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 96, height: 120)
                                .clipped()
                                .font(.system(size: 110, weight: .black))
                                .padding(.horizontal, -10)

                                // Second decimal digit
                                Picker("", selection: $freqDecimal2) {
                                    ForEach(0..<10) { digit in
                                        Text("\(digit)").tag(digit)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 96, height: 120)
                                .clipped()
                                .font(.system(size: 110, weight: .black))
                                .padding(.horizontal, -10)
                            }
                            .onChange(of: freqTens) { updateFrequency() }
                            .onChange(of: freqUnits) { updateFrequency() }
                            .onChange(of: freqDecimal1) { updateFrequency() }
                            .onChange(of: freqDecimal2) { updateFrequency() }
                        }

                        Button("Restore") {
                            currentSondeType = initialSondeType
                            currentFrequency = initialFrequency
                            updateFrequencyDigits(from: initialFrequency)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                // Initialize from BLECommunicationService's deviceSettings
                currentSondeType = bleCommunicationService.deviceSettings.sondeType
                currentFrequency = bleCommunicationService.deviceSettings.frequency

                // Store initial values for restore
                initialSondeType = currentSondeType
                initialFrequency = currentFrequency

                // Update frequency digits from the current frequency
                updateFrequencyDigits(from: currentFrequency)
            }
            .onDisappear { [bleCommunicationService, persistenceService] in
                print("[DEBUG] SettingsView onDisappear triggered. Connection status: \(bleCommunicationService.connectionStatus)")
                // Save settings when leaving the view
                if bleCommunicationService.connectionStatus != .disconnected {
                    // Update internal settings before sending command
                    bleCommunicationService.deviceSettings.sondeType = currentSondeType
                    bleCommunicationService.deviceSettings.frequency = currentFrequency
                    persistenceService.save(deviceSettings: bleCommunicationService.deviceSettings)
                    
                    // Map sondeType to probeType code
                    let probeTypeCode: Int = {
                        switch currentSondeType.uppercased() {
                        case "RS41": return 1
                        case "M20": return 2
                        case "M10": return 3
                        case "PILOT": return 4
                        case "DFM": return 5
                        default: return 1
                        }
                    }()
                    bleCommunicationService.sendSettingsCommand(frequency: currentFrequency, probeType: probeTypeCode)
                    
                    // Previous line commented out as per instruction:
                    // var updatedSettings = bleCommunicationService.deviceSettings
                    // updatedSettings.sondeType = currentSondeType
                    // updatedSettings.frequency = currentFrequency
                    // bleCommunicationService.sendCommand(command: updatedSettings.toCommandString())
                }
            }
        }
    }

    private func updateFrequency() {
        let combinedFrequencyString = String(format: "40%d.%d%d",
                                             freqUnits,
                                             freqDecimal1,
                                             freqDecimal2)
        if let newFreq = Double(combinedFrequencyString) {
            currentFrequency = newFreq
        }
    }

    private func updateFrequencyDigits(from frequency: Double) {
        let frequencyString = String(format: "%.2f", frequency)
        let components = frequencyString.components(separatedBy: ".")

        if components.count == 2 {
            let integerPart = components[0]
            let decimalPart = components[1]

            // Only update freqUnits, as freqHundreds and freqTens are fixed
            if integerPart.count >= 3 {
                freqUnits = Int(String(integerPart[integerPart.index(integerPart.startIndex, offsetBy: 2)])) ?? 0
            }

            if decimalPart.count == 2 {
                freqDecimal1 = Int(String(decimalPart.prefix(1))) ?? 0
                freqDecimal2 = Int(String(decimalPart.suffix(1))) ?? 0
            } else {
                // Handle cases where decimal part is not 2 digits
                freqDecimal1 = Int(String(decimalPart.prefix(1))) ?? 0
                if decimalPart.count >= 2 {
                    freqDecimal2 = Int(String(decimalPart.suffix(1))) ?? 0
                } else {
                    freqDecimal2 = 0
                }
            }
        }
    }
}
