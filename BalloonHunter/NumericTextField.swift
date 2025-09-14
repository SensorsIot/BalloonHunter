import SwiftUI

struct NumericTextField: View {
    @Binding var value: Int
    @State private var text: String
    var placeholder: String = ""

    init(_ placeholder: String = "", value: Binding<Int>) {
        self._value = value
        self._text = State(initialValue: String(value.wrappedValue))
        self.placeholder = placeholder
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .onChange(of: text) { _, newValue in
                // Keep digits only and allow empty during editing
                let filtered = newValue.filter { $0.isNumber }
                if filtered != newValue { text = filtered }
                if let intVal = Int(filtered) {
                    if intVal != value { value = intVal }
                }
            }
            .onChange(of: value) { _, newVal in
                // Reflect external changes back to text
                let s = String(newVal)
                if s != text { text = s }
            }
    }
}

