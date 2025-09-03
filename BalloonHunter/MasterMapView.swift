import SwiftUI

/// The main map container that switches between tracking and final approach phases.
struct MasterMapView: View {
    @EnvironmentObject var annotationService: AnnotationService

    init() {
        print("[DEBUG][MasterMapView] MasterMapView initialized")
    }

    var body: some View {
        ZStack {
            switch annotationService.appState {
            case .longRangeTracking:
                TrackingMapView()
            case .finalApproach:
                FinalMapView()
            default:
                if annotationService.appState == .startup {
                    VStack(spacing: 20) {
                        ProgressView()
                        Text("Waiting for balloon data...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.25))
                }
            }
        }
    }
}

#Preview {
    MasterMapView()
        .environmentObject(AnnotationService())
}
