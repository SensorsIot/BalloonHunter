import SwiftUI

/// Dummy view for final approach phase.
struct FinalMapView: View {
    var body: some View {
        ZStack {
            Color.green.opacity(0.1).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "location.north.line")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
                Text("FinalMapView")
                    .font(.title)
                    .foregroundColor(.green)
                Text("(Final Approach UI goes here)")
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    FinalMapView()
}
