import SwiftUI

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
