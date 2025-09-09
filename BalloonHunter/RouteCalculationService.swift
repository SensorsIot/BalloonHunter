
import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import OSLog

@MainActor
final class RouteCalculationService: ObservableObject {
    private let landingPointService: LandingPointService
    private let currentLocationService: CurrentLocationService

    @Published var routeData: RouteData? = nil
    @Published var healthStatus: ServiceHealth = .healthy
    private var failureCount: Int = 0
    private var retryDelay: TimeInterval = 1.0

    init(landingPointService: LandingPointService, currentLocationService: CurrentLocationService) {
        self.landingPointService = landingPointService
        self.currentLocationService = currentLocationService
        
        appLog("RouteCalculationService init", category: .service, level: .debug)
    }

    func calculateRoute(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        transportType: TransportationMode = .car,
        version: Int
    ) {
        appLog("RouteCalculationService: Starting route calculation from \(from) to \(to) via \(transportType)", category: .service, level: .info)
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
                print("[RouteCalculationService] Route calculation error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.failureCount += 1
                    self.retryDelay = min(self.retryDelay * 2, 60.0)
                    self.healthStatus = self.failureCount >= 3 ? .unhealthy : .degraded
                }
                return
            }
            guard let route = response?.routes.first else {
                print("[RouteCalculationService] No route found.")
                DispatchQueue.main.async {
                    self.routeData = nil
                    self.failureCount += 1
                    self.retryDelay = min(self.retryDelay * 2, 60.0)
                    self.healthStatus = self.failureCount >= 3 ? .unhealthy : .degraded
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
                expectedTravelTime: travelTime,
                version: version
            )
            DispatchQueue.main.async {
                self.routeData = routeData
                self.healthStatus = .healthy
                self.failureCount = 0
                self.retryDelay = 1.0
                appLog("RouteCalculationService: Route calculation completed - Distance: \(String(format: "%.1f", route.distance/1000))km, Travel time: \(String(format: "%.1f", travelTime/60))min", category: .service, level: .info)
            }
        }
    }
}
