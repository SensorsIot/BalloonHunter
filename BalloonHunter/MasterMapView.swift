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
                TrackingMapView()
            }
        }
    }
}

#Preview {
    let persistenceService = PersistenceService()
    let bleService = BLECommunicationService(persistenceService: persistenceService)
    MasterMapView()
        .environmentObject(AnnotationService(bleService: bleService))
        .environmentObject(bleService)
        .environmentObject(persistenceService)
}
