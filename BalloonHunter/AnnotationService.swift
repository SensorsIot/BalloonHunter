import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import os

@MainActor
final class AnnotationService: ObservableObject {
    let bleService: BLECommunicationService
    let balloonTrackingService: BalloonTrackingService
    let landingPointService: LandingPointService
    
    private var cancellables = Set<AnyCancellable>()
    private var lastAnnotationUpdateTime: Date? = nil
    
    @Published private(set) var appState: AppState = .startup {
        didSet {
            SharedAppState.shared.appState = appState
        }
    }
    
    public func setAppState(_ newState: AppState) {
        self.appState = newState
    }
    
    @Published var annotations: [MapAnnotationItem] = []

    init(bleService: BLECommunicationService, balloonTrackingService: BalloonTrackingService, landingPointService: LandingPointService) {
        self.bleService = bleService
        self.balloonTrackingService = balloonTrackingService
        self.landingPointService = landingPointService
        print("[DEBUG][AnnotationService] AnnotationService init")
        
        bleService.$telemetryAvailabilityState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAvailable in
                self?.handleTelemetryAvailabilityChanged(isAvailable)
            }
            .store(in: &cancellables)

        balloonTrackingService.$currentBalloonTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.throttledUpdateAnnotations()
            }
            .store(in: &cancellables)

        landingPointService.$validLandingPoint
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.throttledUpdateAnnotations()
            }
            .store(in: &cancellables)
    }
    
    private func handleTelemetryAvailabilityChanged(_ isAvailable: Bool) {
        if isAvailable {
            let telemetry = bleService.latestTelemetry
            let userLocation = bleService.currentLocationService?.locationData
            let prediction = bleService.predictionService?.predictionData
            let lastUpdateTime = bleService.lastTelemetryUpdateTime
            
            updateAnnotations(
                telemetry: telemetry,
                userLocation: userLocation,
                prediction: prediction,
                lastTelemetryUpdateTime: lastUpdateTime
            )
        } else {
            var items: [MapAnnotationItem] = []
            if let userLoc = bleService.currentLocationService?.locationData {
                items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: userLoc.latitude, longitude: userLoc.longitude), kind: .user))
            }
            self.annotations = items
        }
    }

    private func throttledUpdateAnnotations() {
        let now = Date()
        if let last = lastAnnotationUpdateTime, now.timeIntervalSince(last) < 2.0 { return } // Throttle to 2 seconds
        lastAnnotationUpdateTime = now
        updateAnnotationsBasedOnTrack()
    }
    
    private func updateAnnotationsBasedOnTrack() {
        let telemetry = bleService.latestTelemetry
        let userLocation = bleService.currentLocationService?.locationData
        let prediction = bleService.predictionService?.predictionData
        let lastUpdateTime = bleService.lastTelemetryUpdateTime

        updateAnnotations(
            telemetry: telemetry,
            userLocation: userLocation,
            prediction: prediction,
            lastTelemetryUpdateTime: lastUpdateTime
        )
    }

    func updateState(
        telemetry: TelemetryData?,
        userLocation: LocationData?,
        prediction: PredictionData?,
        route: RouteData?,
        telemetryHistory: [TelemetryData],
        lastTelemetryUpdateTime: Date?
    ) {
        if telemetry != nil {
            let telemetryStr = "lat=\(telemetry!.latitude), lon=\(telemetry!.longitude), alt=\(telemetry!.altitude)"
            _ = telemetryStr
            _ = prediction != nil
            _ = route != nil
            _ = telemetryHistory.count
        } else {
            _ = prediction != nil
            _ = route != nil
            _ = telemetryHistory.count
        }

        switch appState {
        case .startup:
            if let _ = telemetry,
               let prediction = prediction, prediction.landingPoint != nil,
               let route = route, route.path != nil {
                appState = .longRangeTracking
            }
        case .longRangeTracking:
            break
        
        }
        
        updateAnnotations(telemetry: telemetry, userLocation: userLocation, prediction: prediction, lastTelemetryUpdateTime: lastTelemetryUpdateTime)
    }

    private func updateAnnotations(
        telemetry: TelemetryData?,
        userLocation: LocationData?,
        prediction: PredictionData?,
        lastTelemetryUpdateTime: Date?
    ) {
        var currentAnnotationMap: [MapAnnotationItem.AnnotationKind: MapAnnotationItem] = [:]
        for annotation in self.annotations {
            currentAnnotationMap[annotation.kind] = annotation
        }

        var newAnnotations: [MapAnnotationItem] = []

        if let userLoc = userLocation {
            let userAnnotation = currentAnnotationMap[.user] ?? MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .user)
            userAnnotation.coordinate = CLLocationCoordinate2D(latitude: userLoc.latitude, longitude: userLoc.longitude)
            newAnnotations.append(userAnnotation)
            currentAnnotationMap.removeValue(forKey: .user)
        }

        if let tel = telemetry, (self.appState == .longRangeTracking) {
            let isAscending = tel.verticalSpeed >= 0
            let balloonCoordinate = CLLocationCoordinate2D(latitude: tel.latitude, longitude: tel.longitude)

            let balloonAnnotation = currentAnnotationMap[.balloon] ?? MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .balloon)
            balloonAnnotation.coordinate = balloonCoordinate
            balloonAnnotation.isAscending = isAscending
            balloonAnnotation.lastUpdateTime = lastTelemetryUpdateTime
            balloonAnnotation.altitude = tel.altitude
            newAnnotations.append(balloonAnnotation)
            currentAnnotationMap.removeValue(forKey: .balloon)

            // Only show burst point if prediction service says it should be visible
            if let predictionService = bleService.predictionService, predictionService.isBurstMarkerVisible, let burst = prediction?.burstPoint {
                let burstAnnotation = currentAnnotationMap[.burst] ?? MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .burst)
                burstAnnotation.coordinate = burst
                newAnnotations.append(burstAnnotation)
                currentAnnotationMap.removeValue(forKey: .burst)
            }
        }

        // Show landing point only if balloon hasn't landed yet
        if balloonTrackingService.isLanded {
            // If balloon has landed, show landed annotation at the balloon's actual position
            if let tel = telemetry {
                let landedAnnotation = currentAnnotationMap[.landed] ?? MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .landed)
                landedAnnotation.coordinate = CLLocationCoordinate2D(latitude: tel.latitude, longitude: tel.longitude)
                newAnnotations.append(landedAnnotation)
                currentAnnotationMap.removeValue(forKey: .landed)
            }
        } else if let landing = landingPointService.validLandingPoint {
            // Only show predicted landing point if balloon hasn't landed
            let landingAnnotation = currentAnnotationMap[.landing] ?? MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .landing)
            landingAnnotation.coordinate = landing
            newAnnotations.append(landingAnnotation)
            currentAnnotationMap.removeValue(forKey: .landing)
        }

        self.annotations = newAnnotations
    }
}

