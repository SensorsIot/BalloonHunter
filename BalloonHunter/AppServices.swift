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
    let userSettings = UserSettings()
    
    // MARK: - Core Services
    let bleCommunicationService: BLECommunicationService
    let aprsTelemetryService: APRSTelemetryService
    let currentLocationService: CurrentLocationService
    
    // MARK: - Specialized Services
    let predictionService: PredictionService
    let balloonPositionService: BalloonPositionService
    let balloonTrackService: BalloonTrackService
    let landingPointTrackingService: LandingPointTrackingService
    // RouteCalculationService moved to ServiceCoordinator (circular dependencies)
    
    // MARK: - Coordinators (moved to ServiceCoordinator)
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        
        // 1. Initialize core infrastructure first
        self.persistenceService = PersistenceService()
        self.predictionCache = PredictionCache()
        self.routingCache = RoutingCache()
        
        // 2. Initialize core services with dependencies
        self.bleCommunicationService = BLECommunicationService(persistenceService: persistenceService)
        self.aprsTelemetryService = APRSTelemetryService(userSettings: userSettings)
        self.currentLocationService = CurrentLocationService()

        // 3. Initialize prediction service in API-only mode initially
        self.predictionService = PredictionService()

        // 4. Initialize specialized services
        self.balloonPositionService = BalloonPositionService(bleService: bleCommunicationService,
                                                             aprsTelemetryService: aprsTelemetryService,
                                                             currentLocationService: currentLocationService,
                                                             persistenceService: persistenceService,
                                                             predictionService: predictionService)
        self.balloonTrackService = BalloonTrackService(
            persistenceService: persistenceService,
            balloonPositionService: balloonPositionService
        )
        self.landingPointTrackingService = LandingPointTrackingService(
            persistenceService: persistenceService,
            balloonTrackService: balloonTrackService
        )
        // LandingPointService and RouteCalculationService creation moved to ServiceCoordinator

        // 5. Set up inter-service communication
        balloonPositionService.setBalloonTrackService(balloonTrackService)

    }
    
    // MARK: - Service Lifecycle
    
    func initialize() {
        let startTime = Date()
        
        // Service initialization handled by ServiceCoordinator
        // AppServices now focuses on service coordination only
        
        let _ = Date().timeIntervalSince(startTime)
    }
    
    // MARK: - UI Command Methods
    
    // Manual prediction now handled by ServiceCoordinator
    // AppServices no longer manages UI interactions
    
    // Transport mode setting moved to ServiceCoordinator
    // AppServices no longer manages UI state
    
    // Prediction visibility toggling moved to ServiceCoordinator
    // AppServices no longer manages UI state
    
    // UI state management methods moved to ServiceCoordinator
    // AppServices now focuses on service coordination only
    
    /// Set buzzer mute state
    func setBuzzerMute(_ muted: Bool) {
        bleCommunicationService.setMute(muted)
        // Buzzer state now managed by ServiceCoordinator
        appLog("AppServices: Buzzer mute set to \(muted)", category: .general, level: .info)
    }
    
    // MARK: - Private Helper Methods
    
    // Camera control moved to ServiceCoordinator - AppServices no longer handles UI state
    
}
