import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

@MainActor
final class AnnotationService: ObservableObject {
    let bleService: BLECommunicationService
    let balloonTrackingService: BalloonTrackingService
    
    private var cancellables = Set<AnyCancellable>()
    
    @Published private(set) var appState: AppState = .startup {
        didSet {
            SharedAppState.shared.appState = appState
        }
    }
    
    public func setAppState(_ newState: AppState) {
        self.appState = newState
    }
    
    @Published var annotations: [MapAnnotationItem] = []

    init(bleService: BLECommunicationService, balloonTrackingService: BalloonTrackingService) {
        self.bleService = bleService
        self.balloonTrackingService = balloonTrackingService
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
                self?.updateAnnotationsBasedOnTrack()
            }
            .store(in: &cancellables)
    }
    
    private func handleTelemetryAvailabilityChanged(_ isAvailable: Bool) {
        if isAvailable {
            let telemetry = bleService.latestTelemetry
            let userLocation = bleService.currentLocationService?.locationData
            let prediction = bleService.predictionService?.predictionData
            let route = bleService.predictionService?.routeCalculationService?.routeData
            let telemetryHistory = balloonTrackingService.currentBalloonTrack.map {
                TelemetryData(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude)
            }
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
        case .finalApproach:
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
        guard appState != .finalApproach else {
            return
        }

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

        if let tel = telemetry, (self.appState == .longRangeTracking || self.appState == .finalApproach) {
            let isAscending = tel.verticalSpeed >= 0
            let balloonCoordinate = CLLocationCoordinate2D(latitude: tel.latitude, longitude: tel.longitude)

            let balloonAnnotation = currentAnnotationMap[.balloon] ?? MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .balloon)
            balloonAnnotation.coordinate = balloonCoordinate
            balloonAnnotation.isAscending = isAscending
            balloonAnnotation.lastUpdateTime = lastTelemetryUpdateTime
            balloonAnnotation.altitude = tel.altitude
            newAnnotations.append(balloonAnnotation)
            currentAnnotationMap.removeValue(forKey: .balloon)

            if isAscending, let burst = prediction?.burstPoint {
                let burstAnnotation = currentAnnotationMap[.burst] ?? MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .burst)
                burstAnnotation.coordinate = burst
                newAnnotations.append(burstAnnotation)
                currentAnnotationMap.removeValue(forKey: .burst)
            }

            

            if let landing = prediction?.landingPoint {
                let landingAnnotation = currentAnnotationMap[.landing] ?? MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .landing)
                landingAnnotation.coordinate = landing
                newAnnotations.append(landingAnnotation)
                currentAnnotationMap.removeValue(forKey: .landing)
            }
        }

        self.annotations = newAnnotations
    }
}

