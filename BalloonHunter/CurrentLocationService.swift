import Foundation
import CoreLocation
import Combine

/// Publishes current location and heading (for map orientation)
public final class CurrentLocationService: NSObject, ObservableObject {
    @Published public private(set) var location: CLLocation?
    @Published public private(set) var heading: CLHeading?
    private let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 1 // degrees, for frequent updates
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        print("[LocationService] Initialized and started location/heading updates.")
    }
}

extension CurrentLocationService: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        print("[LocationService] Location update: \(loc?.coordinate.latitude ?? 0), \(loc?.coordinate.longitude ?? 0)")
        location = loc
    }
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        print("[LocationService] Heading update: \(newHeading.trueHeading)° true, \(newHeading.magneticHeading)° magnetic")
        heading = newHeading
    }
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationService] Error: \(error.localizedDescription)")
    }
}
