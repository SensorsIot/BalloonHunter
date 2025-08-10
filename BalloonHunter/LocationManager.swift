// LocationManager.swift
// Provides observable user location using CoreLocation

import Foundation
import CoreLocation
import Combine

public class LocationManager: NSObject, ObservableObject {
    @Published public var location: CLLocation? = nil
    private let locationManager = CLLocationManager()

    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
}

extension LocationManager: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationManager error: \(error.localizedDescription)")
    }
}
