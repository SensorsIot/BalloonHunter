import SwiftUI

struct SondeSheet: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .padding(.top, 32)
            Text("Sonde Feature")
                .font(.title)
                .fontWeight(.bold)
            Text("This is a placeholder for the SondeSheet view. Customize as needed.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding()
            Spacer()
        }
        .padding()
    }
}

#Preview {
    SondeSheet()
}
