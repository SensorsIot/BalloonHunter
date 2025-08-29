// SondeSettingsView.swift
// Placeholder implementation for SondeSettingsView.
import SwiftUI

struct SondeSettingsView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            Text("Sonde Settings")
                .font(.largeTitle)
                .bold()
            Text("Device-specific BLE configuration and settings would go here.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

#Preview {
    SondeSettingsView()
}
