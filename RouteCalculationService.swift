// RouteCalculationService.swift
// Provides route calculation logic and published route data for the app.

import Foundation
import MapKit
import Combine
import SwiftUI

@MainActor
final class RouteCalculationService: ObservableObject {
    @Published var routeData: RouteData? = nil

    // Calculate route between two coordinates using MapKit's Directions API
    func calculateRoute(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        transportType: TransportationMode = .car
    ) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = (transportType == .car) ? .automobile : .walking // Use walking for .bike as a fallback

        let directions = MKDirections(request: request)
        directions.calculate { [weak self] response, error in
            guard let self = self else { return }
            if let error = error {
                print("[RouteCalculationService] Route calculation error: \(error.localizedDescription)")
                return
            }
            guard let route = response?.routes.first else {
                print("[RouteCalculationService] No route found.")
                return
            }
            let routeData = RouteData(
                path: route.polyline.coordinates,
                distance: route.distance,
                expectedTravelTime: route.expectedTravelTime
            )
            DispatchQueue.main.async {
                self.routeData = routeData
            }
        }
    }
}
