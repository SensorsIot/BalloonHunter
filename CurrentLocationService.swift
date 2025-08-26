// CurrentLocationService.swift
// Provides current user location updates via CoreLocation

import Foundation
import CoreLocation
import Combine
import SwiftUI

@MainActor
final class CurrentLocationService: NSObject, ObservableObject {
    @Published var locationData: LocationData?
    private let locationManager = CLLocationManager()
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
}

extension CurrentLocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let heading = location.course
        self.locationData = LocationData(latitude: location.coordinate.latitude,
                                         longitude: location.coordinate.longitude,
                                         heading: heading)
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[CurrentLocationService] Failed to get location: \(error.localizedDescription)")
    }
}
