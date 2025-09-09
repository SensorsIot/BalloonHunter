import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import os

@MainActor
final class CurrentLocationService: NSObject, ObservableObject {
    @Published var locationData: LocationData?
    private let locationManager = CLLocationManager()
    private var lastHeading: CLLocationDirection? = nil
    private var lastLocationUpdateTime: Date? = nil
    weak var serviceManager: ServiceManager?
    
    init(serviceManager: ServiceManager) {
        self.serviceManager = serviceManager
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] CurrentLocationService init")
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.startUpdatingHeading()
    }

    func requestPermission() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] CurrentLocationService: Requesting location permission.")
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] CurrentLocationService: Starting location updates.")
        locationManager.startUpdatingLocation()
    }
}

extension CurrentLocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        lastHeading = newHeading.trueHeading > 0 ? newHeading.trueHeading : newHeading.magneticHeading
        // If locationData exists, update its heading; otherwise, don't publish until new location is received
        if let oldLocationData = locationData {
            DispatchQueue.main.async {
                self.locationData = LocationData(latitude: oldLocationData.latitude, longitude: oldLocationData.longitude, heading: self.lastHeading ?? -1)
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] CurrentLocationService: No locations received.")
            return
        }
        let heading = lastHeading ?? location.course
        DispatchQueue.main.async {
            let now = Date()
            let newLocationData = LocationData(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, heading: heading)
            
            // Log location updates
            if let oldLocationData = self.locationData {
                let distance = CLLocation(latitude: oldLocationData.latitude, longitude: oldLocationData.longitude).distance(from: CLLocation(latitude: newLocationData.latitude, longitude: newLocationData.longitude))
                let timeDiff = self.lastLocationUpdateTime != nil ? now.timeIntervalSince(self.lastLocationUpdateTime!) : 0
                appLog("User location update: lat=\(newLocationData.latitude), lon=\(newLocationData.longitude), dist=\(distance)m, timeDiff=\(timeDiff)s", category: .service, level: .debug)
            } else {
                appLog("Initial user location: lat=\(newLocationData.latitude), lon=\(newLocationData.longitude)", category: .service, level: .debug)
            }

            self.locationData = newLocationData
            self.lastLocationUpdateTime = now
            self.serviceManager?.userLocationPublisher.send(UserLocationEvent(locationData: newLocationData))
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            appLog("CurrentLocationService: Failed to get location: \(error.localizedDescription)", category: .service, level: .error)
        }
    }
}

