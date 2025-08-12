// AppServices.swift
// Centralizes all non-UI, reusable service-style logic and singleton helpers.

import Foundation
import CoreLocation
import Combine
import SwiftUI
import CoreData

// MARK: - Location Manager (Observable)
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

// MARK: - Prediction Info (Observable)
public final class PredictionInfo: ObservableObject {
    @Published public var landingTime: Date?
    @Published public var arrivalTime: Date?
    @Published public var routeDistanceMeters: CLLocationDistance?
    @Published public var burstCoordinate: CLLocationCoordinate2D?
    @Published public var predictedPath: [CLLocationCoordinate2D]
    @Published public var hunterRoute: [CLLocationCoordinate2D]

    public init(
        landingTime: Date? = nil,
        arrivalTime: Date? = nil,
        routeDistanceMeters: CLLocationDistance? = nil,
        burstCoordinate: CLLocationCoordinate2D? = nil,
        predictedPath: [CLLocationCoordinate2D]? = nil,
        hunterRoute: [CLLocationCoordinate2D]? = nil
    ) {
        self.landingTime = landingTime
        self.arrivalTime = arrivalTime
        self.routeDistanceMeters = routeDistanceMeters
        self.burstCoordinate = burstCoordinate
        self.predictedPath = predictedPath ?? []
        self.hunterRoute = hunterRoute ?? []
    }
    public static let empty = PredictionInfo()
}

// MARK: - PredictionService Stub
public class PredictionService {
    public static let shared = PredictionService()
    private init() {}
    // Simulate async prediction fetch/route
    public func fetchPrediction(completion: @escaping (PredictionInfo) -> Void) {
        completion(PredictionInfo())
    }
    public func startPredictionTimer(_ handler: @escaping (PredictionInfo) -> Void) {}
    public func startRouteTimer(_ handler: @escaping (PredictionInfo) -> Void) {}
}

// MARK: - AnnotationService Stub
public class AnnotationService {
    static func calculateAnnotations(userCoordinate: CLLocationCoordinate2D?, balloonCoordinate: CLLocationCoordinate2D?, latestTelemetry: TelemetryStruct?, viewModel: MainViewModel) -> [MapAnnotationItem] {
        // Simplified placeholder logic
        var items: [MapAnnotationItem] = []
        if let coord = userCoordinate {
            items.append(MapAnnotationItem(coordinate: coord, kind: .user, status: .fresh))
        }
        if let coord = balloonCoordinate {
            items.append(MapAnnotationItem(coordinate: coord, kind: .balloon, status: .fresh))
        }
        return items
    }
}

// MARK: - PredictionSettings stub
public class PredictionSettings {
    public static let shared = PredictionSettings()
    private init() {}
}

// MARK: - PredictionLogic stub
public class PredictionLogic {
    public static let shared = PredictionLogic()
    private init() {}
}

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
