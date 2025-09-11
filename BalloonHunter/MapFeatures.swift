// MapFeatures.swift
// Phase 1: Logical grouping of related map elements
// Works alongside existing MapState - doesn't replace it

import Foundation
import CoreLocation
import MapKit
import SwiftUI

// MARK: - Map Feature Protocol

protocol MapFeature {
    var id: String { get }
    var isVisible: Bool { get }
    var annotations: [MapAnnotationItem] { get }
    var overlays: [MapOverlay] { get }
}

// MARK: - Map Overlay Wrapper

struct MapOverlay {
    let id: String
    let polyline: MKPolyline
    let color: Color
    let lineWidth: CGFloat
    let zOrder: Int
}

// MARK: - Balloon Prediction Feature

struct BalloonPredictionFeature: MapFeature {
    let id = "balloon_prediction"
    let isVisible: Bool
    let annotations: [MapAnnotationItem]
    let overlays: [MapOverlay]
    
    init(from mapState: MapState) {
        // Visibility based on prediction toggle
        self.isVisible = mapState.isPredictionPathVisible
        
        var featureAnnotations: [MapAnnotationItem] = []
        var featureOverlays: [MapOverlay] = []
        
        // Balloon annotation (if available)
        if let balloonTelemetry = mapState.balloonTelemetry {
            let balloonAnnotation = MapAnnotationItem(
                coordinate: CLLocationCoordinate2D(
                    latitude: balloonTelemetry.latitude,
                    longitude: balloonTelemetry.longitude
                ),
                kind: .balloon,
                isAscending: balloonTelemetry.verticalSpeed >= 0,
                altitude: balloonTelemetry.altitude
            )
            featureAnnotations.append(balloonAnnotation)
        }
        
        // Burst point annotation (only if ascending)
        if let burstPoint = mapState.burstPoint,
           let balloonTelemetry = mapState.balloonTelemetry,
           balloonTelemetry.verticalSpeed >= 0 {
            let burstAnnotation = MapAnnotationItem(coordinate: burstPoint, kind: .burst)
            featureAnnotations.append(burstAnnotation)
        }
        
        // Landing point annotation (part of prediction)
        if let landingPoint = mapState.landingPoint {
            let landingAnnotation = MapAnnotationItem(coordinate: landingPoint, kind: .landing)
            featureAnnotations.append(landingAnnotation)
        }
        
        // Prediction path overlay (blue line)
        if let predictionPath = mapState.predictionPath {
            let predictionOverlay = MapOverlay(
                id: "prediction_path",
                polyline: predictionPath,
                color: .blue,
                lineWidth: 4,
                zOrder: 1
            )
            featureOverlays.append(predictionOverlay)
        }
        
        self.annotations = featureAnnotations
        self.overlays = featureOverlays
    }
}

// MARK: - User Route Feature

struct UserRouteFeature: MapFeature {
    let id = "user_route"
    let isVisible: Bool
    let annotations: [MapAnnotationItem]
    let overlays: [MapOverlay]
    
    init(from mapState: MapState) {
        // Visibility based on route availability and distance
        self.isVisible = mapState.isRouteVisible
        
        var featureAnnotations: [MapAnnotationItem] = []
        var featureOverlays: [MapOverlay] = []
        
        // User annotation
        if let userLocation = mapState.userLocation {
            let userAnnotation = MapAnnotationItem(
                coordinate: CLLocationCoordinate2D(
                    latitude: userLocation.latitude,
                    longitude: userLocation.longitude
                ),
                kind: .user
            )
            featureAnnotations.append(userAnnotation)
        }
        
        // Landing point annotation (shared with prediction)
        if let landingPoint = mapState.landingPoint {
            let landingAnnotation = MapAnnotationItem(coordinate: landingPoint, kind: .landing)
            featureAnnotations.append(landingAnnotation)
        }
        
        // Route path overlay (green line)
        if let userRoute = mapState.userRoute {
            let routeOverlay = MapOverlay(
                id: "user_route_path",
                polyline: userRoute,
                color: .green,
                lineWidth: 3,
                zOrder: 3
            )
            featureOverlays.append(routeOverlay)
        }
        
        self.annotations = featureAnnotations
        self.overlays = featureOverlays
    }
}

// MARK: - Balloon Track Feature

struct BalloonTrackFeature: MapFeature {
    let id = "balloon_track"
    let isVisible = true  // Always visible when data exists
    let annotations: [MapAnnotationItem] = []  // No annotations, just path
    let overlays: [MapOverlay]
    
    init(from mapState: MapState) {
        var featureOverlays: [MapOverlay] = []
        
        // Balloon track overlay (red line)
        if let trackPath = mapState.balloonTrackPath {
            let trackOverlay = MapOverlay(
                id: "balloon_track_path",
                polyline: trackPath,
                color: .red,
                lineWidth: 2,
                zOrder: 2
            )
            featureOverlays.append(trackOverlay)
        }
        
        self.overlays = featureOverlays
    }
}

// MARK: - Map Feature Coordinator

struct MapFeatureCoordinator {
    static func createFeatures(from mapState: MapState) -> [MapFeature] {
        var features: [MapFeature] = []
        
        // Create features based on available data
        features.append(BalloonPredictionFeature(from: mapState))
        features.append(UserRouteFeature(from: mapState))
        features.append(BalloonTrackFeature(from: mapState))
        
        return features
    }
    
    // Get all annotations from all visible features
    static func getAllAnnotations(from features: [MapFeature]) -> [MapAnnotationItem] {
        var allAnnotations: [MapAnnotationItem] = []
        
        for feature in features where feature.isVisible {
            allAnnotations.append(contentsOf: feature.annotations)
        }
        
        // Remove duplicates (e.g., landing point appears in both prediction and route)
        return removeDuplicateAnnotations(allAnnotations)
    }
    
    // Get all overlays from all visible features, sorted by z-order
    static func getAllOverlays(from features: [MapFeature]) -> [MapOverlay] {
        var allOverlays: [MapOverlay] = []
        
        for feature in features where feature.isVisible {
            allOverlays.append(contentsOf: feature.overlays)
        }
        
        return allOverlays.sorted { $0.zOrder < $1.zOrder }
    }
    
    private static func removeDuplicateAnnotations(_ annotations: [MapAnnotationItem]) -> [MapAnnotationItem] {
        var uniqueAnnotations: [MapAnnotationItem] = []
        var seenCoordinates: Set<String> = []
        
        for annotation in annotations {
            let key = "\(annotation.coordinate.latitude),\(annotation.coordinate.longitude),\(annotation.kind)"
            if !seenCoordinates.contains(key) {
                seenCoordinates.insert(key)
                uniqueAnnotations.append(annotation)
            }
        }
        
        return uniqueAnnotations
    }
}