
import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

@MainActor
final class RouteCalculationService: ObservableObject {
    private let landingPointService: LandingPointService
    private let currentLocationService: CurrentLocationService
    private var cancellables = Set<AnyCancellable>()
    private var lastRouteCalculationTime: Date?

    @Published var routeData: RouteData? = nil

    init(landingPointService: LandingPointService, currentLocationService: CurrentLocationService) {
        self.landingPointService = landingPointService
        self.currentLocationService = currentLocationService
        
        print("[DEBUG] RouteCalculationService init")
        setupTriggers()
    }

    private func setupTriggers() {
        // Trigger 1: The landing point has changed
        landingPointService.$validLandingPoint
            .sink { [weak self] newLandingPoint in
                guard let self = self else { return }
                if let landingPoint = newLandingPoint,
                   let currentLocation = self.currentLocationService.locationData {
                    print("[DEBUG] Landing point changed. Recalculating route.")
                    self.calculateRoute(
                        from: CLLocationCoordinate2D(latitude: currentLocation.latitude, longitude: currentLocation.longitude),
                        to: landingPoint,
                        transportType: .car // Default to car for now
                    )
                } else {
                    self.routeData = nil // Clear route if landing point is no longer valid
                }
            }
            .store(in: &cancellables)

        // Trigger 2: The last route calculation is more than 60 seconds old and the user’s position has changed
        currentLocationService.$locationData
            .sink { [weak self] newLocationData in
                guard let self = self else { return }
                if let currentLocation = newLocationData,
                   let landingPoint = self.landingPointService.validLandingPoint {
                    let now = Date()
                    if self.lastRouteCalculationTime == nil || now.timeIntervalSince(self.lastRouteCalculationTime!) > 60 {
                        print("[DEBUG] User position changed and >60s since last calculation. Recalculating route.")
                        self.calculateRoute(
                            from: CLLocationCoordinate2D(latitude: currentLocation.latitude, longitude: currentLocation.longitude),
                            to: landingPoint,
                            transportType: .car // Default to car for now
                        )
                        self.lastRouteCalculationTime = now
                    }
                } else {
                    self.routeData = nil // Clear route if current location or landing point is no longer valid
                }
            }
            .store(in: &cancellables)
    }

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
                print("[RouteCalculationService] Route calculation error: \(error.localizedDescription)")
                return
            }
            guard let route = response?.routes.first else {
                print("[RouteCalculationService] No route found.")
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
