import SwiftUI

/// The main map container that switches between tracking and final approach phases.
struct MasterMapView: View {
    @EnvironmentObject private var annotationService: AnnotationService

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
    let balloonTrackingService = BalloonTrackingService(persistenceService: persistenceService, bleService: bleService)
    MasterMapView()
        .environmentObject(AnnotationService(bleService: bleService, balloonTrackingService: balloonTrackingService))
        .environmentObject(bleService)
        .environmentObject(persistenceService)
}
