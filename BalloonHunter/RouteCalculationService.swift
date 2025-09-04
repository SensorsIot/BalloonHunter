
import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

@MainActor
final class RouteCalculationService: ObservableObject {
    init() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] RouteCalculationService init")
    }
    @Published var routeData: RouteData? = nil
    func calculateRoute(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        transportType: TransportationMode = .car
    ) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))

        switch transportType {
        case .car:
            request.transportType = .automobile
        case .bike:
            request.transportType = .cycling
        }

        let directions = MKDirections(request: request)
        directions.calculate { [weak self] response, error in
            guard let self = self else { return }
            if let error = error {
                print("[RouteCalculationService][State: \(SharedAppState.shared.appState.rawValue)] Route calculation error: \(error.localizedDescription)")
                return
            }
            guard let route = response?.routes.first else {
                print("[RouteCalculationService][State: \(SharedAppState.shared.appState.rawValue)] No route found.")
                DispatchQueue.main.async {
                    self.routeData = nil
                }
                return
            }

            var travelTime = route.expectedTravelTime
            if transportType == .bike {
                travelTime *= 0.7
            }

            let routeData = RouteData(
                path: route.polyline.coordinates,
                distance: route.distance,
                expectedTravelTime: travelTime
            )
            DispatchQueue.main.async {
                self.routeData = routeData
            }
        }
    }
}
