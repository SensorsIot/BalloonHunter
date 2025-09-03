import SwiftUI

/// The main map container that switches between tracking and final approach phases.
struct MasterMapView: View {
    @EnvironmentObject var annotationService: AnnotationService

    var body: some View {
        Group {
            switch annotationService.appState {
            case .longRangeTracking:
                TrackingMapView()
            case .finalApproach:
                FinalMapView()
            default:
                VStack(spacing: 20) {
                    ProgressView()
                    Text("Waiting for balloon data...")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

#Preview {
    MasterMapView()
        .environmentObject(AnnotationService())
}
