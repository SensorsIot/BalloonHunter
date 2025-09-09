import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

@MainActor
final class ServiceManager: ObservableObject {
    let persistenceService: PersistenceService
    let predictionCache: PredictionCache
    let routingCache: RoutingCache
    let policyScheduler: PolicyScheduler

    lazy var currentLocationService = CurrentLocationService(serviceManager: self)
    lazy var bleCommunicationService = BLECommunicationService(persistenceService: self.persistenceService, serviceManager: self)
    lazy var modeManager = ModeManager(serviceManager: self)

    lazy var balloonTrackingService = BalloonTrackingService(persistenceService: self.persistenceService, bleService: self.bleCommunicationService)
    lazy var predictionService = PredictionService(currentLocationService: self.currentLocationService, balloonTrackingService: self.balloonTrackingService, persistenceService: self.persistenceService, userSettings: self.persistenceService.userSettings)
    lazy var landingPointService = LandingPointService(balloonTrackingService: self.balloonTrackingService, predictionService: self.predictionService, persistenceService: self.persistenceService)
    lazy var routeCalculationService = RouteCalculationService(landingPointService: self.landingPointService, currentLocationService: self.currentLocationService)
    lazy var annotationService = AnnotationService(bleService: self.bleCommunicationService, balloonTrackingService: self.balloonTrackingService, landingPointService: self.landingPointService)

    lazy var predictionPolicy = PredictionPolicy(serviceManager: self, predictionService: self.predictionService, policyScheduler: self.policyScheduler, predictionCache: self.predictionCache)
    lazy var routingPolicy = RoutingPolicy(serviceManager: self, routeCalculationService: self.routeCalculationService, policyScheduler: self.policyScheduler, routingCache: self.routingCache)
    lazy var cameraPolicy = CameraPolicy(serviceManager: self, policyScheduler: self.policyScheduler)
    lazy var startupCoordinator = StartupCoordinator(serviceManager: self)

    private var cancellables = Set<AnyCancellable>()
    
    private var lastRouteCalculationTime: Date? = nil

    let telemetryPublisher = PassthroughSubject<TelemetryEvent, Never>()
    let userLocationPublisher = PassthroughSubject<UserLocationEvent, Never>()
    let uiEventPublisher = PassthroughSubject<UIEvent, Never>()

    init() {
        appLog("ServiceManager init", category: .general)
        // 1. Independent services/caches/schedulers
        self.persistenceService = PersistenceService()
        self.predictionCache = PredictionCache()
        self.routingCache = RoutingCache()
        self.policyScheduler = PolicyScheduler()

        
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
