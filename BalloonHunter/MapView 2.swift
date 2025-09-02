import SwiftUI
import MapKit

struct MapView: View {
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var predictionService: PredictionService
    @EnvironmentObject var routeService: RouteCalculationService
    @EnvironmentObject var locationService: CurrentLocationService
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var userSettings: UserSettings
    @EnvironmentObject var annotationService: AnnotationService
    @EnvironmentObject var persistenceService: PersistenceService
    @EnvironmentObject var serviceManager: ServiceManager

    var body: some View {
        ZStack {
            Color(.systemBackground).edgesIgnoringSafeArea(.all)
            Text("Map goes here")
                .font(.title)
                .foregroundColor(.gray)
                .padding()
            // TODO: Replace this placeholder with the MKMapView+SwiftUI integration and overlays per FSD
        }
    }
}

#if DEBUG
#Preview {
    MapView()
        .environmentObject(ServiceManager().bleCommunicationService)
        .environmentObject(ServiceManager().predictionService)
        .environmentObject(ServiceManager().routeCalculationService)
        .environmentObject(ServiceManager().currentLocationService)
        .environmentObject(AppSettings())
        .environmentObject(UserSettings())
        .environmentObject(ServiceManager().annotationService)
        .environmentObject(ServiceManager().persistenceService)
        .environmentObject(ServiceManager())
}
#endif
