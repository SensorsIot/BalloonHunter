// PredictionInfo.swift
// Centralized ObservableObject for prediction info

import Foundation
import CoreLocation
import Combine

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
