import Foundation
import Combine
import SwiftUI
import CoreLocation
import MapKit
import OSLog

/// Primary dependency injection container and service lifecycle manager
/// Manages all service instances and their dependencies
/// Coordinates inter-service communication and observation
@MainActor
final class AppServices: ObservableObject {
    // MARK: - Core Infrastructure
    let persistenceService: PersistenceService
    let predictionCache: PredictionCache
    let routingCache: RoutingCache
    let userSettings: UserSettings

    // MARK: - Core Services
    let bleCommunicationService: BLECommunicationService
    let aprsService: APRSDataService
    let currentLocationService: CurrentLocationService

    // MARK: - Specialized Services
    let predictionService: PredictionService
    let balloonPositionService: BalloonPositionService
    let balloonTrackService: BalloonTrackService
    let landingPointTrackingService: LandingPointTrackingService
    let routeCalculationService: RouteCalculationService
    let navigationService: NavigationService
    let frequencyManagementService: FrequencyManagementService

    // MARK: - Coordinators (moved to ServiceCoordinator)

    init() {

        // 1. Initialize core infrastructure first
        self.persistenceService = PersistenceService()
        self.predictionCache = PredictionCache()
        self.routingCache = RoutingCache()

        // Use the loaded UserSettings from PersistenceService instead of creating fresh ones
        self.userSettings = persistenceService.userSettings

        // 2. Initialize core services with dependencies
        self.bleCommunicationService = BLECommunicationService(persistenceService: persistenceService)
        self.aprsService = APRSDataService(userSettings: userSettings)
        self.currentLocationService = CurrentLocationService()

        // 3. Initialize prediction service with shared dependencies
        self.predictionService = PredictionService(predictionCache: predictionCache, userSettings: userSettings)

        // 4. Initialize route calculation service
        self.routeCalculationService = RouteCalculationService(currentLocationService: currentLocationService)

        // 5. Initialize navigation service
        self.navigationService = NavigationService(userSettings: userSettings, routeCalculationService: routeCalculationService)

        // 5. Initialize specialized services
        self.balloonPositionService = BalloonPositionService(bleService: bleCommunicationService,
                                                             aprsService: aprsService,
                                                             currentLocationService: currentLocationService,
                                                             persistenceService: persistenceService,
                                                             predictionService: predictionService,
                                                             routeCalculationService: routeCalculationService)
        self.balloonTrackService = BalloonTrackService(
            persistenceService: persistenceService,
            balloonPositionService: balloonPositionService
        )
        self.landingPointTrackingService = LandingPointTrackingService(
            persistenceService: persistenceService,
            balloonTrackService: balloonTrackService
        )

        // 6. Initialize frequency management service
        self.frequencyManagementService = FrequencyManagementService(
            bleService: bleCommunicationService,
            balloonPositionService: balloonPositionService
        )

        // LandingPointService and RouteCalculationService creation moved to ServiceCoordinator

        // 5. Set up inter-service communication
        balloonPositionService.setBalloonTrackService(balloonTrackService)

        // NEW: Set up service chain dependencies
        predictionService.setLandingPointTrackingService(landingPointTrackingService)
        balloonPositionService.setLandingPointTrackingService(landingPointTrackingService)
        landingPointTrackingService.setRouteCalculationService(routeCalculationService)

    }
    
    // MARK: - Service Lifecycle

    func initialize() {
        // All service initialization is now handled in the init() method
        // ServiceCoordinator manages the startup sequence
        appLog("AppServices: Services initialized and ready", category: .service, level: .info)
    }
}
