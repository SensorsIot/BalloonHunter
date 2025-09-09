import SwiftUI

struct StartupView: View {
    @EnvironmentObject var startupCoordinator: StartupCoordinator

    var body: some View {
        VStack {
            Text("BalloonHunter")
                .font(.largeTitle)
                .fontWeight(.bold)
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(1.5)
                .padding()
            Text(startupCoordinator.startupProgress)
                .font(.headline)
        }
    }
}
