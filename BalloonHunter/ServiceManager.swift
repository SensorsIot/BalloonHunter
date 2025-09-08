import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

@MainActor
final class ServiceManager: ObservableObject {
    let bleCommunicationService: BLECommunicationService
    let balloonTrackingService: BalloonTrackingService
    let currentLocationService: CurrentLocationService
    let persistenceService: PersistenceService
    let routeCalculationService: RouteCalculationService
    let predictionService: PredictionService
    let annotationService: AnnotationService
    let landingPointService: LandingPointService

    private var cancellables = Set<AnyCancellable>()
    
    private var lastRouteCalculationTime: Date? = nil

    init() {
        print("[DEBUG] ServiceManager init")
        self.persistenceService = PersistenceService()
        self.bleCommunicationService = BLECommunicationService(persistenceService: self.persistenceService)
        self.balloonTrackingService = BalloonTrackingService(persistenceService: self.persistenceService, bleService: self.bleCommunicationService)
        self.currentLocationService = CurrentLocationService()
        self.predictionService = PredictionService(currentLocationService: self.currentLocationService, balloonTrackingService: self.balloonTrackingService, persistenceService: self.persistenceService, userSettings: self.persistenceService.userSettings)
        self.landingPointService = LandingPointService(balloonTrackingService: self.balloonTrackingService, predictionService: self.predictionService, persistenceService: self.persistenceService)
        self.routeCalculationService = RouteCalculationService(landingPointService: self.landingPointService, currentLocationService: self.currentLocationService)
        self.annotationService = AnnotationService(bleService: self.bleCommunicationService, balloonTrackingService: self.balloonTrackingService, landingPointService: self.landingPointService)
        self.bleCommunicationService.annotationService = self.annotationService
        self.bleCommunicationService.predictionService = self.predictionService
        self.bleCommunicationService.currentLocationService = self.currentLocationService

        self.predictionService.routeCalculationService = self.routeCalculationService

        bleCommunicationService.$latestTelemetry
            .sink { [weak self] _ in Task { await self?.propagateStateUpdates() } }
            .store(in: &cancellables)

        currentLocationService.$locationData
            .sink { [weak self] _ in Task { await self?.propagateStateUpdates() } }
            .store(in: &cancellables)

        predictionService.$predictionData
            .sink { [weak self] _ in Task { await self?.propagateStateUpdates() } }
            .store(in: &cancellables)

        routeCalculationService.$routeData
            .sink { [weak self] _ in Task { await self?.propagateStateUpdates() } }
            .store(in: &cancellables)

        balloonTrackingService.$currentBalloonTrack
            .sink { [weak self] _ in Task { await self?.propagateStateUpdates() } }
            .store(in: &cancellables)
        

    }

    

    func propagateStateUpdates() async {
        let telemetry = bleCommunicationService.latestTelemetry
        let userLocation = currentLocationService.locationData
        let prediction = predictionService.predictionData
        let route = routeCalculationService.routeData
        let telemetryHistory = balloonTrackingService.currentBalloonTrack.map {
            TelemetryData(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude)
        }

        

        annotationService.updateState(
            telemetry: telemetry,
            userLocation: userLocation,
            prediction: prediction,
            route: route,
            telemetryHistory: telemetryHistory,
            lastTelemetryUpdateTime: bleCommunicationService.lastTelemetryUpdateTime
        )
    }
}

