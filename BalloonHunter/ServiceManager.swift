
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

    private var cancellables = Set<AnyCancellable>()
    private var predictionTimer: Timer?
    private var lastRouteCalculationTime: Date? = nil

    init() {
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] ServiceManager init")
        self.persistenceService = PersistenceService()
        self.bleCommunicationService = BLECommunicationService(persistenceService: self.persistenceService)
        self.balloonTrackingService = BalloonTrackingService(persistenceService: self.persistenceService, bleService: self.bleCommunicationService)
        self.currentLocationService = CurrentLocationService()
        self.routeCalculationService = RouteCalculationService()
        self.predictionService = PredictionService()
        self.annotationService = AnnotationService(bleService: self.bleCommunicationService, balloonTrackingService: self.balloonTrackingService)
        self.bleCommunicationService.annotationService = self.annotationService
        self.bleCommunicationService.predictionService = self.predictionService
        self.bleCommunicationService.currentLocationService = self.currentLocationService

        self.predictionService.routeCalculationService = self.routeCalculationService
        self.predictionService.currentLocationService = self.currentLocationService

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
        
        setupTimers()
    }

    private func setupTimers() {
        predictionTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                print("[DEBUG][ServiceManager] 60s timer fired. Fetching prediction.")
                guard let telemetry = self.bleCommunicationService.latestTelemetry,
                      let userSettings = self.persistenceService.readPredictionParameters() else { return }
                
                if self.annotationService.appState != .startup {
                    await self.predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
                }
            }
        }
    }

    func propagateStateUpdates() async {
        let telemetry = bleCommunicationService.latestTelemetry
        let userLocation = currentLocationService.locationData
        let prediction = predictionService.predictionData
        let route = routeCalculationService.routeData
        let telemetryHistory = balloonTrackingService.currentBalloonTrack.map {
            TelemetryData(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude)
        }

        if let userLoc = userLocation, let landingPoint = prediction?.landingPoint {
            let now = Date()
            if lastRouteCalculationTime == nil || now.timeIntervalSince(lastRouteCalculationTime!) >= 60 {
                await self.routeCalculationService.calculateRoute(
                    from: CLLocationCoordinate2D(latitude: userLoc.latitude, longitude: userLoc.longitude),
                    to: landingPoint,
                    transportType: .car
                )
                self.lastRouteCalculationTime = now
            }
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
